import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin

// The Vault page's API (docs/vault-design.md): the entries without their values, adding and replacing one (values go
// in, never come out), removing one, and moving config.json's secrets in. Administrators only; the audit log keeps
// the route and the outcome, not the body.

extension UIServer {
    /// The vault's routes, or nil for another route.
    func vaultAPI(_ route: [String], _ request: Request, caller: Caller) async throws -> Reply? {
        guard route.first == "vault" else { return nil }
        guard caller.isAdmin else { return .error(403, "only an administrator can do this") }
        let body: JSONValue = request.body.isEmpty ? .null : try JSONValue(data: request.body)
        do {
            switch (request.method, Array(route.dropFirst())) {
            case (.GET, []):
                return .json(try catalog.vaultJSON())
            case (.GET, ["migration"]):
                return .json(try catalog.vaultMigrationPlan().json)
            case (.POST, ["migration"]):
                let result = try await catalog.migrateToVault(VaultMigration.Choices(json: body), dryRun: body["dryRun"]?.boolValue == true)
                logger.info("Web UI moved config.json's secrets into the vault", metadata: ["user": "\(caller.username)"])
                return .json(result)
            case let (.PUT, path) where path.count == 1:
                guard let kind = body["kind"]?.stringValue.flatMap(VaultEntry.Kind.init(rawValue:)) else {
                    return .error(400, "kind is one of \(VaultEntry.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                let fields = (body["fields"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
                var expires: Date?
                if let text = body["expires"]?.stringValue, !text.isEmpty {
                    guard let date = Self.date(iso: text) else { return .error(400, "expires: an ISO date") }
                    expires = date
                }
                return .json(try await catalog.setVaultEntry(path[0], kind: kind, fields: fields, expires: expires))
            case let (.DELETE, path) where path.count == 1:
                return .json(try catalog.removeVaultEntry(path[0], force: body["force"]?.boolValue == true))
            default:
                return .error(404, "no such vault route")
            }
        } catch let error as CatalogError {
            return .error(400, error.description)
        } catch let error as VaultMigrationError {
            return .error(400, error.description)
        } catch let error as SecretReferenceError {
            return .error(400, error.description)
        }
    }
}
