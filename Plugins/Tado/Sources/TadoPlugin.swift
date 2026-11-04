import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// tado° smart thermostats, radiator valves, hot water and air conditioners through tado's cloud: each zone of each
/// home of the block becomes an accessory (a Thermostat, a Heater Cooler, a Switch or a Valve), with the home's
/// presence, weather, central switch, presence lock and child locks (docs/clean-room/Tado.md).
///
/// The block of `@homebridge-plugins/homebridge-tado` loads unchanged (`TadoPlatform`, `homes[]`). The account signs in
/// through Setup, with tado's device authorization (TadoSetup.swift); its refresh token is in the vault, one per
/// username. tado allows about 100 requests a day without a subscription, so the plugin polls once for every zone and
/// as often as the day allows (TadoBudget.swift). See README.md in this directory.
public actor TadoPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        /// The block as it is: read leniently (TadoSettings.swift).
        public var raw: JSONValue

        public init(from decoder: any Decoder) throws {
            raw = try JSONValue(from: decoder)
        }

        init(raw: JSONValue) { self.raw = raw }

        var debug: Bool { raw["debug"]?.flag ?? false }
        var preferSiriTemperature: Bool { raw["preferSiriTemperature"]?.flag ?? false }
        /// Homeswift's own: the account's requests a day (tado's 100 without a subscription).
        var dailyRequestLimit: Int { max(raw["dailyRequestLimit"]?.saturatingIntValue ?? TadoBudget.defaultDailyLimit, 10) }
        var homes: [JSONValue] { raw["homes"]?.arrayValue ?? [] }
    }

    /// What the plugin reaches tado with; tests swap them.
    struct Dependencies: Sendable {
        var transport: any HTTPSending = HTTPClient()
        /// The waits between retries and polls.
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var now: @Sendable () -> Date = Date.init
        var home = TadoHome.Options()
    }

    public static let platform = "TadoPlatform"
    public static let name = "tado°"
    public static let icon: String? = "thermo"
    public static let summary: String? = "Thermostats, radiator valves, hot water and air conditioners of a tado° account"
    public static let assistantBackground: String? = """
        tado° is reached through its cloud only (my.tado.com). An account without an Auto-Assist subscription may make about \
        100 requests a day; past it tado answers HTTP 429 until midnight (Europe/Berlin). The plugin polls all zones in one \
        request and spreads its polls over the day; `polling` in a home overrides that. "needs signing in" means the refresh \
        token was refused: sign in again through Setup. A home without `id` is the account's first home with the same name.
        """
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private var logger: Logger { context.logger }
    private(set) var homes: [TadoHome] = []
    /// One account per username, shared by its homes.
    private var accounts: [String: TadoAccount] = [:]

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    var http: TadoHTTP { TadoHTTP(transport: dependencies.transport, sleep: dependencies.sleep) }

    /// Telegram's bot token in the vault (`canonicalSettings` moves the block's there).
    var telegramFile: SecretFile<[String: String]> { context.secretFile("telegram.json", as: [String: String].self) }

    /// The homes of the block, each zone with its Accessory Settings on top.
    func homeSettings(log: Bool = false) -> [HomeSettings] {
        let telegramToken = telegramFile.load()?["token"]
        return configuration.homes.compactMap { json in
            do {
                return try HomeSettings(json, telegramToken: telegramToken) { deviceID in self.context.accessorySettings(for: deviceID).plugin }
            } catch {
                if log, let skipped = error as? SkippedHome { logger.warning("\(skipped.reason): the home is skipped") }
                return nil
            }
        }
    }

    /// The account of a username, made once.
    func account(for username: String, skipAuth: Bool = false) -> TadoAccount {
        let key = username.lowercased()
        if let account = accounts[key] { return account }
        let counter = RequestCounter(file: context.jsonFile("tado-api-\(TadoHash.username(key)).json", as: RequestCounter.Stored.self), now: dependencies.now)
        let isFile = key.hasSuffix(".json")
        let account = TadoAccount(
            username: key, file: isFile ? nil : context.secretFile(TadoAccount.fileName(username: key), as: TadoAccount.Tokens.self),
            tokenFile: isFile ? URL(fileURLWithPath: username) : nil, http: http, counter: counter, logger: logger, now: dependencies.now)
        accounts[key] = account
        return account
    }

    func api(for home: HomeSettings) -> TadoAPI {
        let account = account(for: home.username)
        return TadoAPI(base: home.apiBase, account: home.skipAuth ? nil : account, http: http, counter: account.counter, logger: logger, debug: configuration.debug)
    }

    public func start() async throws {
        let all = homeSettings(log: true)
        let telegram = all.last { $0.telegram != nil }?.telegram.map { TelegramSender(settings: $0, http: http, logger: logger) }
        var options = dependencies.home
        options.preferSiriTemperature = configuration.preferSiriTemperature
        options.dailyLimit = configuration.dailyRequestLimit
        var keep = Set<String>()
        for settings in all {
            let home = TadoHome(settings: settings, api: api(for: settings), context: context, options: options, telegram: telegram, now: dependencies.now)
            await home.addAccessories()
            keep.formUnion(await home.accessoryIDs)
            homes.append(home)
        }
        _ = await context.removeAccessories(keeping: keep)
        let perAccount = Dictionary(grouping: all, by: { $0.username.lowercased() }).mapValues(\.count)
        let sleep = dependencies.sleep
        for (index, home) in homes.enumerated() {
            await home.startPolling(homesOnAccount: perAccount[all[index].username.lowercased()] ?? 1, sleep: sleep)
        }
        // The day's count, soon after start and then hourly, as the Homebridge plugin logged it.
        tasks.add { [weak self] in
            try? await sleep(.seconds(4))
            while !Task.isCancelled {
                await self?.logCounters()
                try? await sleep(.seconds(3600))
            }
        }
    }

    public func stop() async {
        tasks.cancelAll()
        for home in homes { await home.stop() }
        for account in accounts.values { await account.counter.save() }
    }

    func logCounters() async {
        for (username, account) in accounts.sorted(by: { $0.key < $1.key }) {
            let today = await account.counter.today()
            logger.info("tado° API counter: \(today.api + today.login) (\(today.api) API, \(today.login) sign-in) today for \(username), of \(configuration.dailyRequestLimit)")
        }
    }

    /// `GET status`: each account's requests today and its limit, each home's polling interval.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        guard request.method == "GET", request.path == "status" else { return .error(404, "Not found") }
        var accountsJSON: [JSONValue] = []
        for (username, account) in accounts.sorted(by: { $0.key < $1.key }) {
            let today = await account.counter.today()
            accountsJSON.append(["username": .string(username), "api": .number(Double(today.api)), "login": .number(Double(today.login)),
                                 "limit": .number(Double(configuration.dailyRequestLimit)), "authorized": .bool(await account.isAuthorized)])
        }
        let all = homeSettings()
        let perAccount = Dictionary(grouping: all, by: { $0.username.lowercased() }).mapValues(\.count)
        var homesJSON: [JSONValue] = []
        for (index, home) in homes.enumerated() where index < all.count {
            homesJSON.append(["name": .string(all[index].name),
                              "pollingInterval": .number(Double(await home.pollingInterval(homesOnAccount: perAccount[all[index].username.lowercased()] ?? 1)))])
        }
        return PluginWebResponse(["accounts": .array(accountsJSON), "homes": .array(homesJSON)])
    }
}

/// Messages to a Telegram chat (section 2.5): sent once, failures logged.
actor TelegramSender {
    let settings: TelegramSettings
    private let http: TadoHTTP
    private let logger: Logger

    init(settings: TelegramSettings, http: TadoHTTP, logger: Logger) {
        self.settings = settings
        self.http = http
        self.logger = logger
    }

    func send(_ text: String) async {
        guard let url = URL(string: "https://api.telegram.org/bot\(settings.token)/sendMessage") else { return }
        let request = HTTPRequest(method: "POST", url: url, headers: [("Content-Type", "application/x-www-form-urlencoded")],
                                  body: Data(URLEncoding.form([("chat_id", settings.chatID), ("parse_mode", "Markdown"), ("text", text)]).utf8), timeout: .seconds(15))
        do {
            let response = try await http.send(request, retries: 0)
            if !response.isSuccess { logger.error("Telegram did not take the message: HTTP \(response.status)") }
        } catch {
            logger.error("Could not send the Telegram message: \(type(of: error))")
        }
    }
}
