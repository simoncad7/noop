import Foundation
import Combine
import CoreBluetooth
import Security
import WhoopProtocol
import WhoopStore
import SmartBand10Protocol

/// EXPERIMENTAL, ISOLATED live-BLE source for the Xiaomi Smart Band 10.
///
/// Drives the band's OWN SPPv2 BLE protocol (`SmartBand10Protocol` package: FE95 service, EC/CRC auth,
/// realtime subtype-45→47 HR, activity channel 5) through the SAME `LiveState` / `persist` channels the
/// other sources use, so live HR lights the existing live UI and the full activity sync (sleep with
/// hypnogram, HRV from the R-R stream, SpO2, steps, daily rollups) lands in the WhoopStore tables via
/// `SmartBand10Importer` — NOOP computes its own metrics, never reads a Xiaomi score.
///
/// "EXPERIMENTAL, HELP US TEST": this is a best-effort, clean-room driver re-derived from documented
/// protocol FACTS (see `ATTRIBUTION.md`) and validated byte-for-byte against real-device captures in the
/// package's test suite. It is shipped behind the experimental add-device tier because it can't be
/// hardware-verified here. It NEVER fabricates data: if the band won't authenticate (missing / wrong
/// 32-hex bind token) it surfaces an HONEST message and streams nothing.
///
/// WHOOP-FIRST ISOLATION (identical to `HuamiHRSource` / `OuraLiveSource`): this class runs its OWN
/// `CBCentralManager` and never imports, calls, or shares state with `BLEManager`. The WHOOP path cannot
/// regress. The only shared surfaces are `LiveState` and the injected closures (`persist`, `persistFiles`,
/// `log`, `onBattery`).
///
/// The band requires its Xiaomi cloud BIND TOKEN (the 32-hex auth key) before any health command. It is
/// entered by the user in the wizard (or fetched once via the optional Xiaomi account login) and persisted
/// per-device in the Keychain via `SmartBand10KeyStore` — never in UserDefaults, a plist, or on disk.
@MainActor
public final class SmartBand10Source: NSObject, ObservableObject {

    // MARK: - Public model

    /// A Smart Band 10 (or Xiaomi band family) seen during a scan.
    public struct DiscoveredDevice: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    @Published public private(set) var discovered: [DiscoveredDevice] = []
    @Published public private(set) var scanning: Bool = false
    @Published public private(set) var batteryPct: Int? = nil
    @Published public private(set) var connected: Bool = false
    /// Honest explanation when we can't stream (missing / wrong auth key, auth failed). nil = no problem.
    @Published public private(set) var needsPairing: String? = nil
    /// Human-readable status line for the wizard / settings (mirrors BleTransport.status).
    @Published public private(set) var status: String = "Idle"
    /// Last activity-sync outcome, e.g. "Synced 4 file(s)".
    @Published public private(set) var lastSyncSummary: String? = nil

    // MARK: - BLE UUIDs

    /// Xiaomi FE95 service; RX 005E (notify, the band→phone stream), TX 005F (write-without-response).
    private let fe95Service = CBUUID(string: "0000FE95-0000-1000-8000-00805F9B34FB")
    private let rxNotify = CBUUID(string: "0000005E-0000-1000-8000-00805F9B34FB")
    private let txWrite = CBUUID(string: "0000005F-0000-1000-8000-00805F9B34FB")
    /// Standard GATT Battery Service — a quick proof the GATT link is up without SPPv2, and the pairing
    /// trigger if the characteristic is encrypted (insufficientAuthentication → iOS shows the dialog).
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")

    // MARK: - Dependencies (injected — no BLEManager reference)

    private let live: LiveState
    private let persist: (Streams) -> Void
    /// Called with the parsed activity files after a sync — the coordinator wires it to `SmartBand10Importer`
    /// so sleep / HRV / R-R / SpO2 / steps land in the WhoopStore tables under this device's id.
    private let persistFiles: ([ParsedActivityFile]) -> Void
    private let deviceId: String
    private let log: (String) -> Void
    private let onBattery: (Int) -> Void
    /// When false (the wizard's discovery-only scanner) this source never writes `LiveState`.
    private let feedsLive: Bool
    /// Reads the band's 32-hex bind token (16 bytes) from the Keychain, or nil when not set yet.
    private let authKey: () -> Data?

    // MARK: - Protocol state (SmartBand10Protocol)

    private var session: Session?
    private let framer = Framer()
    /// One-shot guard: the SPP session-config packet is written exactly once per connect (after the RX
    /// notify is live). Reset on disconnect / auth retry so a re-connect re-runs the full handshake.
    private var sessionConfigSent = false
    private var isAuthenticated = false
    /// One-shot auth retry budget. The Band 10 needs TWO auth handshakes (first HMAC always mismatches),
    /// so this is tripped exactly once per user-initiated `connect`: `connect` re-arms it, `didAuthenticate`
    /// clears it, `authFailed` trips it to fire the one retry. Deliberately NOT reset on disconnect — the
    /// force-reconnect teardown must preserve it until the retry session answers.
    private var authRetryAttempted = false

    // MARK: - CoreBluetooth state (OWN central, separate from WHOOP)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingConnectID: UUID?
    private var seenPeripherals: [UUID: CBPeripheral] = [:]
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?

    // MARK: - Live HR buffer

    private var buffer: [(hr: Int, ts: Int)] = []
    private var lastFlush: Date = .init()
    private let flushCount = 30
    private let flushInterval: TimeInterval = 30
    private var loggedFirstHR = false
    private var zeroHrCount = 0
    /// Auto-pause the 5s realtime poll after this many consecutive 0-bpm replies (≈30s off-wrist).
    private let realtimeStallLimit = 6

    // MARK: - Async tasks / sync continuations

    private var realtimeTask: Task<Void, Never>?
    private var syncTimeoutTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var fileIdsContinuation: CheckedContinuation<[ActivityFileId]?, Never>?
    private var fileContinuation: CheckedContinuation<ParsedActivityFile?, Never>?
    private var syncIsRunning = false
    /// Periodic activity re-sync while connected, so a session left open overnight (or after a nap) picks
    /// up freshly-banked sleep / R-R / HR / steps on the band's flash WITHOUT needing a reconnect. Mirrors
    /// Oura's 900 s history re-fetch and BLEManager's ~15 min WHOOP history-offload floor — the same
    /// cadence the base app uses for its own pull-based devices. `syncActivity()` is guarded by
    /// `syncIsRunning` + `isAuthenticated`, so a fire that overlaps an in-flight sync is a no-op.
    private var syncTimer: Timer?
    private let syncInterval: TimeInterval = 900

    // MARK: - Reconnect (mirrors OuraLiveSource's capped-exponential backoff)

    /// Set while we're connecting / connected so an involuntary drop (band out of range, band reboot)
    /// triggers an automatic reconnect instead of leaving the device dead until the user taps Connect.
    /// A deliberate teardown (`stop()`, an auth-failure cancel) sets `intentionalDisconnect` to suppress it.
    private var reconnectID: UUID?
    private var intentionalDisconnect = false
    /// Consecutive failed-reconnect count. Reset only on a REAL connection (`didConnect`), `stop()` and an
    /// auth-failure cancel — never in `connect(_:)`, or the backoff would never progress past its first step.
    private var reconnectAttempt = 0

    // MARK: - Battery persistence

    /// Banked battery readings, flushed into the `battery` table on the next `flush()`. Without this the
    /// band's battery only lives in `LiveState` (in-memory samples that reset every connect) — Oura and the
    /// WHOOP strap persist battery rows, so the band should too.
    private var batteryBuffer: [BatterySample] = []

    // MARK: - Init

    public init(live: LiveState,
                deviceId: String,
                persist: @escaping (Streams) -> Void = { _ in },
                persistFiles: @escaping ([ParsedActivityFile]) -> Void = { _ in },
                log: @escaping (String) -> Void = { _ in },
                onBattery: @escaping (Int) -> Void = { _ in },
                feedsLive: Bool = true,
                authKey: @escaping () -> Data? = { nil }) {
        self.live = live
        self.deviceId = deviceId
        self.persist = persist
        self.persistFiles = persistFiles
        self.log = log
        self.onBattery = onBattery
        self.feedsLive = feedsLive
        self.authKey = authKey
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Build (or rebuild) the SPP session from the stored auth key. Honest `needsPairing` when the key is
    /// missing or malformed — we never attempt a keyless connect.
    private func makeSessionIfNeeded() {
        if session != nil { return }
        guard let key = authKey() else {
            status = "Enter the band's Xiaomi bind token"
            needsPairing = "This band needs its Xiaomi bind token (the 32-hex auth key). Enter it in NOOP " +
                           "or log in to your Xiaomi account once, then reconnect."
            return
        }
        let hex = key.map { String(format: "%02x", $0) }.joined()
        do {
            session = try Session(authKeyHex: hex)
            session?.onAuthenticated = { [weak self] encrypted in self?.didAuthenticate(encrypted: encrypted) }
            session?.onAuthFailed = { [weak self] in self?.authFailed() }
            session?.onEvent = { [weak self] event in self?.handle(event: event) }
            needsPairing = nil
            log("Smart Band 10: SPP session ready (key \(hex.prefix(4))…)")
        } catch {
            needsPairing = "The stored Xiaomi bind token is malformed — re-enter the 32-hex key in NOOP."
            status = "Invalid bind token"
        }
    }

    // MARK: - Scanning

    /// Scan for the band. We can't filter by service in the advert reliably, so we scan broadly and keep
    /// only Xiaomi-band-looking names (the same filter the reference client uses).
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        status = "Scanning…"
        log("Smart Band 10: scanning for Xiaomi band devices…")
        guard central.state == .poweredOn else {
            log("Smart Band 10: Bluetooth not powered on (state=\(central.state.rawValue)) — scan deferred")
            return
        }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connecting

    public func connect(_ id: UUID) {
        stopScan()
        needsPairing = nil
        // A fresh user-initiated connect gets a fresh one-shot auth retry budget. The Band 10 normally
        // needs TWO auth handshakes — the first HMAC always mismatches (see `authFailed`) — so every
        // connect re-arms the retry. `authRetryAttempted` is NOT reset on disconnect (it must survive
        // the force-reconnect teardown) — only here, on success, and on `stop`.
        authRetryAttempted = false
        makeSessionIfNeeded()
        // A user-initiated connect arms auto-reconnect for the whole link lifetime. A deliberate teardown
        // (`stop()`) clears this; an involuntary drop (out of range, band reboot) re-issues connect().
        reconnectID = id
        intentionalDisconnect = false
        // Bonded Xiaomi bands stop advertising — reconnect by the stored identifier first (memory
        // smartband10-bonded-reconnect), falling back to the scan cache / a fresh scan.
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            pendingConnectID = id
            log("Smart Band 10: device \(id) not cached — scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("Smart Band 10: Bluetooth not powered on — connect deferred until ready")
            return
        }
        log("Smart Band 10: connecting to \(id)")
        central.connect(p, options: nil)
    }

    public func stop() {
        // Deliberate teardown — the reconnect backoff must NOT fire after this. Set before the peripheral
        // cancel so the resulting didDisconnectPeripheral sees it and suppresses the reconnect.
        intentionalDisconnect = true
        reconnectID = nil
        reconnectAttempt = 0
        stopScan()
        pendingConnectID = nil
        cancelTasks()
        cancelSyncWaits()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        session = nil
        framer.reset()
        sessionConfigSent = false
        isAuthenticated = false
        authRetryAttempted = false
        rxCharacteristic = nil
        txCharacteristic = nil
        batteryCharacteristic = nil
        loggedFirstHR = false
        zeroHrCount = 0
        batteryPct = nil
        flush()
        connected = false
        if feedsLive {
            live.connected = false
            live.streamingLiveHR = false
        }
        status = "Disconnected"
    }

    // MARK: - Handshake

    private func beginHandshakeIfReady() {
        guard !sessionConfigSent,
              let rx = rxCharacteristic, rx.isNotifying,
              let session, txCharacteristic != nil else { return }
        sessionConfigSent = true
        status = "Initializing SPP…"
        sendRaw(session.start())
    }

    private func didAuthenticate(encrypted: Bool) {
        isAuthenticated = true
        authRetryAttempted = false
        zeroHrCount = 0
        status = encrypted ? "Authenticated (encrypted)" : "Authenticated (cleartext)"
        connected = true
        if feedsLive { live.connected = true }
        log("Smart Band 10: authenticated encrypted=\(encrypted) — post-auth init")

        // Post-auth init handshake FIRST (setCurrentTime + deviceInfo + deviceStateGet + battery + config
        // reads). The Band 10 re-sends its CMD_AUTH confirmation every ~6s until it receives this; sending
        // a data command (e.g. realtime subtype 45) before it makes the band drop the BLE link
        // (CBError code=7). Only after the init do we start the realtime stream, then the activity sync.
        sendSessionPackets {
            guard let session = self.session else { return [] }
            return try session.postAuthInit()
        }
        startRealtimeLoop()
        // Re-arm the periodic activity re-sync (the same 900 s cadence Oura / the WHOOP offload use) so a
        // connection left open keeps pulling freshly-banked band data; the timer's first fire is minutes
        // after the initial sync below, and syncActivity's own guards make any overlap a no-op.
        startSyncTimer()
        // After the band settles (a few seconds past auth + init), pull the full activity channel once.
        // The sync stops/restarts the realtime poll itself, so it is safe to overlap the initial start.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.isAuthenticated else { return }
            await self.syncActivity()
        }
    }

    private func authFailed() {
        // The Band 10 NORMALLY requires TWO consecutive auth handshakes: the first HMAC always mismatches
        // — the watch is still holding the encryption keys from a previous link — and only the retry
        // (which re-runs the whole handshake with a fresh session) succeeds. A first mismatch is the
        // EXPECTED path, not a wrong token. We drop the link and re-handshake once; only if the RETRY also
        // fails do we declare the key wrong.
        guard !authRetryAttempted else {
            status = "Auth failed — wrong bind token?"
            needsPairing = "The band rejected the auth key twice. Double-check the 32-hex Xiaomi bind token " +
                           "for this band, or log in to your Xiaomi account again."
            // Drop the BLE link so `session` nils out (didDisconnectPeripheral) — with the peripheral left
            // connected, a user who corrects the key and taps Connect would hit makeSessionIfNeeded()'s
            // early return (`session != nil`) and the stale key would never be re-read. Mirrors
            // OuraLiveSource's cancel on adopt failure. Also suppress the reconnect backoff: this is a
            // deliberate teardown, the link died for a reason a timer can't fix.
            intentionalDisconnect = true
            reconnectID = nil
            reconnectAttempt = 0
            pendingConnectID = nil
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        // First failure: the expected stale-session HMAC mismatch. Re-run the handshake once.
        authRetryAttempted = true
        status = "Re-authenticating…"
        log("Smart Band 10: first auth HMAC mismatch (expected on Band 10) — re-handshaking")
        forceReconnect()
    }

    private func forceReconnect() {
        let pToReconnect = peripheral ?? reconnectID.flatMap { seenPeripherals[$0] ?? central.retrievePeripherals(withIdentifiers: [$0]).first }
        guard let p = pToReconnect else {
            log("Smart Band 10: no live peripheral for auth re-handshake — re-connecting by id")
            if let id = reconnectID { connect(id) }
            return
        }
        session = nil
        framer.reset()
        sessionConfigSent = false
        isAuthenticated = false
        rxCharacteristic = nil
        txCharacteristic = nil
        central.cancelPeripheralConnection(p)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            self.peripheral = p
            p.delegate = self
            self.makeSessionIfNeeded()
            self.log("Smart Band 10: re-connecting for auth retry...")
            self.central.connect(p, options: nil)
        }
    }

    // MARK: - Realtime stream (subtype 45 start, then band pushes subtype 47)

    private func startRealtimeLoop() {
        realtimeTask?.cancel()
        zeroHrCount = 0

        realtimeTask = Task { @MainActor [weak self] in
            // Give the post-auth init handshake time to be answered before the first realtime request.
            // Sending it too early (right on top of the init) caused the CBError code=7 drop.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.isAuthenticated else { return }
            self.sendSession { try self.session?.startRealtime() }
            if self.feedsLive { self.live.streamingLiveHR = true }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, self.isAuthenticated else { break }
                self.sendSession { try self.session?.startRealtime() }
            }
        }
    }

    /// Halt the periodic realtime poll so it doesn't interleave `8,45` requests into an in-flight
    /// activity-sync transfer (that interleaving stalls the channel-5 stream and drags the sync out).
    private func stopRealtimeLoop() {
        realtimeTask?.cancel()
        realtimeTask = nil
    }

    /// Auto-pause the realtime poll once the band reports 0 bpm for long enough (off-wrist) that
    /// continuing to request HR is just wasted `8,45` traffic.
    private func pauseRealtime() {
        guard realtimeTask != nil else { return }
        zeroHrCount = 0
        stopRealtimeLoop()
        if feedsLive { live.streamingLiveHR = false }
        log("Smart Band 10: realtime auto-paused — 0 bpm for \(realtimeStallLimit) polls")
    }

    // MARK: - Activity sync (channel 5: sleep / HRV / R-R / SpO2 / steps / daily rollups)

    private func startSyncTimer() {
        stopSyncTimer()
        let t = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncActivity() }
        }
        syncTimer = t
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    /// Pull the band's full activity channel: today + past file lists, then each file (reassembled +
    /// parsed by the protocol package), then hand the parsed files to `persistFiles` (the importer).
    /// Idempotent: files are not acked (`keepActivityData`), so re-syncing re-reads them and the importer
    /// upserts.
    public func syncActivity() async {
        guard let session, isAuthenticated else {
            status = "Connect to the band first"
            return
        }
        guard !syncIsRunning else { return }
        syncIsRunning = true
        lastSyncSummary = nil
        session.keepActivityData = true

        // Stop the 5s realtime poll for the duration of the transfer — its `8,45` requests interleave
        // with the channel-5 file chunks and stall the stream. Restart it once the sync is done.
        stopRealtimeLoop()
        defer {
            syncIsRunning = false
            if isAuthenticated { startRealtimeLoop() }
        }

        // 1. Fetch the file list (today + past), deduped.
        var ids: [ActivityFileId] = []
        status = "Fetching file list…"
        sendSession { try session.fetchActivityToday() }
        if let today = await waitForFileIds() { ids += today }
        sendSession { try session.fetchActivityPast() }
        if let past = await waitForFileIds() { ids += past }

        var seen = Set<[UInt8]>()
        let unique = ids.filter { seen.insert($0.bytes).inserted }

        // 2. Request each file, one at a time, reassembled + parsed by the session.
        var parsed: [ParsedActivityFile] = []
        for (index, fileId) in unique.enumerated() {
            status = "Syncing \(index + 1)/\(unique.count) · \(fileId.typeName) \(fileId.subtypeName)"
            sendSession { try session.requestActivityFile(fileId) }
            if let file = await waitForFile() {
                parsed.append(file)
                log("Smart Band 10: synced \(file.fileId.typeName) \(file.fileId.subtypeName) " +
                    "\(file.error ?? "ok")")
            }
        }

        // 3. Persist into the WhoopStore tables (off the main actor's work is the importer's own async).
        if !parsed.isEmpty {
            persistFiles(parsed)
            status = unique.isEmpty ? "No new data" : "Synced \(unique.count) file(s)"
            lastSyncSummary = "Synced \(parsed.count) file(s)"
        } else {
            status = unique.isEmpty ? "No new data" : "Sync complete (nothing new)"
            lastSyncSummary = unique.isEmpty ? "No new data" : "Already up to date"
        }
    }

    private func waitForFileIds() async -> [ActivityFileId]? {
        await withCheckedContinuation { continuation in
            fileIdsContinuation = continuation
            armSyncTimeout(forFileIds: true)
        }
    }

    private func waitForFile() async -> ParsedActivityFile? {
        await withCheckedContinuation { continuation in
            fileContinuation = continuation
            armSyncTimeout(forFileIds: false)
        }
    }

    /// Resume the pending sync continuation with `nil` after 6 s — mirrors the Python client's per-step
    /// `wait_for(..., timeout=6)`.
    private func armSyncTimeout(forFileIds: Bool) {
        syncTimeoutTask?.cancel()
        syncTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if forFileIds {
                guard let pending = self.fileIdsContinuation else { return }
                self.fileIdsContinuation = nil
                pending.resume(returning: nil)
            } else {
                guard let pending = self.fileContinuation else { return }
                self.fileContinuation = nil
                pending.resume(returning: nil)
            }
        }
    }

    // MARK: - Event dispatch (Session.Event)

    private func handle(event: Session.Event) {
        switch event {
        case .battery(let battery):
            batteryPct = Int(battery.level)
            onBattery(Int(battery.level))
            // Bank it into the `battery` table (BatterySample → StreamStore battery rows) so the band's
            // charge history persists and charts across connects, like Oura's BatterySample walk.
            batteryBuffer.append(BatterySample(ts: Int(Date().timeIntervalSince1970),
                                               soc: Double(battery.level),
                                               mv: nil,
                                               charging: nil))
        case .realtime(let sample):
            if sample.heartRate > 10 {
                zeroHrCount = 0
                ingest(hr: Int(sample.heartRate))
            } else {
                // The band pushes realtime packets even when it has no reading (off-wrist or between
                // samples). Give it a grace period, then stop the poll instead of hammering it forever.
                zeroHrCount += 1
                if zeroHrCount >= realtimeStallLimit { pauseRealtime() }
            }
        case .activityFileIds(let ids):
            syncTimeoutTask?.cancel()
            if let continuation = fileIdsContinuation {
                fileIdsContinuation = nil
                continuation.resume(returning: ids)
            }
        case .activityFile(let parsed):
            syncTimeoutTask?.cancel()
            if let continuation = fileContinuation {
                fileContinuation = nil
                continuation.resume(returning: parsed)
            } else {
                // Arrived after our request timed out — still keep it for the current sync.
                log("Smart Band 10: late activity file arrived — buffered for next sync")
            }
        case .deviceInfo(let info):
            log("Smart Band 10: device \(info.model) FW \(info.firmware)")
        case .heartRateConfig, .spo2Config, .stressConfig, .dndConfig, .unknown:
            break
        }
    }

    // MARK: - Live HR buffer / persistence

    private func enqueue(hr: Int) {
        buffer.append((hr: hr, ts: Int(Date().timeIntervalSince1970)))
        if buffer.count >= flushCount || Date().timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    private func flush() {
        if !buffer.isEmpty {
            // HR-only mapping for the live channel (the band's realtime packet has no R-R; R-R lives in
            // the sleep files and arrives via the importer). Same HR→Streams mapping the generic strap
            // path uses, so persisted rows are identical in shape and source-tagged by id.
            for sample in buffer {
                persist(StandardHRMapping.samples(fromHR: sample.hr, rr: [], at: sample.ts))
            }
            buffer.removeAll()
        }
        if !batteryBuffer.isEmpty {
            // Persist banked battery readings into the `battery` table (ON CONFLICT(deviceId, ts) DO
            // NOTHING keeps re-reads/idempotent). The coordinator's persist closure routes it to the store.
            persist(Streams(events: [], battery: batteryBuffer))
            batteryBuffer.removeAll()
        }
        lastFlush = Date()
    }

    /// Fold a decoded HR into live state + the buffer. Range-gated to the same physiological window the
    /// standard path uses; an out-of-range value is dropped (never shown).
    private func ingest(hr: Int) {
        guard hr >= 30, hr <= 220 else { return }
        if !loggedFirstHR {
            loggedFirstHR = true
            log("Smart Band 10: receiving data — first sample \(hr) bpm")
        }
        if feedsLive {
            live.heartRate = hr
            live.connected = true
        }
        enqueue(hr: hr)
    }

    // MARK: - TX / RX

    private func sendSession(_ build: () throws -> Data?) {
        do {
            if let data = try build() { sendRaw(data) }
        } catch {
            log("Smart Band 10: session command failed — \(error.localizedDescription)")
        }
    }

    private func sendSessionPackets(_ build: () throws -> [Data]) {
        do {
            for data in try build() { sendRaw(data) }
        } catch {
            log("Smart Band 10: session command failed — \(error.localizedDescription)")
        }
    }

    private func sendRaw(_ data: Data) {
        guard let peripheral, let tx = txCharacteristic else {
            log("Smart Band 10: cannot send — peripheral=\(peripheral != nil) tx=\(txCharacteristic != nil)")
            return
        }
        // The Xiaomi 005F characteristic is write-without-response (Gadgetbridge writes WRITE_TYPE_NO_RESPONSE
        // by default). Prefer that, and only fall back to .withResponse when no-response isn't advertised.
        let writeType: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = peripheral.maximumWriteValueLength(for: writeType)
        if data.count <= mtu {
            peripheral.writeValue(data, for: tx, type: writeType)
        } else {
            var offset = 0
            while offset < data.count {
                let chunk = data.subdata(in: offset..<min(offset + mtu, data.count))
                peripheral.writeValue(chunk, for: tx, type: writeType)
                offset += mtu
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        let packets = framer.push(data)
        guard let session else { return }
        for packet in packets {
            do {
                let responses = try session.handle(type: packet.type, sequence: packet.sequence, payload: packet.payload)
                for response in responses { sendRaw(response) }
            } catch {
                log("Smart Band 10: session.handle failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Teardown

    private func cancelTasks() {
        realtimeTask?.cancel(); realtimeTask = nil
        syncTimeoutTask?.cancel(); syncTimeoutTask = nil
        connectTimeoutTask?.cancel(); connectTimeoutTask = nil
        stopSyncTimer()
    }

    /// Resume any in-flight sync wait with `nil` so a disconnect mid-sync doesn't leave `syncActivity()`
    /// suspended forever.
    private func cancelSyncWaits() {
        syncTimeoutTask?.cancel(); syncTimeoutTask = nil
        if let continuation = fileIdsContinuation {
            fileIdsContinuation = nil
            continuation.resume(returning: nil)
        }
        if let continuation = fileContinuation {
            fileContinuation = nil
            continuation.resume(returning: nil)
        }
    }

    /// Re-reach the band after an involuntary drop (`didDisconnectPeripheral` with an error) or a failed
    /// connect, unless the teardown was intentional (`stop()`, auth-failure cancel) or there is no known id.
    ///
    /// Mirrors `OuraLiveSource.scheduleReconnect()`: the first attempts use a short timed backoff (the app is
    /// awake — it just received the callback — so a 3s/6s/12s retry fixes a transient blip fast), capped at
    /// 60 s so a long outage never hot-loops. Unlike Oura we don't keep a STANDING CoreBluetooth connect
    /// outstanding across the phone's suspension — SmartBand10Source has no state-restoration surface yet,
    /// and the capped timer still re-arms on resume within 60 s. Every wake re-checks `intentionalDisconnect`
    /// and that the target id is unchanged, so a deliberate teardown never races a stale reconnect.
    private func scheduleReconnect() {
        guard !intentionalDisconnect, let id = reconnectID else { return }
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        let delay = min(60.0, 3.0 * pow(2.0, Double(reconnectAttempt - 1)))
        log("Smart Band 10: reconnecting in \(Int(delay))s (attempt \(reconnectAttempt))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect, self.reconnectID == id else { return }
            self.connect(id)
        }
    }
}

// MARK: - LiveHRSource conformance

extension SmartBand10Source: LiveHRSource {}

// MARK: - CBCentralManagerDelegate

extension SmartBand10Source: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: nil,
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        default:
            if feedsLive { live.connected = false }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        // The same Xiaomi-band name filter the reference client uses — the band advertises a name
        // containing "Xiaomi" / "Band" / "Smart". (Recognition-only would be too brittle; the advertised
        // string is firmware-dependent.)
        guard name.contains("Xiaomi") || name.contains("Band") || name.contains("Smart") else { return }
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        if firstSight { log("Smart Band 10: found \(name) (\(id)) rssi \(RSSI.intValue)") }
        let dev = DiscoveredDevice(id: id, name: name.isEmpty ? "Smart Band 10" : name, rssi: RSSI.intValue)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = dev
        } else {
            discovered.append(dev)
        }
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Smart Band 10: connected — discovering services")
        // A real connection clears the reconnect backoff (mirrors Oura #912) — the next drop starts fresh.
        reconnectAttempt = 0
        status = "Connected, discovering…"
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Smart Band 10: WARNING failed to connect — \(error?.localizedDescription ?? "unknown error")")
        if feedsLive { live.connected = false }
        connected = false
        status = "Connect failed"
        // A failed connect is an involuntary miss — re-issue unless we tore down deliberately.
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Smart Band 10: disconnected\(error.map { " — \($0.localizedDescription)" } ?? " (clean)")")
        let wasInvoluntary = error != nil
        cancelTasks()
        cancelSyncWaits()
        isAuthenticated = false
        session = nil
        framer.reset()
        sessionConfigSent = false
        rxCharacteristic = nil
        txCharacteristic = nil
        batteryCharacteristic = nil
        loggedFirstHR = false
        zeroHrCount = 0
        batteryPct = nil
        flush()
        connected = false
        if feedsLive {
            live.connected = false
            live.streamingLiveHR = false
        }
        status = "Disconnected"
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
        // An involuntary drop (band out of range, battery killed the link, remote reset) reconnects
        // automatically; a clean disconnect — including our own cancelPeripheralConnection in stop() and
        // the auth-failure cancel — stays down.
        if wasInvoluntary { scheduleReconnect() }
    }
}

// MARK: - CBPeripheralDelegate

extension SmartBand10Source: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Smart Band 10: WARNING service discovery failed — \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            if char.uuid == rxNotify { rxCharacteristic = char }
            if char.uuid == txWrite { txCharacteristic = char }
            if char.uuid == batteryLevel {
                batteryCharacteristic = char
                if char.properties.contains(.notify) { peripheral.setNotifyValue(true, for: char) }
                if char.properties.contains(.read) { peripheral.readValue(for: char) }
            }
            // Subscribe to every notifiable characteristic and read every readable one — the RX notify
            // (005E) subscription is what makes the band start speaking SPPv2, and reading a potentially
            // encrypted char is the pairing/bonding trigger.
            if char.properties.contains(.notify) { peripheral.setNotifyValue(true, for: char) }
            if char.properties.contains(.read) { peripheral.readValue(for: char) }
        }
        beginHandshakeIfReady()
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == rxNotify, characteristic.isNotifying else { return }
        beginHandshakeIfReady()
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Standard GATT battery (2A19): update batteryPct without SPPv2. If the read fails with
        // insufficientAuthentication it means the char is encrypted and iOS should prompt to pair — not fatal.
        if characteristic.uuid == batteryLevel {
            if let error = error {
                let nsErr = error as NSError
                if nsErr.domain == CBATTErrorDomain, nsErr.code == CBATTError.insufficientAuthentication.rawValue {
                    log("Smart Band 10: battery needs authentication — pairing should be triggered")
                } else {
                    log("Smart Band 10: battery read error — \(nsErr.domain) code=\(nsErr.code)")
                }
                return
            }
            if let data = characteristic.value, let level = data.first {
                batteryPct = Int(level)
                onBattery(Int(level))
                batteryBuffer.append(BatterySample(ts: Int(Date().timeIntervalSince1970),
                                                   soc: Double(level),
                                                   mv: nil,
                                                   charging: nil))
                log("Smart Band 10: battery \(level)%")
            }
            return
        }
        guard characteristic.uuid == rxNotify, let data = characteristic.value else { return }
        handleIncoming(data)
    }
}

// MARK: - Smart Band 10 auth-key store (Keychain)

/// Generic-password Keychain store for the band's 32-hex Xiaomi bind token (16 bytes), following the
/// `OuraKeyStore` pattern (`Strand/BLE/OuraLiveSource.swift`) so the key never lands in UserDefaults, a
/// plist, or on disk in the clear. Scoped per `deviceId` (the `account`), so each registered band has its
/// own item. Written from exactly two places: the wizard's manual key field and the optional Xiaomi
/// account login.
public enum SmartBand10KeyStore {
    private static let service = "com.noop.smartband10.authkey"
    /// 32 hex chars == 16 bytes.
    public static let keyLength = 16

    private static func baseQuery(deviceId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
        ]
    }

    /// Store (or replace) the 16-byte bind token for `deviceId`. A wrong-length key is rejected (no
    /// partial key is ever stored, so a later read can't return a malformed key).
    @discardableResult
    public static func save(_ key: Data, deviceId: String) -> Bool {
        guard key.count == keyLength else { return false }
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
        var attrs = baseQuery(deviceId: deviceId)
        attrs[kSecValueData as String] = key
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Read the stored 16-byte bind token for `deviceId`, or nil if none is set (or the stored item is
    /// the wrong length, treated as absent so the honest needs-pairing path runs).
    public static func read(deviceId: String) -> Data? {
        var query = baseQuery(deviceId: deviceId)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == keyLength else { return nil }
        return data
    }

    /// Remove the stored bind token for `deviceId`.
    public static func clear(deviceId: String) {
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
    }
}
