import Foundation

/// Internal command builders/parsers (port of `xiaomi_band/ble_client.py`).
/// The protobuf types stay internal to this target; the public `Session`
/// exposes only `DeviceInfo`/`Battery`/`RealtimeSample` and `Data`.
enum Commands {
    // MARK: - Command subtype constants

    enum CommandType {
        static let auth: UInt32 = 1
        static let system: UInt32 = 2
        static let health: UInt32 = 8
    }

    enum SystemSubtype {
        static let battery: UInt32 = 1
        static let deviceInfo: UInt32 = 2
        static let clock: UInt32 = 3
        static let deviceStateGet: UInt32 = 78
    }

    enum HealthSubtype {
        static let activityFetchToday: UInt32 = 1
        static let activityFetchPast: UInt32 = 2
        static let activityRequestFile: UInt32 = 3
        static let activityAckFile: UInt32 = 5
        static let realtimeEnable: UInt32 = 45
        static let realtimeStop: UInt32 = 46
        static let realtimeStream: UInt32 = 47 // watch → phone (also the BLE poll request)
    }

    enum AuthSubtype {
        static let phoneNonce: UInt32 = 26
        static let step3: UInt32 = 27
        static let cleartextOk: UInt32 = 5
    }

    // MARK: - Builders

    static func command(type: UInt32, subtype: UInt32) -> Xiaomi_Command {
        var cmd = Xiaomi_Command()
        cmd.type = type
        cmd.subtype = subtype
        return cmd
    }

    /// `Command{type=2, subtype=2}` → device info request.
    static func deviceInfo() -> Xiaomi_Command {
        return command(type: CommandType.system, subtype: SystemSubtype.deviceInfo)
    }

    /// `Command{type=2, subtype=1}` → battery request.
    static func battery() -> Xiaomi_Command {
        return command(type: CommandType.system, subtype: SystemSubtype.battery)
    }

    /// `Command{type=2, subtype=78}` → device state request (post-auth init).
    static func deviceStateGet() -> Xiaomi_Command {
        return command(type: CommandType.system, subtype: SystemSubtype.deviceStateGet)
    }

    /// `Command{type=2, subtype=3}` — set the band's clock (time + date + tz).
    ///
    /// This is the FIRST command of the post-auth init handshake. Mirrors
    /// Gadgetbridge `XiaomiSupport.onAuthSuccess()`: setCurrentTime() followed by
    /// deviceInfo / deviceStateGet / battery. Sending a data command before this
    /// handshake makes the Band 10 re-drive auth every ~6s and then drop the link.
    static func setCurrentTime() -> Xiaomi_Command {
        let now = Date()
        let cal = Calendar.current
        let tz = TimeZone.current
        let comps = cal.dateComponents(in: tz, from: now)

        var time = Xiaomi_Time()
        time.hour = UInt32(comps.hour ?? 0)
        time.minute = UInt32(comps.minute ?? 0)
        time.second = UInt32(comps.second ?? 0)

        var date = Xiaomi_Date()
        date.year = UInt32(comps.year ?? 2025)
        date.month = UInt32(comps.month ?? 1)
        date.day = UInt32(comps.day ?? 1)

        // Offsets are in 15-minute blocks, mirroring Gadgetbridge exactly
        // (`Calendar.ZONE_OFFSET` / `DST_OFFSET`): `zoneOffset` is the RAW
        // standard-time offset (DST EXCLUDED), `dstOffset` is the DST delta on
        // top of it. Using `secondsFromGMT` — which already folds DST in — for
        // `zoneOffset` double-counts the DST hour and leaves the watch 1h off.
        let dstSecs = Int(tz.daylightSavingTimeOffset(for: now))
        let rawOffset = tz.secondsFromGMT(for: now) - dstSecs
        let zoneOffset = Int32(rawOffset / (15 * 60))
        let dstOffset = Int32(dstSecs / (15 * 60))

        var tzMsg = Xiaomi_TimeZone()
        tzMsg.zoneOffset = zoneOffset
        if dstOffset != 0 { tzMsg.dstOffset = dstOffset }
        tzMsg.name = tz.identifier

        var clock = Xiaomi_Clock()
        clock.date = date
        clock.time = time
        clock.timezone = tzMsg

        var system = Xiaomi_System()
        system.clock = clock

        var cmd = command(type: CommandType.system, subtype: SystemSubtype.clock)
        cmd.system = system
        return cmd
    }

    /// `Command{type=8, subtype=45}` — START the realtime stats stream.
    ///
    /// Per Gadgetbridge (`XiaomiHealthService.enableRealtimeStats`) and the
    /// working Python RFCOMM client, this is a BARE command with NO `health`
    /// field. The band then pushes `Command{type=8, subtype=47}` events carrying
    /// `health.realTimeStats.heartRate`. `subtype=46` stops the stream.
    static func realtimeEnable() -> Xiaomi_Command {
        return command(type: CommandType.health, subtype: HealthSubtype.realtimeEnable)
    }

    /// `Command{type=8, subtype=46}` — stop realtime.
    static func realtimeStop() -> Xiaomi_Command {
        return command(type: CommandType.health, subtype: HealthSubtype.realtimeStop)
    }

    // MARK: - Activity sync (channel 5)

    /// `Command{type=8, subtype=1}` — request the list of today's activity files.
    ///
    /// Mirrors `ble_client.py` `fetch_activity_today`: the `activitySyncRequestToday`
    /// sub-message must be present (with `unknown1 = 0`).
    static func activityFetchToday() -> Xiaomi_Command {
        var cmd = command(type: CommandType.health, subtype: HealthSubtype.activityFetchToday)
        var health = Xiaomi_Health()
        var request = Xiaomi_ActivitySyncRequestToday()
        request.unknown1 = 0
        health.activitySyncRequestToday = request
        cmd.health = health
        return cmd
    }

    /// `Command{type=8, subtype=2}` — request the list of past activity files.
    static func activityFetchPast() -> Xiaomi_Command {
        return command(type: CommandType.health, subtype: HealthSubtype.activityFetchPast)
    }

    /// `Command{type=8, subtype=3}` — request one file by its 7-byte id.
    static func activityRequestFile(_ fileId: ActivityFileId) -> Xiaomi_Command {
        var cmd = command(type: CommandType.health, subtype: HealthSubtype.activityRequestFile)
        var health = Xiaomi_Health()
        health.activityRequestFileIds = Data(fileId.bytes)
        cmd.health = health
        return cmd
    }

    /// `Command{type=8, subtype=5}` — acknowledge a received file (tells the watch
    /// it may delete it). Only sent when `Session.keepActivityData == false`.
    static func activityAckFile(_ fileId: ActivityFileId) -> Xiaomi_Command {
        var cmd = command(type: CommandType.health, subtype: HealthSubtype.activityAckFile)
        var health = Xiaomi_Health()
        health.activitySyncAckFileIds = Data(fileId.bytes)
        cmd.health = health
        return cmd
    }

    // MARK: - Auth command builders

    /// `Command{type=1, subtype=26}` — send phone nonce.
    static func authPhoneNonce(_ nonce: Data) -> Xiaomi_Command {
        var cmd = command(type: CommandType.auth, subtype: AuthSubtype.phoneNonce)
        var auth = Xiaomi_Auth()
        var phoneNonce = Xiaomi_PhoneNonce()
        phoneNonce.nonce = nonce
        auth.phoneNonce = phoneNonce
        cmd.auth = auth
        return cmd
    }

    /// `Command{type=1, subtype=27}` — send auth step 3.
    static func authStep3(encryptedNonces: Data, encryptedDeviceInfo: Data) -> Xiaomi_Command {
        var cmd = command(type: CommandType.auth, subtype: AuthSubtype.step3)
        var auth = Xiaomi_Auth()
        var step3 = Xiaomi_AuthStep3()
        step3.encryptedNonces = encryptedNonces
        step3.encryptedDeviceInfo = encryptedDeviceInfo
        auth.authStep3 = step3
        cmd.auth = auth
        return cmd
    }

    // MARK: - Parsers

    /// Parse `system.deviceInfo`, if present.
    static func parseDeviceInfo(_ cmd: Xiaomi_Command) -> DeviceInfo? {
        guard cmd.hasSystem, cmd.system.hasDeviceInfo else { return nil }
        let info = cmd.system.deviceInfo
        return DeviceInfo(model: info.model, firmware: info.firmware, serial: info.serialNumber)
    }

    /// Parse `system.power.battery`, if present.
    static func parseBattery(_ cmd: Xiaomi_Command) -> Battery? {
        guard cmd.hasSystem, cmd.system.hasPower, cmd.system.power.hasBattery else { return nil }
        let battery = cmd.system.power.battery
        return Battery(level: battery.level, state: battery.state)
    }

    /// Parse `health.realTimeStats`, if present (the `type=8, subtype=47` stream).
    static func parseRealtime(_ cmd: Xiaomi_Command) -> RealtimeSample? {
        guard cmd.hasHealth, cmd.health.hasRealTimeStats else { return nil }
        let rts = cmd.health.realTimeStats
        return RealtimeSample(
            heartRate: rts.heartRate,
            steps: rts.steps,
            calories: rts.calories,
            standingHours: rts.standingHours
        )
    }
    
    // MARK: - Configuration Builders

    /// `Command{type=8, subtype=11}` — Set heart rate tracking config.
    static func setHeartRateConfig(interval: UInt32, sleepAdvanced: Bool) -> Xiaomi_Command {
        var h = Xiaomi_HeartRate()
        h.disabled = false
        h.interval = interval // 0 = smart, 1 = 1min, 10 = 10min, 30 = 30min
        var adv = Xiaomi_AdvancedMonitoring()
        adv.enabled = sleepAdvanced
        h.advancedMonitoring = adv
        h.unknown7 = 1
        
        var cmd = command(type: CommandType.health, subtype: 11)
        var health = Xiaomi_Health()
        health.heartRate = h
        cmd.health = health
        return cmd
    }
    
    /// `Command{type=8, subtype=10}` — Get heart rate tracking config.
    static func getHeartRateConfig() -> Xiaomi_Command {
        return command(type: CommandType.health, subtype: 10)
    }

    /// `Command{type=8, subtype=9}` — Set SpO2 config.
    static func setSpO2Config(allDay: Bool) -> Xiaomi_Command {
        var sp = Xiaomi_SpO2()
        sp.unknown1 = 1
        sp.allDayTracking = allDay
        
        var cmd = command(type: CommandType.health, subtype: 9)
        var health = Xiaomi_Health()
        health.spo2 = sp
        cmd.health = health
        return cmd
    }
    
    /// `Command{type=8, subtype=8}` — Get SpO2 config.
    static func getSpO2Config() -> Xiaomi_Command {
        return command(type: CommandType.health, subtype: 8)
    }

    /// `Command{type=8, subtype=15}` — Set Stress config.
    static func setStressConfig(allDay: Bool) -> Xiaomi_Command {
        var st = Xiaomi_Stress()
        st.allDayTracking = allDay
        var relax = Xiaomi_RelaxReminder()
        relax.enabled = false
        relax.unknown2 = 0
        st.relaxReminder = relax
        
        var cmd = command(type: CommandType.health, subtype: 15)
        var health = Xiaomi_Health()
        health.stress = st
        cmd.health = health
        return cmd
    }
    
    /// `Command{type=8, subtype=14}` — Get Stress config.
    static func getStressConfig() -> Xiaomi_Command {
        return command(type: CommandType.health, subtype: 14)
    }

    /// `Command{type=2, subtype=23}` — Set Do Not Disturb.
    static func setDndConfig(enabled: Bool) -> Xiaomi_Command {
        var dnd = Xiaomi_DoNotDisturb()
        dnd.status = enabled ? 0 : 2
        
        var cmd = command(type: CommandType.system, subtype: 23)
        var system = Xiaomi_System()
        system.dndStatus = dnd
        cmd.system = system
        return cmd
    }
    
    /// `Command{type=2, subtype=22}` — Get Do Not Disturb.
    static func getDndConfig() -> Xiaomi_Command {
        return command(type: CommandType.system, subtype: 22)
    }
    
    // MARK: - Configuration Parsers
    
    static func parseHeartRateConfig(_ cmd: Xiaomi_Command) -> Xiaomi_HeartRate? {
        guard cmd.hasHealth, cmd.health.hasHeartRate else { return nil }
        return cmd.health.heartRate
    }
    
    static func parseSpO2Config(_ cmd: Xiaomi_Command) -> Xiaomi_SpO2? {
        guard cmd.hasHealth, cmd.health.hasSpo2 else { return nil }
        return cmd.health.spo2
    }
    
    static func parseStressConfig(_ cmd: Xiaomi_Command) -> Xiaomi_Stress? {
        guard cmd.hasHealth, cmd.health.hasStress else { return nil }
        return cmd.health.stress
    }
    
    static func parseDndConfig(_ cmd: Xiaomi_Command) -> Xiaomi_DoNotDisturb? {
        guard cmd.hasSystem, cmd.system.hasDndStatus else { return nil }
        return cmd.system.dndStatus
    }
}
