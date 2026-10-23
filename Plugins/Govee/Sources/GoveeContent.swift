import Foundation
import HomeswiftPlugin

/// The Govee app's content: the scene library of a device, the account's DIY effects, and the modes a device
/// supports (`utils/govee-content.ts`). Unofficial endpoints the app itself calls; they can change without
/// notice, so every caller carries on without them.
enum GoveeContent {
    /// What identifies a device to the content endpoints.
    struct DeviceRef: Sendable, Equatable {
        var sku: String
        var device: String
        var goodsType: Int?
        var versionSoft: String?
        var versionHard: String?
        var wifiVersionSoft: String?
        var wifiVersionHard: String?
        var pactType: Int?
        var pactCode: Int?
    }

    /// One effect of a scene; scenes with several carry the speed or style variants the app offers.
    struct SceneVariant: Sendable, Equatable {
        var id: Int
        var name: String
        /// Comma-separated base64 frames, for the `rgbScene` command.
        var code: String
        var supportsSpeed: Bool
        var supportedDirections: [Int]
    }

    struct SceneEntry: Sendable, Equatable {
        var sceneId: Int
        var name: String
        var category: String
        var iconUrl: String?
        var iconUrlDark: String?
        var variants: [SceneVariant]
        /// The first variant's code.
        var code: String
    }

    struct SceneCategory: Sendable, Equatable {
        var id: Int
        var name: String
        var scenes: [SceneEntry]
    }

    struct SceneLibrary: Sendable, Equatable {
        enum Source: String, Sendable { case cloud, offline }
        var sku: String
        var device: String
        var categories: [SceneCategory]
        var source: Source
    }

    struct DIYEntry: Sendable, Equatable {
        var diyId: Int
        var name: String
        var group: String?
        var iconUrl: String?
        var code: String
    }

    /// The modes the app can show for a device, by its internal mode id.
    static let modes: [Int: String] = [
        7: "video", 8: "music", 9: "colour", 10: "scene", 11: "diy", 12: "graffiti", 13: "illumination", 18: "interaction",
        19: "quickOperation", 20: "shareSpace", 21: "display", 22: "carousel",
    ]

    struct FunctionSupport: Sendable, Equatable {
        var modes: [String]
        var modeIds: [Int]
    }

    // MARK: Normalising

    /// The raw scene-library categories as the config page and the lights use them, already encoded.
    static func normaliseSceneLibrary(_ categories: JSONValue?, sku: String, device: String, source: SceneLibrary.Source = .cloud) -> SceneLibrary {
        var normalised: [SceneCategory] = []
        for category in categories?.arrayValue ?? [] {
            var scenes: [SceneEntry] = []
            for scene in category["scenes"]?.arrayValue ?? [] {
                let effects = scene["lightEffects"]?.arrayValue.flatMap { $0.isEmpty ? nil : $0 } ?? [.object([:])]
                let variants = effects.enumerated().compactMap { index, effect in variant(effect, scene: scene, sku: sku, index: index) }
                guard let first = variants.first else { continue }
                let icons = scene["iconUrls"]?.arrayValue ?? []
                scenes.append(SceneEntry(
                    sceneId: number(scene["sceneId"]) ?? 0, name: sceneName(scene), category: category["categoryName"]?.stringValue ?? "",
                    iconUrl: icons.first?.stringValue.flatMap(nonEmpty), iconUrlDark: (icons.count > 2 ? icons[2].stringValue : nil).flatMap(nonEmpty),
                    variants: variants, code: first.code))
            }
            guard !scenes.isEmpty else { continue }
            // Rendered into element ids by the page, so never trust it to be numeric.
            let id = category["categoryId"].flatMap { $0.doubleValue ?? $0.stringValue.flatMap(Double.init) }.map { $0.isFinite ? Int($0) : 0 } ?? 0
            normalised.append(SceneCategory(id: id, name: category["categoryName"]?.stringValue ?? "Scenes", scenes: scenes))
        }
        return SceneLibrary(sku: sku, device: device, categories: normalised, source: source)
    }

    private static func sceneName(_ scene: JSONValue) -> String {
        if let english = scene["sceneNameNew"]?["en"]?.stringValue, !english.isEmpty { return english }
        if let name = scene["sceneName"]?.stringValue, !name.isEmpty { return name }
        if let name = scene["analyticName"]?.stringValue, !name.isEmpty { return name }
        return "Scene \(number(scene["sceneId"]).map(String.init) ?? "")".trimmingCharacters(in: .whitespaces)
    }

    /// The effect for one SKU: Govee's per-model overrides in `specialEffect` win when they list it.
    private static func variant(_ effect: JSONValue, scene: JSONValue, sku: String, index: Int) -> SceneVariant? {
        var paramId = number(effect["scenceParamId"])
        var param = effect["scenceParam"]?.stringValue
        var sceneCode = number(effect["sceneCode"])
        var sceneType = number(effect["sceneType"])
        if let override = effect["specialEffect"]?.arrayValue?.first(where: { $0["supportSku"]?.arrayValue?.contains(.string(sku)) == true }) {
            paramId = number(override["scenceParamId"]) ?? paramId
            if let overrideParam = override["scenceParam"]?.stringValue, !overrideParam.isEmpty { param = overrideParam }
            if let code = number(override["sceneCode"]), code > 0 { sceneCode = code }
            sceneType = number(override["sceneType"]) ?? sceneType
        }
        guard let code = sceneCode ?? number(scene["sceneCode"]) else { return nil }
        let frames = SceneCodes.encodeScene(scenceParam: param ?? "", sceneCode: code, sceneType: sceneType ?? number(scene["sceneType"]))
        let name = effect["scenceName"]?.stringValue.flatMap(nonEmpty) ?? "Variant \(index + 1)"
        return SceneVariant(
            id: paramId ?? index, name: name, code: SceneCodes.framesToCode(frames), supportsSpeed: effect["speedInfo"]?["supSpeed"]?.boolValue ?? false,
            supportedDirections: effect["supportDirections"]?.arrayValue?.compactMap(\.intValue) ?? [])
    }

    private static func number(_ value: JSONValue?) -> Int? {
        guard let double = value?.doubleValue, double.isFinite else { return nil }
        return Int(double)
    }

    private static func nonEmpty(_ string: String) -> String? { string.isEmpty ? nil : string }

    // MARK: JSON for the page

    static func json(_ library: SceneLibrary) -> JSONValue {
        [
            "sku": .string(library.sku), "device": .string(library.device), "source": .string(library.source.rawValue),
            "categories": .array(library.categories.map { category in
                [
                    "id": .number(Double(category.id)), "name": .string(category.name),
                    "scenes": .array(category.scenes.map { scene in
                        var object: [String: JSONValue] = [
                            "sceneId": .number(Double(scene.sceneId)), "name": .string(scene.name), "category": .string(scene.category), "code": .string(scene.code),
                            "variants": .array(scene.variants.map { variant in
                                [
                                    "id": .number(Double(variant.id)), "name": .string(variant.name), "code": .string(variant.code),
                                    "supportsSpeed": .bool(variant.supportsSpeed), "supportedDirections": .array(variant.supportedDirections.map { .number(Double($0)) }),
                                ]
                            }),
                        ]
                        if let icon = scene.iconUrl { object["iconUrl"] = .string(icon) }
                        if let icon = scene.iconUrlDark { object["iconUrlDark"] = .string(icon) }
                        return .object(object)
                    }),
                ]
            }),
        ]
    }

    static func json(_ diy: DIYEntry) -> JSONValue {
        var object: [String: JSONValue] = ["diyId": .number(Double(diy.diyId)), "name": .string(diy.name), "code": .string(diy.code)]
        if let group = diy.group { object["group"] = .string(group) }
        if let icon = diy.iconUrl { object["iconUrl"] = .string(icon) }
        return .object(object)
    }

    // MARK: Endpoints

    static let scenesURL = "https://app2.govee.com/appsku/v2/scences"
    static let diysURL = "https://app2.govee.com/bff-app/v1/diy/list"
    static let functionSupportURL = "https://app2.govee.com/bff-app/v1/devices/detail/function-support"
    static let timeout: Duration = .seconds(20)

    /// The scene library Govee offers for one device. Throws when the request fails: callers decide whether
    /// to fall back to the bundled catalogue.
    static func sceneLibrary(api: GoveeAPI, token: String, ref: DeviceRef) async throws -> SceneLibrary {
        let answer = try await api.request(
            "GET", scenesURL, token: token,
            query: [("sku", ref.sku), ("device", ref.device), ("goodsType", String(ref.goodsType ?? 0)), ("source", "0")], timeout: timeout)
        guard let categories = answer["data"]?["categories"], categories.arrayValue != nil else {
            throw GoveeAPIError.message("Govee scene library response did not contain any categories")
        }
        return normaliseSceneLibrary(categories, sku: ref.sku, device: ref.device)
    }

    /// The account's DIY effects for one device.
    static func diyEffects(api: GoveeAPI, token: String, ref: DeviceRef) async throws -> [DIYEntry] {
        let body: JSONValue = ["sku": .string(ref.sku), "device": .string(ref.device), "goodsType": .number(Double(ref.goodsType ?? 0))]
        let answer = try await api.request("POST", diysURL, token: token, body: body, timeout: timeout)
        return diyEntries(answer["data"]?["diys"])
    }

    static func diyEntries(_ groups: JSONValue?) -> [DIYEntry] {
        var entries: [DIYEntry] = []
        for group in groups?.arrayValue ?? [] {
            for diy in group["diys"]?.arrayValue ?? [] {
                guard let code = number(diy["diyCode"]) ?? number(diy["diyId"]) else { continue }
                let name = diy["diyName"]?.stringValue.flatMap(nonEmpty) ?? diy["name"]?.stringValue.flatMap(nonEmpty) ?? "DIY \(code)"
                entries.append(DIYEntry(
                    diyId: number(diy["diyId"]) ?? code, name: name, group: group["groupName"]?.stringValue.flatMap(nonEmpty),
                    iconUrl: diy["coverUrl"]?.stringValue.flatMap(nonEmpty), code: SceneCodes.framesToCode(SceneCodes.encodeDIY(effect: diy["effectStr"]?.stringValue ?? "", code: code))))
            }
        }
        return entries
    }

    /// Which modes a device supports, so the page offers only those.
    static func functionSupport(api: GoveeAPI, token: String, ref: DeviceRef) async throws -> FunctionSupport {
        var query: [(String, String)] = [("sku", ref.sku), ("device", ref.device), ("goodsType", String(ref.goodsType ?? 0))]
        if let value = ref.pactType { query.append(("pactType", String(value))) }
        if let value = ref.pactCode { query.append(("pactCode", String(value))) }
        if let value = ref.versionSoft { query.append(("versionSoft", value)) }
        if let value = ref.versionHard { query.append(("versionHard", value)) }
        if let value = ref.wifiVersionSoft { query.append(("wifiVersionSoft", value)) }
        if let value = ref.wifiVersionHard { query.append(("wifiVersionHard", value)) }
        let answer = try await api.request("GET", functionSupportURL, token: token, query: query, timeout: timeout)
        return functionSupport(answer["data"])
    }

    static func functionSupport(_ raw: JSONValue?) -> FunctionSupport {
        let ids: [Double?]
        if let modes = raw?["modes"]?.arrayValue {
            ids = modes.map { $0.doubleValue ?? $0["componentId"].flatMap { $0.doubleValue ?? $0.stringValue.flatMap(Double.init) } }
        } else if let components = raw?["components"]?.arrayValue {
            ids = components.map { ($0["componentId"] ?? $0).doubleValue ?? ($0["componentId"] ?? $0).stringValue.flatMap(Double.init) }
        } else {
            ids = []
        }
        let modeIds = ids.compactMap { $0 }.filter(\.isFinite).map { Int($0) }
        return FunctionSupport(modes: modeIds.compactMap { modes[$0] }, modeIds: modeIds)
    }
}

/// The scene catalogue bundled with the plugin (`utils/scene-catalogue.ts`): the Govee app's own fallback,
/// for the picker before a login and for BLE- or LAN-only setups. No per-device filtering beyond the RGB and
/// RGBIC split; the cloud library is preferred whenever there is a token.
enum SceneCatalogue {
    private static let parsed: JSONValue? = try? JSONValue(string: json)

    /// Whether the SKU is addressable (RGBIC), and so gets the richer set.
    static func isRGBIC(_ sku: String) -> Bool {
        parsed?["rgbicSkus"]?.arrayValue?.contains(.string(sku.uppercased())) ?? false
    }

    static func library(sku: String, device: String) -> GoveeContent.SceneLibrary? {
        guard let parsed else { return nil }
        let categories = isRGBIC(sku) ? parsed["rgbic"] : parsed["rgb"]
        return GoveeContent.normaliseSceneLibrary(categories, sku: sku.uppercased(), device: device, source: .offline)
    }
}
