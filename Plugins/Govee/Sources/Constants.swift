import Foundation

/// The model lists, defaults and minimums of the Homebridge plugin's `utils/constants.ts`.
enum GoveeConstants {
    struct Defaults {
        static let adaptiveLightingShift = 0
        static let bleControlInterval = 500
        static let awsColourMode = "default"
        static let bleRefreshTime = 300
        static let brightnessStep = 1
        static let httpRefreshTime = 30
        static let lanRefreshTime = 30
        static let lanScanInterval = 60
        static let lowBattThreshold = 20
        static let showAs = "default"
    }

    /// `bleControlInterval` takes milliseconds (500 and up) or, from older configurations, seconds (5 and up).
    struct Minimums {
        static let adaptiveLightingShift = -1
        static let bleControlInterval = 5
        static let bleRefreshTime = 60
        static let brightnessStep = 1
        static let httpRefreshTime = 30
        static let lanRefreshTime = 10
        static let lanScanInterval = 30
        static let lowBattThreshold = 1
    }

    /// Models by family. Upper case, as Govee reports them.
    enum Models {
        static let rgb: [String] = [
            "H6001", "H6002", "H6003", "H6004", "H6005", "H6006", "H6007", "H6008", "H6009", "H600A", "H600B", "H600C", "H600D", "H6010",
            "H6011", "H6013", "H601A", "H601B", "H601C", "H601D", "H601E", "H6020", "H6022", "H6038", "H6039", "H6042", "H6043", "H6046",
            "H6047", "H6048", "H6049", "H604A", "H604B", "H604C", "H604D", "H6050", "H6051", "H6052", "H6053", "H6054", "H6055", "H6056",
            "H6057", "H6058", "H6059", "H605A", "H605B", "H605C", "H605D", "H6061", "H6062", "H6063", "H6065", "H6066", "H6067", "H6069",
            "H606A", "H6071", "H6072", "H6073", "H6075", "H6076", "H6078", "H6079", "H607C", "H6083", "H6085", "H6086", "H6087", "H6088",
            "H6089", "H608A", "H608B", "H608C", "H608D", "H6091", "H6092", "H6093", "H6095", "H6097", "H6098", "H6099", "H60A0", "H60A1",
            "H60A4", "H60A6", "H60B0", "H60B1", "H60B2", "H60C1", "H6101", "H6102", "H6104", "H6107", "H6109", "H610A", "H610B", "H6110",
            "H6114", "H6116", "H6117", "H611A", "H611B", "H611C", "H611Z", "H6121", "H6125", "H6126", "H6127", "H6129", "H612A", "H612B",
            "H612C", "H612D", "H612E", "H612F", "H6135", "H6137", "H6138", "H6139", "H613A", "H613B", "H613C", "H613D", "H613E", "H613F",
            "H613G", "H6141", "H6142", "H6143", "H6144", "H6145", "H6146", "H6147", "H6148", "H614A", "H614B", "H614C", "H614D", "H614E",
            "H6154", "H6159", "H615A", "H615B", "H615C", "H615D", "H615E", "H615F", "H6160", "H6161", "H6163", "H6167", "H6168", "H6169",
            "H616C", "H616D", "H616E", "H6170", "H6171", "H6172", "H6173", "H6175", "H6176", "H6178", "H6179", "H617A", "H617C", "H617E",
            "H617F", "H6181", "H6182", "H6185", "H6188", "H618A", "H618C", "H618E", "H618F", "H6195", "H6196", "H6198", "H6199", "H619A",
            "H619B", "H619C", "H619D", "H619E", "H619Z", "H61A0", "H61A1", "H61A2", "H61A3", "H61A5", "H61A8", "H61A9", "H61B1", "H61B2",
            "H61B3", "H61B5", "H61B6", "H61B8", "H61B9", "H61BA", "H61BC", "H61BE", "H61C2", "H61C3", "H61C5", "H61D3", "H61D5", "H61D6",
            "H61E0", "H61E1", "H61E5", "H61E6", "H61F2", "H61F5", "H61F6", "H6601", "H6602", "H6604", "H6609", "H6630", "H6631", "H6640",
            "H6641", "H6671", "H6672", "H66A0", "H66A1", "H6800", "H6810", "H6811", "H6840", "H6841", "H6871", "H7001", "H7002", "H7005",
            "H7006", "H7007", "H7008", "H7010", "H7011", "H7012", "H7013", "H7015", "H7016", "H7017", "H7019", "H7020", "H7021", "H7022",
            "H7023", "H7024", "H7025", "H7026", "H7028", "H7029", "H702A", "H702B", "H702C", "H7031", "H7032", "H7033", "H7037", "H7038",
            "H7039", "H703A", "H703B", "H7041", "H7042", "H7050", "H7051", "H7052", "H7053", "H7055", "H7056", "H7057", "H7058", "H705A",
            "H705B", "H705C", "H705D", "H705E", "H705F", "H7060", "H7061", "H7062", "H7063", "H7065", "H7066", "H7067", "H7068", "H7069",
            "H706A", "H706B", "H706C", "H7070", "H7073", "H7075", "H7076", "H7078", "H707A", "H7086", "H7087", "H7090", "H7092", "H7093",
            "H7094", "H7095", "H70A1", "H70A2", "H70A3", "H70B1", "H70B3", "H70B4", "H70B5", "H70B6", "H70BC", "H70C1", "H70C2", "H70C4",
            "H70C5", "H70C7", "H70C9", "H70CB", "H70D1", "H70D2", "H70D3", "H801B", "H801C", "H802A", "H8022", "H805A", "H805B", "H805C",
            "H806A", "H8072", "H808A", "H80A4", "H80C4", "H80C5", "H8604", "H8840", "H8841", "HXXXX"
        ]

        static let switchSingle: [String] = [
            "H5001", "H5080", "H5081", "H5083", "H5086", "H7014"
        ]

        static let switchDouble: [String] = [
            "H5082"
        ]

        static let switchTriple: [String] = [
            "H5160"
        ]

        static let sensorLeak: [String] = [
            "H5054", "H5058"
        ]

        static let sensorThermo: [String] = [
            "B5178", "H5051", "H5052", "H5053", "H5055", "H5071", "H5072", "H5074", "H5075", "H5100", "H5101", "H5102", "H5103", "H5104",
            "H5105", "H5108", "H5109", "H5110", "H5112", "H5174", "H5177", "H5179", "H5183", "H5190", "H5310"
        ]

        static let sensorThermo4: [String] = [
            "H5198"
        ]

        static let sensorMonitor: [String] = [
            "H5106"
        ]

        static let fan: [String] = [
            "H7100", "H7101", "H7102", "H7105", "H7106", "H7107", "H7111"
        ]

        static let heater1: [String] = [
            "H7130", "H713A", "H713B", "H713C"
        ]

        static let heater2: [String] = [
            "H7131", "H7132", "H7133", "H7134", "H7135"
        ]

        static let dehumidifier: [String] = [
            "H7150", "H7151"
        ]

        static let humidifier: [String] = [
            "H7140", "H7141", "H7142", "H7143", "H7145", "H7147", "H7148", "H7149", "H714E", "H7160"
        ]

        static let purifier: [String] = [
            "H7120", "H7121", "H7122", "H7123", "H7124", "H7126", "H7127", "H7128", "H7129", "H712C"
        ]

        static let diffuser: [String] = [
            "H7161", "H7162"
        ]

        static let iceMaker: [String] = [
            "H7172", "H717D"
        ]

        static let sensorButton: [String] = [
            "H5122"
        ]

        static let sensorContact: [String] = [
            "H5123"
        ]

        static let sensorPresence: [String] = [
            "H5127"
        ]

        static let kettle: [String] = [
            "H7170", "H7171", "H7173", "H7175", "H717A"
        ]

        static let template: [String] = [
            "H1162", "H1167", "H5024", "H5042", "H5043", "H5059", "H5085", "H5111", "H5121", "H5124", "H5126", "H5129", "H5107", "H5125",
            "H5140", "H5185", "H5191"
        ]
    }

    /// Models that also speak Matter: `ignoreMatter` leaves them out so they can be added natively.
    static let matterModels: Set<String> = ["H5085", "H600D", "H6022", "H6099", "H612B", "H61F2", "H6641", "H6811", "H7067", "H706A", "H706B", "H706C", "H7075", "H70C4"]
    /// Single outlets that take the channel-1 codes (17 on, 16 off) for AWS on/off.
    static let awsOutlet1617: Set<String> = ["H5080", "H5083"]
    /// Models that report brightness on a 0-254 scale.
    static let apiBrightnessScale: Set<String> = ["H6002", "H6083", "H6085", "H6135", "H6137", "H7005"]
    /// Models that take a BLE brightness in percent rather than 0-255.
    static let bleBrightnessNoScale: Set<String> = ["H6052", "H6058", "H6102", "H613B", "H613D", "H617E"]
    /// BLE colour command variants: mode byte 0x0d instead of 0x02, or the all-segments frame (15 01).
    static let bleColourD: Set<String> = ["H6005", "H6052", "H6058", "H6102", "H613B", "H613D", "H617E"]
    static let bleColour1501: Set<String> = ["H6053", "H6072", "H6102", "H6199"]

    /// Sensors whose readings come from the HTTP device list.
    static var httpSensorModels: Set<String> { Set(Models.sensorLeak + Models.sensorThermo + Models.sensorMonitor) }
}

/// The config.json array a device's settings live in.
enum DeviceConfigKey: String, Sendable, CaseIterable, Codable {
    case lightDevices, switchDevices, thermoDevices, leakDevices, fanDevices, heaterDevices, humidifierDevices
    case dehumidifierDevices, purifierDevices, diffuserDevices, kettleDevices, iceMakerDevices

    /// Which array each model list belongs to (`MODEL_CONFIG_KEYS`); unknown models are lights.
    static let modelLists: [([String], DeviceConfigKey)] = [
        (GoveeConstants.Models.switchSingle, .switchDevices),
        (GoveeConstants.Models.switchDouble, .switchDevices),
        (GoveeConstants.Models.switchTriple, .switchDevices),
        (GoveeConstants.Models.sensorLeak, .leakDevices),
        (GoveeConstants.Models.sensorThermo, .thermoDevices),
        (GoveeConstants.Models.sensorThermo4, .thermoDevices),
        (GoveeConstants.Models.sensorMonitor, .thermoDevices),
        (GoveeConstants.Models.sensorButton, .thermoDevices),
        (GoveeConstants.Models.sensorContact, .thermoDevices),
        (GoveeConstants.Models.sensorPresence, .thermoDevices),
        (GoveeConstants.Models.fan, .fanDevices),
        (GoveeConstants.Models.heater1, .heaterDevices),
        (GoveeConstants.Models.heater2, .heaterDevices),
        (GoveeConstants.Models.humidifier, .humidifierDevices),
        (GoveeConstants.Models.dehumidifier, .dehumidifierDevices),
        (GoveeConstants.Models.purifier, .purifierDevices),
        (GoveeConstants.Models.diffuser, .diffuserDevices),
        (GoveeConstants.Models.iceMaker, .iceMakerDevices),
        (GoveeConstants.Models.kettle, .kettleDevices),
        (GoveeConstants.Models.rgb, .lightDevices),
    ]

    init(model: String?) {
        let sku = (model ?? "").uppercased()
        self = Self.modelLists.first { $0.0.contains(sku) }?.1 ?? .lightDevices
    }
}
