import Foundation
import Homeswift

/// What an input is: an Android app, a source (the tuner, Home, HDMI) or a channel.
enum InputType: String, Codable, Sendable {
    case app, source, channel
}

/// An input before it has a HomeKit service: its id (package name, source URI or channel number), its name
/// and, for apps the TV does not report, how to launch it.
struct InputData: Sendable, Equatable {
    var id: String
    var name: String
    var type: InputType
    var className: String?
    var action: String?
    var displayOrder: Int?
}

/// What the plugin keeps about an input across launches: HomeKit's identifier for it (scenes point at it),
/// the name the user gave it and whether it is shown. `inputs-<MAC>.json` in the plugin's directory.
struct InputRecord: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var configuredName: String
    var type: InputType
    var identifier: Int
    /// 0 shown, 1 hidden (`CurrentVisibilityState`).
    var visibility: Int
}

enum Inputs {
    /// HomeKit lists up to 100 services per accessory; this many inputs keeps the Home app responsive.
    static let maximum = 30
    /// Watch TV, Home, HDMI 1 to 4: identifiers 1 to 6, apps from 7.
    static let staticInputs: [InputData] = [
        InputData(id: JointSpace.watchTVURI, name: "Watch TV", type: .source),
        InputData(id: JointSpace.homeURI, name: "Home", type: .source),
    ] + JointSpace.hdmiSources.map { InputData(id: $0.id, name: $0.name, type: .source) }
    static let staticCount = staticInputs.count

    /// What the TV reports in the foreground on its home screen.
    static let launcherPackages: Set<String> = ["com.google.android.tvlauncher", "com.google.android.leanbacklauncher", "com.google.android.apps.tv.launcherx"]
    /// What the TV reports for the tuner and every HDMI input alike.
    static let playTVPackage = "org.droidtv.playtv"
    /// The TV's report for "no app it tracks".
    static let noAppReport = "NA"
    static let channelsPackage = "org.droidtv.channels"
    static let systemPackages: Set<String> = [
        "com.android.vending", "com.android.tv.settings", "com.google.android.katniss", "com.google.android.tvrecommendations",
        "org.droidtv.eum", "org.droidtv.contentexplorer",
    ]
    static var excludedPackages: Set<String> { launcherPackages.union(systemPackages).union([playTVPackage]) }

    static func isLauncher(_ package: String) -> Bool {
        launcherPackages.contains(package) || package.lowercased().contains("launcher")
    }

    /// HomeKit's `RemoteKey` values to the TV's keys, apart from the three the configuration chooses.
    static let remoteKeys: [Int: String] = [
        HAPConstants.RemoteKey.rewind: "Rewind", HAPConstants.RemoteKey.fastForward: "FastForward",
        HAPConstants.RemoteKey.nextTrack: "Next", HAPConstants.RemoteKey.previousTrack: "Previous",
        HAPConstants.RemoteKey.arrowUp: "CursorUp", HAPConstants.RemoteKey.arrowDown: "CursorDown",
        HAPConstants.RemoteKey.arrowLeft: "CursorLeft", HAPConstants.RemoteKey.arrowRight: "CursorRight",
        HAPConstants.RemoteKey.select: "Confirm", HAPConstants.RemoteKey.exit: "Home",
    ]

    /// Localized forms of the "Input"/"Input Source" placeholder tvOS writes back into ConfiguredName
    /// (homebridge/homebridge#3703), which must never replace a real name.
    static let genericNames: [String] = [
        "input source", "input", "entrada", "entrée", "entree", "eingang", "ingresso", "ingang", "ingång", "inngang", "indgang", "tulo",
        "wejście", "wejscie", "giriş", "giris", "вход", "источник", "入力", "输入", "輸入", "입력",
    ]

    static func isGenericName(_ name: String) -> Bool {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        for generic in genericNames where lowered.hasPrefix(generic) {
            let rest = lowered.dropFirst(generic.count).trimmingCharacters(in: .whitespaces)
            if rest.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// The first input for every id; a later duplicate would share a service.
    static func dedupe(_ inputs: [InputData]) -> [InputData] {
        var seen = Set<String>()
        return inputs.filter { seen.insert($0.id).inserted }
    }

    /// The TLV8 `DisplayOrder` value: identifiers in order, each a 4-byte little-endian item 1, separated by
    /// an empty item 0.
    static func displayOrder(_ identifiers: [Int]) -> String {
        var bytes: [UInt8] = []
        for (index, identifier) in identifiers.enumerated() {
            if index > 0 { bytes += [0x00, 0x00] }
            let value = UInt32(max(0, identifier))
            bytes += [0x01, 0x04, UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
        }
        return Data(bytes).base64EncodedString()
    }
}

/// Decides which inputs exist, from the static sources, the configuration and what the TV reports.
struct InputCatalog: Sendable {
    let settings: TVSettings

    /// True when the configuration lists the inputs itself: nothing is discovered.
    var hasUserInputs: Bool { !settings.inputs.isEmpty }

    /// Custom apps and sources marked visible must stay, even when the TV stops reporting them.
    func isUserRequested(_ id: String) -> Bool {
        settings.customApps.contains { $0.id == id } || settings.sources[id]?.visible == true
    }

    /// The inputs to register at launch: the static sources, then the configured or cached apps, capped.
    func startupInputs(cached: [InputRecord]) -> [InputData] {
        let apps: [InputData]
        if hasUserInputs {
            apps = settings.inputs
        } else {
            let remembered = cached.filter { record in record.type == .app && !Inputs.staticInputs.contains { $0.id == record.id } }
                .map { InputData(id: $0.id, name: $0.name, type: .app) }
            apps = sortBySourcePriority(settings.customApps + remembered)
        }
        return Array(Inputs.dedupe(Inputs.staticInputs + apps).prefix(Inputs.maximum))
    }

    /// App inputs from the TV's list: one per package, system packages left out unless marked visible,
    /// sorted by name.
    func appsFromTV(_ applications: [JointSpace.Application]) -> [InputData] {
        var inputs: [InputData] = []
        for application in applications {
            guard let package = application.packageName, !package.isEmpty else { continue }
            if Inputs.excludedPackages.contains(package), settings.sources[package]?.visible != true { continue }
            inputs.append(InputData(id: package, name: TVSettings.homeKitName(application.label?.nonEmpty ?? package), type: .app))
        }
        return Inputs.dedupe(inputs).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Visible first, unconfigured next, hidden last, so the cap never drops a source the user wants.
    func sortBySourcePriority(_ inputs: [InputData]) -> [InputData] {
        func priority(_ input: InputData) -> Int {
            switch settings.sources[input.id]?.visible {
            case true: 0
            case nil: 1
            case false: 2
            }
        }
        return inputs.enumerated().sorted { (priority($0.element), $0.offset) < (priority($1.element), $1.offset) }.map(\.element)
    }

    /// The order of an input in the wheel: the sources setting, then the configured list's displayOrder.
    func order(of id: String) -> Int? {
        settings.sources[id]?.order ?? settings.inputs.first { $0.id == id }?.displayOrder
    }
}

/// The input records on disk: identifiers allocated once and kept.
struct InputStore: Sendable {
    let url: URL
    private(set) var records: [InputRecord] = []

    init(directory: URL, mac: String) {
        url = directory.appendingPathComponent("inputs-\(mac.filter(\.isHexDigit).lowercased()).json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([InputRecord].self, from: data) {
            records = Self.validated(decoded)
        }
    }

    func record(for id: String) -> InputRecord? { records.first { $0.id == id } }

    /// The identifier recorded for an input, else the lowest free one above the static sources.
    func identifier(for id: String, inUse: Set<Int>) -> Int {
        if let known = record(for: id) { return known.identifier }
        let used = inUse.union(records.map(\.identifier))
        var next = Inputs.staticCount + 1
        while used.contains(next) { next += 1 }
        return next
    }

    mutating func save(_ records: [InputRecord]) throws {
        self.records = records
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try OwnerOnlyFile.write(try encoder.encode(records), to: url)
    }

    /// Well-formed records only, the first for each id and identifier: a torn or edited file must not
    /// hand two inputs one service.
    static func validated(_ records: [InputRecord]) -> [InputRecord] {
        var ids = Set<String>(), identifiers = Set<Int>()
        return records.filter { record in
            guard !record.id.isEmpty, record.identifier >= 1, ids.insert(record.id).inserted, identifiers.insert(record.identifier).inserted else { return false }
            return true
        }
    }
}

/// Names the user gave the source switches, kept apart from the inputs: `switch-names-<MAC>.json`.
struct SwitchNameStore: Sendable {
    let url: URL
    private(set) var names: [String: String] = [:]

    init(directory: URL, mac: String) {
        url = directory.appendingPathComponent("switch-names-\(mac.filter(\.isHexDigit).lowercased()).json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            names = decoded.compactMapValues { TVSettings.controllerName($0).nonEmpty }
        }
    }

    mutating func set(_ name: String, for id: String) throws {
        guard names[id] != name else { return }
        names[id] = name
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try OwnerOnlyFile.write(try encoder.encode(names), to: url)
    }
}
