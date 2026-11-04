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
}

/// A Developer Mode token the plugin minted through the cloud for a gateway (3.5), kept in the vault.
struct LocalToken: Codable, Sendable, Equatable {
    var gatewayPin: String
    var token: String
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

    static func browse(for duration: Duration) async -> [GatewayAnnouncement] {
        let events = await BonjourBrowser.browse(type: "_kizboxdev._tcp").collect(for: duration)
        var found: [String: GatewayAnnouncement] = [:]
        for event in events {
            guard case .found(let service) = event else { continue }
            let address = service.addresses.first { !$0.contains(":") } ?? service.addresses.first
            found[service.name] = GatewayAnnouncement(name: service.name, pin: service.txt["gateway_pin"], address: address)
        }
        return found.values.sorted { $0.name < $1.name }
    }
}

extension TahomaPlugin {
    /// The account: what Setup kept in the vault, else the block's `service`, `user` and `password`.
    nonisolated var account: TahomaAccount? {
        if let kept = context.credentials(as: TahomaAccount.self), !kept.user.isEmpty, !kept.password.isEmpty { return kept }
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
            if let local = try await localFallingBack(cloud: cloud, minting: minting) { return local }
        } catch {
            logger.info("The gateway's local API is not used: \(error)")
        }
        return cloud
    }

    /// The local API of the account's single gateway, with the token kept or one minted now; nil when the setup has
    /// several gateways (the local API of one would miss the others' devices).
    private func localFallingBack(cloud: OverkizClient, minting: Bool) async throws -> OverkizClient? {
        var kept = localToken.load()
        if kept == nil, minting {
            let gateways = try await cloud.gateways()
            guard gateways.count == 1, let pin = gateways.first else { return nil }
            let token = try await cloud.mintLocalToken(pin: pin, label: "Homeswift")
            let minted = LocalToken(gatewayPin: pin, token: token)
            try localToken.save(minted)
            logger.info("Minted a Developer Mode token for the gateway")
            kept = minted
        }
        guard let kept else { return nil }
        let local = try await localClient(user: kept.gatewayPin, token: kept.token, refusesAccount: false)
        do {
            try await local.signIn()
            logger.info("Talking to the gateway on the local network")
            return local
        } catch let error as OverkizError where error.status == 401 {
            logger.info("The gateway refused its Developer Mode token: a new one is minted at the next start")
            localToken.remove()
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
            let found = await dependencies.browseGateways(scaled(10))
            for gateway in found where !gateway.matches(user) { logger.debug("Ignoring gateway \(gateway.name)") }
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

    func makeClient(_ endpoint: OverkizEndpoint, http: any HTTPSending, refusesAccount: Bool) -> OverkizClient {
        let context = context
        var store: RefreshTokenStore?
        if refusesAccount {
            let file = context.secretFile("somfy-oauth.json", as: SomfyRefreshToken.self)
            let logger = logger
            store = RefreshTokenStore(load: { file.load()?.refreshToken }) { token in
                do {
                    if let token { try file.save(SomfyRefreshToken(refreshToken: token)) } else { file.remove() }
                } catch {
                    logger.warning("Could not keep Somfy's refresh token: \(error)")
                }
            }
        }
        return OverkizClient(
            endpoint: endpoint, transport: .init(http: http, timeout: scaled(15)), proxy: configuration.proxy, logger: logger, tokenStore: store,
            onAccount: { refusal in
            guard refusesAccount else { return }
            if let refusal { context.accountRefused("The account refused to sign in: \(refusal.message)") } else { context.accountAccepted() }
        })
    }
}
