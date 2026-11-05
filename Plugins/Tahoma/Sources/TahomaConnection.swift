import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The account: the service and its user and password, what Setup keeps in the vault or the block gives.
struct TahomaAccount: Codable, Sendable, Equatable {
    var service: String
    var user: String
    var password: String
}

/// Somfy's refresh token (docs/clean-room/Tahoma.md 11.4), kept in the vault so a restart refreshes rather than sending
/// the password again.
struct SomfyRefreshToken: Codable, Sendable, Equatable {
    var refreshToken: String
    /// The account it belongs to: one Setup made with another account does not sign in as the previous one.
    var user: String?
}

/// A Developer Mode token the plugin minted through the cloud for a gateway (3.5), kept in the vault.
struct LocalToken: Codable, Sendable, Equatable {
    var gatewayPin: String
    var token: String
    /// The account that minted it.
    var user: String?
    /// Its uuid on the gateway, by which it is revoked once refused.
    var uuid: String?
}

/// A gateway announcing its local API on the network (`_kizboxdev._tcp`).
struct GatewayAnnouncement: Sendable, Equatable {
    var name: String
    /// Its `gateway_pin` TXT record, which Somfy's developer documentation says to match rather than the name.
    var pin: String?
    var address: String?

    /// Whether it is the gateway of `pin`: its TXT record says so, or, without one, its name contains it.
    func matches(_ pin: String) -> Bool {
        if let own = self.pin { return own == pin }
        return name.contains(pin)
    }

    /// The gateways announced within `duration`, or until the one of `pin` is.
    static func browse(for duration: Duration, pin: String?) async -> [GatewayAnnouncement] {
        let found = await withTaskGroup(of: [String: GatewayAnnouncement]?.self) { group in
            group.addTask {
                var found: [String: GatewayAnnouncement] = [:]
                // Ends when the task is cancelled (the window's end).
                for await event in BonjourBrowser.browse(type: "_kizboxdev._tcp") {
                    guard case .found(let service) = event else { continue }
                    let address = service.addresses.first { !$0.contains(":") } ?? service.addresses.first
                    let gateway = GatewayAnnouncement(name: service.name, pin: service.txt["gateway_pin"], address: address)
                    found[service.name] = gateway
                    if let pin, gateway.matches(pin) { break }
                }
                return found
            }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            var found = await group.next().flatMap { $0 } ?? [:]
            group.cancelAll()
            while let result = await group.next() { found.merge(result ?? [:]) { first, _ in first } }
            return found
        }
        return found.values.sorted { $0.name < $1.name }
    }
}

extension TahomaPlugin {
    /// The account: what Setup kept in the vault, else the block's `service`, `user` and `password`. The block's
    /// `service` wins over the one kept, so changing it in Plugin Settings applies.
    nonisolated var account: TahomaAccount? {
        if var kept = context.credentials(as: TahomaAccount.self), !kept.user.isEmpty, !kept.password.isEmpty {
            if let service = configuration.service, !service.isEmpty { kept.service = service }
            return kept
        }
        guard let user = configuration.user?.trimmingCharacters(in: .whitespaces), !user.isEmpty, let password = configuration.password, !password.isEmpty
        else { return nil }
        return TahomaAccount(service: configuration.service ?? "somfy_europe", user: user, password: password)
    }

    /// The client to use (3.4, 3.5): the gateway for `local`; for a Somfy account with one gateway, that gateway's local
    /// API when a token is kept or can be minted and the gateway answers, else the cloud.
    /// `minting` off (a listing for Setup) uses a token kept but mints none.
    func connect(minting: Bool = true) async throws -> OverkizClient {
        guard let account, let service = OverkizService(configured: account.service) else { throw OverkizError(message: "No Overkiz account") }
        if service == .local {
            let client = try await localClient(user: account.user, token: account.password, refusesAccount: true)
            try await client.signIn()
            return client
        }
        let cloud = makeClient(.cloud(service, user: account.user, password: account.password), http: dependencies.cloudHTTP, refusesAccount: true)
        guard service.isSomfy, configuration.preferLocalAPI ?? true else { return cloud }
        do {
            if let local = try await localFallingBack(cloud: cloud, user: account.user, minting: minting) { return local }
        } catch {
            logger.info("The gateway's local API is not used: \(error)")
        }
        return cloud
    }

    /// The local API of the account's single gateway, with the token kept or one minted now; nil when the setup has
    /// several gateways (the local API of one would miss the others' devices). A token is minted once and kept: only
    /// a token the gateway refused, or one of another account, is replaced; a refused one is revoked, and only that
    /// one (another bridge's token on the same gateway stays).
    private func localFallingBack(cloud: OverkizClient, user: String, minting: Bool) async throws -> OverkizClient? {
        var kept = localToken.load()
        if let token = kept, token.user != nil, token.user != user {
            localToken.remove()
            kept = nil
        }
        if kept == nil, minting {
            let gateways = try await cloud.gateways()
            guard gateways.count == 1, let pin = gateways.first else { return nil }
            let (token, uuid) = try await cloud.mintLocalToken(pin: pin, label: "Homeswift")
            let minted = LocalToken(gatewayPin: pin, token: token, user: user, uuid: uuid)
            do {
                try localToken.save(minted)
            } catch {
                // Not kept, so never used again: take it back rather than leave it on the gateway.
                if let uuid { await cloud.revokeLocalToken(pin: pin, uuid: uuid) }
                throw error
            }
            logger.info("Minted a Developer Mode token for the gateway")
            kept = minted
        }
        guard let kept else { return nil }
        let local = try await localClient(user: kept.gatewayPin, token: kept.token, refusesAccount: false)
        do {
            try await local.signIn()
            logger.info("Talking to the gateway on the local network")
            return local
        } catch let error as OverkizError where error.refusesCredentials(local: true) {
            logger.info("The gateway refused its Developer Mode token: a new one is minted at the next start")
            localToken.remove()
            if let uuid = kept.uuid { await cloud.revokeLocalToken(pin: kept.gatewayPin, uuid: uuid) }
            return nil
        }
    }

    /// A client for a gateway by IP address or PIN; a PIN is looked up on the network for 10 s, then `gateway-<PIN>.local`.
    func localClient(user: String, token: String, refusesAccount: Bool) async throws -> OverkizClient {
        let host: String
        var pin: String?
        if Self.isIPv4(user) {
            host = user
        } else if Self.isPIN(user) {
            pin = user
            let found = await dependencies.browseGateways(scaled(10), user)
            for gateway in found where !gateway.matches(user) { logger.debug("Ignoring gateway \(OverkizClient.redacted(gateway.name))") }
            if let address = found.first(where: { $0.matches(user) })?.address {
                host = address
            } else {
                logger.warning("No gateway found on your network: check the PIN and that Developer Mode is activated (https://github.com/Somfy-Developer/Somfy-TaHoma-Developer-Mode)")
                host = Self.gatewayHostName(pin: user)
            }
        } else {
            throw OverkizError(message: "Invalid username. Please provide gateway PIN (XXXX-XXXX-XXXX) or gateway IP")
        }
        return makeClient(.local(host: host, pin: pin, token: token), http: dependencies.localHTTP(pin), refusesAccount: refusesAccount)
    }

    /// A client; `refusesAccount` for the instance's own account, whose refusals the bridge shows, whose refresh token
    /// is kept in the vault and whose sign-in pause outlives the client. Setup's checks keep none of these.
    func makeClient(_ endpoint: OverkizEndpoint, http: any HTTPSending, refusesAccount: Bool) -> OverkizClient {
        let context = context
        var store: RefreshTokenStore?
        if refusesAccount, case .cloud(_, let user, _) = endpoint {
            let file = context.secretFile("somfy-oauth.json", as: SomfyRefreshToken.self)
            let logger = logger
            store = RefreshTokenStore(load: { file.load().flatMap { $0.user == nil || $0.user == user ? $0.refreshToken : nil } }) { token in
                do {
                    if let token { try file.save(SomfyRefreshToken(refreshToken: token, user: user)) } else { file.remove() }
                } catch {
                    logger.warning("Could not keep Somfy's refresh token: \(error)")
                }
            }
        }
        return OverkizClient(
            endpoint: endpoint, transport: .init(http: http, timeout: scaled(15)), proxy: configuration.proxy, logger: logger, tokenStore: store,
            lockout: refusesAccount ? signInLockout : SignInLockout(),
            onAccount: { refusal in
            guard refusesAccount else { return }
            if let refusal { context.accountRefused("The account refused to sign in: \(refusal.message)") } else { context.accountAccepted() }
        })
    }
}
