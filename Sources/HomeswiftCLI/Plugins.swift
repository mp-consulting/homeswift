import HomeswiftDaikinCloud
import HomeswiftDirigera
import HomeswiftDolphinPoolCleaner
import HomeswiftDysonPureCool
import HomeswiftEWeLink
import HomeswiftElgatoKeyLights
import HomeswiftGovee
import HomeswiftLGThinQ
import HomeswiftPhilipsAmbilightTV
import HomeswiftPhilipsHue
import HomeswiftPlugin
import HomeswiftUniFiAccess
import HomeswiftUniFiProtect
import HomeswiftWingman

/// The plugins compiled into this binary.
///
/// To add one: give it a target in Package.swift (see `HomeswiftElgatoKeyLights`), add that target to the
/// `homeswift` executable's dependencies, import it here and register its type. `homeswift plugins` lists
/// what is registered.
func builtInPlugins() -> PluginRegistry {
    var registry = PluginRegistry()
    registry.register(ElgatoKeyLightsPlugin.self)
    registry.register(PhilipsAmbilightTVPlugin.self)
    registry.register(DolphinPoolCleanerPlugin.self)
    registry.register(DysonPureCoolPlugin.self)
    registry.register(UniFiAccessPlugin.self)
    registry.register(DaikinCloudPlugin.self)
    registry.register(EWeLinkPlugin.self)
    registry.register(LGThinQPlugin.self)
    registry.register(GoveePlugin.self)
    registry.register(UniFiProtectPlugin.self)
    registry.register(WingmanPlugin.self)
    registry.register(PhilipsHuePlugin.self)
    registry.register(DirigeraPlugin.self)
    return registry
}
