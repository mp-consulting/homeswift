import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// What the vault keeps for the account (3.4): the long-lived login token and the device ids Gigya remembers, and the
/// e-mail and password so a dead login token can be replaced without the person. JWT and person id stay in memory.
struct RenaultCredentials: Codable, Sendable, Equatable {
    var loginToken: String?
    var gmid: String?
    var ucid: String?
    var username: String?
    var password: String?

    var deviceIDs: GigyaDeviceIDs? {
        guard let gmid, !gmid.isEmpty, let ucid, !ucid.isEmpty else { return nil }
        return GigyaDeviceIDs(gmid: gmid, ucid: ucid)
    }

    var canSignIn: Bool { loginToken?.isEmpty == false || (username?.isEmpty == false && password?.isEmpty == false) }
}

/// The plugin's waits, from docs/clean-room/Renault.md; tests shorten them.
struct RenaultTiming: Sendable {
    /// The quota's window (4.8: about 60 calls an hour). Poll intervals and the vehicle list scale with it.
    var hour: Duration = .seconds(3600)
    /// After `err.func.wired.overloaded` (6.2).
    var cooldown: Duration = .seconds(15 * 60)
    /// After an action, the related endpoint is read again at these delays (6.1).
    var confirmations: [Duration] = [.seconds(60), .seconds(180)]
    /// A switch shows what was written this long unless a read agrees sooner (9.5).
    var optimisticHold: Duration = .seconds(5 * 60)
    /// The Horn and Lights switches turn themselves off after this.
    var momentary: Duration = .seconds(1)
    var requestTimeout: Duration = .seconds(30)
    /// After a failure that is not a refusal: Backoff from this, up to `retryMaximum`.
    var retry: Duration = .seconds(60)
    var retryMaximum: Duration = .seconds(30 * 60)
    /// A dropped endpoint is tried again after this (6.3).
    var forgetDropped: Duration = .seconds(7 * 24 * 3600)
}

/// The budget of an account (6.1, 6.2): one request at a time, at most `maxCallsPerHour` in any rolling hour, and none
/// for 15 minutes after Renault says the quota is reached. Polls and the confirmation reads after an action leave
/// `actionReserve` requests of the hour for actions, so a switch in the Home app is not refused because a poll took the
/// last call.
actor RequestBudget {
    enum Priority: Sendable { case poll, confirmation, action }

    static let actionReserve = 6

    let maxCallsPerHour: Int
    let hour: Duration
    let cooldown: Duration
    private var sent: [ContinuousClock.Instant] = []
    private(set) var cooldownUntil: ContinuousClock.Instant?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxCallsPerHour: Int, hour: Duration, cooldown: Duration) {
        self.maxCallsPerHour = max(maxCallsPerHour, Self.actionReserve + 3)
        self.hour = hour
        self.cooldown = cooldown
    }

    /// What polls may spend in an hour: the hour's budget less the actions' reserve.
    var pollBudget: Int { maxCallsPerHour - Self.actionReserve }

    var isCoolingDown: Bool {
        guard let cooldownUntil else { return false }
        if ContinuousClock.now >= cooldownUntil {
            self.cooldownUntil = nil
            return false
        }
        return true
    }

    /// The requests of the last hour.
    var sentInLastHour: Int {
        prune()
        return sent.count
    }

    private func prune() {
        let start = ContinuousClock.now - hour
        if let index = sent.firstIndex(where: { $0 > start }) { sent.removeFirst(index) } else { sent.removeAll() }
    }

    private func limit(_ priority: Priority) -> Int { priority == .action ? maxCallsPerHour : pollBudget }

    /// Whether `cost` more requests of this kind fit the hour and no cool-down runs.
    func hasRoom(_ priority: Priority, cost: Int = 1) -> Bool {
        guard !isCoolingDown else { return false }
        prune()
        return sent.count + cost <= limit(priority)
    }

    /// Counts one request; throws `quota` when it does not fit (never more than the hour's budget).
    func record(_ priority: Priority) throws {
        guard hasRoom(priority) else { throw RenaultError.quota }
        sent.append(.now)
    }

    /// Renault said the quota is reached.
    func overloaded() { cooldownUntil = .now + cooldown }

    // One request at a time, for every vehicle of the account.

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// One MyRenault account: the Gigya session (login token → JWT, 3.4) and the Kamereon requests, each through the
/// budget. Calls run one at a time: `perform` holds the account's single slot for a whole operation (the R5's charge start
/// is a read and a write), so a JWT is minted once however many vehicles poll.
actor RenaultSession {
    private let http: any HTTPSending
    let locale: String
    private var servers: RenaultServers?
    private let timing: RenaultTiming
    private let logger: Logger
    let budget: RequestBudget
    private(set) var credentials: RenaultCredentials
    /// Called when Gigya gave a new login token or device ids: stored in the vault at once.
    private let onCredentialsChange: @Sendable (RenaultCredentials) -> Void
    private var jwt: (token: String, issued: Date)?
    private var personID: String?
    /// The clock of the JWT's expiry; tests move it.
    var now: @Sendable () -> Date = { Date() }

    init(
        http: any HTTPSending, locale: String, credentials: RenaultCredentials, budget: RequestBudget, timing: RenaultTiming, logger: Logger,
        onCredentialsChange: @escaping @Sendable (RenaultCredentials) -> Void
    ) {
        self.http = http
        self.locale = locale
        self.credentials = credentials
        self.budget = budget
        self.timing = timing
        self.logger = logger
        self.onCredentialsChange = onCredentialsChange
    }

    func resolvedServers() async throws -> RenaultServers {
        if let servers { return servers }
        let resolved = try await RenaultLocale.resolve(locale, http: http, timeout: timing.requestTimeout)
        servers = resolved
        return resolved
    }

    private func gigya() async throws -> GigyaClient {
        GigyaClient(http: http, servers: try await resolvedServers(), timeout: timing.requestTimeout)
    }

    // MARK: Sign-in

    /// A valid JWT: the cached one, else a new one from the login token, else a password sign-in (a block written by
    /// hand, or a dead login token replaced once). A refusal (`invalidCredentials`, `needsTwoFactor`, `loginTokenExpired`
    /// with no password to try) is for the plugin to show as Needs Authorization.
    func currentJWT() async throws -> String {
        if let jwt, !JWT.isExpired(jwt.token, issued: jwt.issued, now: now()) { return jwt.token }
        let gigya = try await gigya()
        if credentials.loginToken?.isEmpty != false { try await signInWithPassword(gigya) }
        guard let loginToken = credentials.loginToken else { throw RenaultError.notSignedIn }
        let token: String
        do {
            token = try await gigya.jwt(loginToken: loginToken)
        } catch RenaultError.loginTokenExpired {
            // Forget the dead token, try the password once (with the remembered device, which skips the code).
            jwt = nil
            personID = nil
            credentials.loginToken = nil
            logger.info("Renault's sign-in expired; signing in again with the stored password")
            try await signInWithPassword(gigya, after: .loginTokenExpired)
            guard let renewed = credentials.loginToken else { throw RenaultError.loginTokenExpired }
            token = try await gigya.jwt(loginToken: renewed)
        }
        jwt = (token, now())
        return token
    }

    private func signInWithPassword(_ gigya: GigyaClient, after reason: RenaultError = .notSignedIn) async throws {
        guard let username = credentials.username, !username.isEmpty, let password = credentials.password, !password.isEmpty else { throw reason }
        let token = try await gigya.login(email: username, password: password, deviceIDs: credentials.deviceIDs)
        credentials.loginToken = token
        onCredentialsChange(credentials)
    }

    func currentPersonID() async throws -> String {
        if let personID { return personID }
        _ = try await currentJWT()
        guard let loginToken = credentials.loginToken else { throw RenaultError.notSignedIn }
        let person = try await gigya().personID(loginToken: loginToken)
        personID = person
        return person
    }

    /// A refused session (Kamereon's unauthorized): minted again on the next request.
    func dropJWT() { jwt = nil }

    // MARK: Requests

    /// Runs `operation` holding the account's one slot, once `cost` requests of this priority fit the hour.
    func perform<T: Sendable>(_ priority: RequestBudget.Priority, cost: Int = 1, _ operation: @Sendable (isolated RenaultSession) async throws -> T) async throws -> T {
        await budget.acquire()
        do {
            guard !Task.isCancelled else { throw CancellationError() }
            guard await budget.hasRoom(priority, cost: cost) else { throw RenaultError.quota }
            let result = try await operation(self)
            await budget.release()
            return result
        } catch {
            await budget.release()
            throw error
        }
    }

    /// One Kamereon request, counted; inside `perform`. Kamereon's unauthorized (or a 401) mints a new JWT and tries once
    /// more; the quota error starts the cool-down.
    func send(_ priority: RequestBudget.Priority, method: String = "GET", path: String, query: [(String, String)] = [], body: JSONValue? = nil, label: String) async throws -> JSONValue {
        var retried = false
        while true {
            let token = try await currentJWT()
            let servers = try await resolvedServers()
            try await budget.record(retried ? .action : priority)
            let request = Kamereon.request(method: method, path: path, query: query, body: body, servers: servers, jwt: token, timeout: timing.requestTimeout)
            let response = try await http.send(request)
            do {
                let json = try Kamereon.check(response)
                logger.debug("Renault \(method) \(label): HTTP \(response.status)")
                return json
            } catch RenaultError.kamereon(let error) {
                logger.debug("Renault \(method) \(label): HTTP \(response.status), \(error.code)")
                if error.code == KamereonError.overloaded { await budget.overloaded() }
                if !retried, error.code == KamereonError.unauthorized || response.status == 401 {
                    retried = true
                    jwt = nil
                    continue
                }
                throw RenaultError.kamereon(error)
            } catch RenaultError.http(let status) where status == 401 && !retried {
                logger.debug("Renault \(method) \(label): HTTP 401")
                retried = true
                jwt = nil
                continue
            }
        }
    }

    // MARK: Account and vehicles (3.5 to 3.7)

    func accounts(_ priority: RequestBudget.Priority) async throws -> [KamereonAccount] {
        let person = try await currentPersonID()
        let json = try await send(priority, path: "/commerce/v1/persons/\(URLEncoding.rfc3986(person))", label: "person")
        return Kamereon.accounts(json)
    }

    /// The account's vehicles with their details; a link without details asks for them, and one still without is left
    /// out (`missing` lists its VIN).
    func vehicles(accountID: String, _ priority: RequestBudget.Priority) async throws -> (vehicles: [VehicleInfo], missing: [String]) {
        let json = try await send(priority, path: "\(Kamereon.accountPath(accountID))/vehicles", label: "vehicles")
        var vehicles: [VehicleInfo] = []
        var missing: [String] = []
        for link in (json["vehicleLinks"]?.arrayValue ?? []).prefix(20) {
            guard let vin = VehicleInfo.cleanVIN(link["vin"]?.stringValue ?? link["vehicleDetails"]?["vin"]?.stringValue) else { continue }
            if let details = link["vehicleDetails"], details.objectValue != nil, let vehicle = VehicleInfo(details: details, vin: vin) {
                vehicles.append(vehicle)
                continue
            }
            if let details = try? await send(priority, path: "\(Kamereon.accountPath(accountID))/vehicles/\(vin)/details", label: "vehicle details"),
                let vehicle = VehicleInfo(details: details, vin: vin) {
                vehicles.append(vehicle)
            } else {
                missing.append(vin)
            }
        }
        return (vehicles, missing)
    }
}
