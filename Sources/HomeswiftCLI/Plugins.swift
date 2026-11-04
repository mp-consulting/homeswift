import HomeswiftDaikinCloud
import HomeswiftDirigera
import HomeswiftDolphinPoolCleaner
import HomeswiftDummy
import HomeswiftDysonPureCool
import HomeswiftESPHome
import HomeswiftEWeLink
import HomeswiftEcoFlow
import HomeswiftElgatoKeyLights
import HomeswiftGoogleNestSDM
import HomeswiftGovee
import HomeswiftHTTPWebhooks
import HomeswiftIPCameras
import HomeswiftImou
import HomeswiftLGThinQ
import HomeswiftMQTTThing
import HomeswiftPhilipsAmbilightTV
import HomeswiftPhilipsHue
import HomeswiftPlugin
import HomeswiftRing
import HomeswiftRoborock
import HomeswiftShelly
import HomeswiftSonos
import HomeswiftSwitchBot
import HomeswiftTPLinkSmarthome
import HomeswiftTado
import HomeswiftTapo
import HomeswiftTuya
import HomeswiftUniFiAccess
import HomeswiftUniFiProtect
import HomeswiftWingman
import HomeswiftZigbee2MQTT

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
    registry.register(EcoFlowPlugin.self)
    registry.register(IPCamerasPlugin.self)
    registry.register(SonosPlugin.self)
    registry.register(TuyaPlugin.self)
    registry.register(SwitchBotPlugin.self)
    registry.register(TadoPlugin.self)
    registry.register(RoborockPlugin.self)
    registry.register(GoogleNestSDMPlugin.self)
    registry.register(DummyPlugin.self)
    registry.register(MQTTThingPlugin.self)
    registry.register(ESPHomePlugin.self)
    registry.register(ShellyNGPlugin.self)
    registry.register(ShellyPlugin.self)
    registry.register(TPLinkSmarthomePlugin.self)
    registry.register(Zigbee2MQTTPlugin.self)
    registry.register(TapoPlugin.self)
    registry.register(HTTPWebhooksPlugin.self)
    registry.register(RingPlugin.self)
    registry.register(ImouPlugin.self)
    return registry
}
