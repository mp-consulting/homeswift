import HomeswiftElgatoKeyLights
import HomeswiftPhilipsAmbilightTV
import HomeswiftPlugin

/// The plugins compiled into this binary.
///
/// To add one: give it a target in Package.swift (see `HomeswiftElgatoKeyLights`), add that target to the
/// `homeswift` executable's dependencies, import it here and register its type. `homeswift plugins` lists
/// what is registered.
func builtInPlugins() -> PluginRegistry {
    var registry = PluginRegistry()
    registry.register(ElgatoKeyLightsPlugin.self)
    registry.register(PhilipsAmbilightTVPlugin.self)
    return registry
}
