import XCTest
@testable import SmartBand10Protocol

final class CommandTests: XCTestCase {
    func testRealtimeEnableHasNoHealthField() {
        let cmd = Commands.realtimeEnable()
        XCTAssertEqual(cmd.type, 8)
        XCTAssertEqual(cmd.subtype, 45)
        XCTAssertFalse(cmd.hasHealth)
    }

    func testDeviceInfoSubtype() {
        let cmd = Commands.deviceInfo()
        XCTAssertEqual(cmd.type, 2)
        XCTAssertEqual(cmd.subtype, 2)
    }

    func testBatterySubtype() {
        let cmd = Commands.battery()
        XCTAssertEqual(cmd.type, 2)
        XCTAssertEqual(cmd.subtype, 1)
    }

    func testParseDeviceInfo() {
        var cmd = Xiaomi_Command()
        cmd.type = 2
        cmd.subtype = 2
        var sys = Xiaomi_System()
        var info = Xiaomi_DeviceInfo()
        info.model = "M2345B1"
        info.firmware = "1.2.3"
        info.serialNumber = "SN123"
        sys.deviceInfo = info
        cmd.system = sys
        XCTAssertEqual(
            Commands.parseDeviceInfo(cmd),
            DeviceInfo(model: "M2345B1", firmware: "1.2.3", serial: "SN123")
        )
    }

    func testParseBattery() {
        var cmd = Xiaomi_Command()
        cmd.type = 2
        cmd.subtype = 1
        var sys = Xiaomi_System()
        var power = Xiaomi_Power()
        var battery = Xiaomi_Battery()
        battery.level = 87
        battery.state = 1
        power.battery = battery
        sys.power = power
        cmd.system = sys
        XCTAssertEqual(Commands.parseBattery(cmd), Battery(level: 87, state: 1))
    }

    func testParseRealtime() {
        var cmd = Xiaomi_Command()
        cmd.type = 8
        cmd.subtype = 47
        var health = Xiaomi_Health()
        var rts = Xiaomi_RealTimeStats()
        rts.heartRate = 72
        rts.steps = 1234
        rts.calories = 500
        rts.standingHours = 3
        health.realTimeStats = rts
        cmd.health = health
        XCTAssertEqual(
            Commands.parseRealtime(cmd),
            RealtimeSample(heartRate: 72, steps: 1234, calories: 500, standingHours: 3)
        )
    }

    func testParseReturnsNilWhenAbsent() {
        var cmd = Xiaomi_Command()
        cmd.type = 8
        cmd.subtype = 47
        XCTAssertNil(Commands.parseRealtime(cmd))
        XCTAssertNil(Commands.parseDeviceInfo(cmd))
        XCTAssertNil(Commands.parseBattery(cmd))
    }
}
