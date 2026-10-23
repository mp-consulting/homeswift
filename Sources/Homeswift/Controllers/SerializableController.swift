import Foundation

/// A controller whose state must survive a restart (HAP-NodeJS's `SerializableController`): Adaptive Lighting
/// keeps its transition schedule, a camera its recording configuration. `PluginContext.configureController`
/// restores the state and saves it on every change; without a plugin runtime, call `deserialize` at launch and
/// save `serialize()` from the state change handler yourself.
public protocol SerializableController: AnyObject, Sendable {
    /// Unique among the controllers of one accessory, e.g. `characteristic-transition-<service id>`.
    var controllerID: String { get }
    /// The state to keep, or nil when there is nothing to keep.
    func serialize() -> Data?
    /// Restores a state `serialize()` returned.
    func deserialize(_ data: Data) throws
    /// Called with every change that `serialize()` would reflect.
    func setupStateChangeDelegate(_ delegate: (@Sendable () -> Void)?)
}
