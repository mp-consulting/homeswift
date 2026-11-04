import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): the instance's account is the Tuya cloud project, an API Key: its Access ID and Access
// Secret, and for a Smart Home project the Tuya Smart or Smart Life app's account linked to it. Setup asks the project's
// type first, then what that type needs, and checks it by signing in; the Access Secret and the app's password go in the
// vault, the rest in the block's `options`. Each device and scene comes with the account and needs no setup of its own.
extension TuyaPlugin {
    public static let accountAuthorization = AuthorizationMethod.apiKey

    public func accountAuthorized() async -> Bool? {
        if case .success = validatedSettings() { return true }
        return false
    }

    public func discover() async throws -> [DiscoveredDevice] {
        runtimes.values.sorted { $0.device.id < $1.device.id }.map { runtime in
            var device = DiscoveredDevice(
                deviceID: runtime.device.id, name: runtime.device.name, model: runtime.device.productName.isEmpty ? nil : runtime.device.productName,
                isSetUp: true, kind: Self.kind(of: runtime.device))
            device.isReachable = runtime.device.online
            return device
        }
    }

    /// The project's type, then its keys (and the app's account), checked with a sign-in.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("Tuya devices come with the account: they need no setup of their own")
        let options = configuration.options
        guard let type = request.choice("projectType", among: ["2", "1"]).flatMap(TuyaProjectType.init(rawValue:)) else {
            return .ask(SetupPrompt(message: "Choose the kind of Tuya cloud project your devices are in.", fields: [
                .choice("projectType", label: "Project", options: [
                    SetupOption("2", label: "Smart Home", detail: "The Tuya Smart or Smart Life app's account, linked to a cloud project on the Tuya IoT Platform."),
                    SetupOption("1", label: "Custom", detail: "A Custom development project on the Tuya IoT Platform, its devices in its assets."),
                ], value: options?.projectType == "1" ? "1" : "2"),
            ]))
        }
        let state: JSONValue = ["projectType": .string(type.rawValue)]
        var fields = [
            SetupField("accessId", label: "Access ID", value: options?.accessId),
            SetupField("accessKey", label: "Access Secret", kind: .secret),
            .choice("endpoint", label: "Data centre", options: TuyaRegion.all.map { SetupOption("https://\($0.host)", label: $0.label) },
                    value: options?.endpoint, optional: type == .smartHome),
        ]
        if type == .smartHome {
            fields += [
                .choice("countryCode", label: "Country", options: SetupOption.countries(Array(TuyaCallingCodes.byCountry.keys)) {
                    String(TuyaCallingCodes.byCountry[$0] ?? 1)
                }, value: options?.countryCode.map(String.init)),
                SetupField("username", label: "App account (email or phone)", value: options?.username),
                SetupField("password", label: "App password", kind: .secret),
                .choice("appSchema", label: "App", options: [SetupOption("tuyaSmart", label: "Tuya Smart"), SetupOption("smartlife", label: "Smart Life")],
                        value: options?.appSchema ?? "tuyaSmart"),
            ]
        }
        let prompt = SetupPrompt(message: type == .smartHome
            ? "Enter your cloud project's Access ID and Access Secret, from the Tuya IoT Platform, and the account of the app linked to it."
            : "Enter your Custom project's Access ID and Access Secret, from the Tuya IoT Platform, and its data centre.", fields: fields)
        guard let accessID = request.answer("accessId"), let accessKey = request.secret("accessKey") else { return .ask(prompt, state: state) }
        var answered = configuration.optionsJSON?.objectValue ?? [:]
        answered["projectType"] = .string(type.rawValue)
        answered["accessId"] = .string(accessID)
        if let endpoint = request.answer("endpoint"), !endpoint.isEmpty { answered["endpoint"] = .string(endpoint) }
        var password: String?
        if type == .smartHome {
            guard let country = request.answer("countryCode").flatMap(Int.init), let username = request.answer("username"),
                  let secret = request.secret("password") else { return .ask(prompt, state: state) }
            answered["countryCode"] = .number(Double(country))
            answered["username"] = .string(username)
            answered["appSchema"] = .string(request.choice("appSchema", among: ["tuyaSmart", "smartlife"]) ?? "tuyaSmart")
            password = secret
        }
        answered.removeValue(forKey: "accessKey")
        answered.removeValue(forKey: "password")
        let credentials = TuyaAccountCredentials(accessKey: accessKey, password: password)
        let checked: TuyaSettings
        switch TuyaSettings.validate(try JSONValue.object(answered).decode(TuyaConfiguration.Options.self), credentials: credentials) {
        case .failure(let error): throw SetupError(error.description)
        case .success(let settings): checked = settings
        }
        do {
            _ = try await signIn(makeAPI(checked), checked)
        } catch {
            logger.info("Tuya refused the account given through Setup: \(error)")
            throw SetupError("Tuya refused the sign-in: \(error)")
        }
        logger.info("Signed in to Tuya through Setup")
        return .done(try SetupOutcome(encoding: credentials, settings: ["options": .object(answered)]))
    }
}

/// The calling codes of the countries, which a Smart Home login sends as `country_code` (Setup's country menu).
enum TuyaCallingCodes {
    static let byCountry: [String: Int] = {
        let table = """
        AD376 AE971 AF93 AG1268 AI1264 AL355 AM374 AO244 AR54 AS1684 AT43 AU61 AW297 AZ994 BA387 BB1246 BD880 BE32 BF226 BG359 BH973 \
        BI257 BJ229 BM1441 BN673 BO591 BR55 BS1242 BT975 BW267 BY375 BZ501 CA1 CD243 CF236 CG242 CH41 CI225 CK682 CL56 CM237 CN86 CO57 \
        CR506 CU53 CV238 CY357 CZ420 DE49 DJ253 DK45 DM1767 DO1809 DZ213 EC593 EE372 EG20 ER291 ES34 ET251 FI358 FJ679 FM691 FO298 FR33 \
        GA241 GB44 GD1473 GE995 GF594 GH233 GI350 GL299 GM220 GN224 GP590 GQ240 GR30 GT502 GU1671 GW245 GY592 HK852 HN504 HR385 HT509 \
        HU36 ID62 IE353 IL972 IN91 IQ964 IR98 IS354 IT39 JM1876 JO962 JP81 KE254 KG996 KH855 KI686 KM269 KN1869 KR82 KW965 KY1345 KZ7 \
        LA856 LB961 LC1758 LI423 LK94 LR231 LS266 LT370 LU352 LV371 LY218 MA212 MC377 MD373 ME382 MG261 MH692 MK389 ML223 MM95 MN976 \
        MO853 MP1670 MQ596 MR222 MS1664 MT356 MU230 MV960 MW265 MX52 MY60 MZ258 NA264 NC687 NE227 NG234 NI505 NL31 NO47 NP977 NR674 \
        NU683 NZ64 OM968 PA507 PE51 PF689 PG675 PH63 PK92 PL48 PM508 PR1787 PS970 PT351 PW680 PY595 QA974 RE262 RO40 RS381 RU7 RW250 \
        SA966 SB677 SC248 SD249 SE46 SG65 SI386 SK421 SL232 SM378 SN221 SO252 SR597 SS211 ST239 SV503 SY963 SZ268 TC1649 TD235 TG228 \
        TH66 TJ992 TL670 TM993 TN216 TO676 TR90 TT1868 TV688 TW886 TZ255 UA380 UG256 US1 UY598 UZ998 VC1784 VE58 VG1284 VI1340 VN84 \
        VU678 WF681 WS685 YE967 YT262 ZA27 ZM260 ZW263
        """
        var codes: [String: Int] = [:]
        for entry in table.split(separator: " ") where entry.count > 2 {
            if let code = Int(entry.dropFirst(2)) { codes[String(entry.prefix(2))] = code }
        }
        return codes
    }()
}
