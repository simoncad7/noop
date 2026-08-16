import Foundation

/// High-level value types exposed by the protocol layer. The protobuf
/// (`xiaomi.pb.swift`) is fully encapsulated and stays internal to this target.
public struct DeviceInfo: Equatable {
    public let model: String
    public let firmware: String
    public let serial: String

    public init(model: String, firmware: String, serial: String) {
        self.model = model
        self.firmware = firmware
        self.serial = serial
    }
}

public struct Battery: Equatable {
    public let level: UInt32
    public let state: UInt32

    public init(level: UInt32, state: UInt32) {
        self.level = level
        self.state = state
    }
}

public struct RealtimeSample: Equatable {
    public let heartRate: UInt32
    public let steps: UInt32
    public let calories: UInt32
    public let standingHours: UInt32

    public init(heartRate: UInt32, steps: UInt32, calories: UInt32, standingHours: UInt32) {
        self.heartRate = heartRate
        self.steps = steps
        self.calories = calories
        self.standingHours = standingHours
    }
}
