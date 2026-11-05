import Foundation

/// What a camera that pans and tilts can do, for the web UI's live view (`HomeswiftPlugin.cameraControls`): the
/// directions it moves in, its presets, and whether it has a home position. HomeKit has no PTZ service, so this is the
/// web UI's own, next to the plugin's Assistant actions.
public struct CameraControls: Sendable, Codable, Equatable {
    public enum Direction: String, Sendable, Codable, CaseIterable {
        case up, down, left, right
    }

    public struct Preset: Sendable, Codable, Equatable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var directions: [Direction]
    public var presets: [Preset]
    /// Whether `CameraCommand.home` turns it to a home position.
    public var home: Bool

    public init(directions: [Direction] = Direction.allCases, presets: [Preset] = [], home: Bool = false) {
        self.directions = directions
        self.presets = presets
        self.home = home
    }
}

/// A move the web UI asks of a camera (`HomeswiftPlugin.controlCamera`).
public enum CameraCommand: Sendable, Equatable {
    /// One step in a direction: the live view sends another while the button is held.
    case move(CameraControls.Direction)
    /// Turns to one of `CameraControls.presets`, by its id.
    case preset(String)
    /// Turns to the home position.
    case home
}

/// A command the camera cannot carry out as asked (a direction it does not move in, a preset it does not have).
public struct CameraControlError: Error, CustomStringConvertible, Sendable, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
