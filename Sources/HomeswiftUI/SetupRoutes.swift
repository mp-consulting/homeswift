import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin

extension UIServer {
    /// Setup (GLOSSARY.md, "Setup"), for administrators, all `POST` with a JSON body: `/api/setup/discover` with
    /// `platform` and `name` (and `block`, an instance not saved yet) finds devices; `/api/setup/start` with the same and
    /// a `deviceID` (none for the account) starts a Setup Session and answers its first prompt; `/api/setup/<session>`
    /// with `answers` answers it; `/api/setup/<session>/cancel` ends it; `/api/setup/exclude` with `deviceID`
    /// and `excluded` excludes a device or includes it again. A person types secrets here; MCP clients cannot.
    func setupRoute(_ route: [String], body: JSONValue, username: String) async throws -> Reply? {
        let platform = body["platform"]?.stringValue ?? ""
        let name = body["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let block = body["block"]?.objectValue.map(JSONValue.object)
        do {
            switch route {
            case ["discover"]:
                guard !platform.isEmpty else { return .error(400, "platform is required") }
                return .json(try await catalog.discoverDevices(platform: platform, name: name, block: block))
            case ["start"]:
                guard !platform.isEmpty else { return .error(400, "platform is required") }
                let answer = try await catalog.startSetup(platform: platform, name: name, deviceID: body["deviceID"]?.stringValue, block: block)
                noteSetup(answer, by: username)
                return .json(answer)
            case ["exclude"]:
                guard !platform.isEmpty, let deviceID = body["deviceID"]?.stringValue, let excluded = body["excluded"]?.boolValue else {
                    return .error(400, "platform, deviceID and excluded (true or false) are required")
                }
                logger.info("Web UI user \(username) \(excluded ? "excluded" : "included") \(platform):\(deviceID)")
                let answer = try await catalog.setExcluded(platform: platform, name: name, deviceID: deviceID, excluded: excluded)
                noteConfigChange(by: username)
                return .json(answer)
            case ["part"]:
                guard !platform.isEmpty, let deviceID = body["deviceID"]?.stringValue, let part = body["part"]?.stringValue, !part.isEmpty,
                      let included = body["included"]?.boolValue else {
                    return .error(400, "platform, deviceID, part and included (true or false) are required")
                }
                logger.info("Web UI user \(username) \(included ? "included" : "left out") \(part) of \(platform):\(deviceID)")
                let answer = try await catalog.setPart(platform: platform, name: name, deviceID: deviceID, part: part, included: included)
                noteConfigChange(by: username)
                return .json(answer)
            case let path where path.count == 2 && path[1] == "state":
                // A Setup the Assistant started, taken over on the page.
                return .json(try catalog.setupState(path[0]))
            case let path where path.count == 2 && path[1] == "cancel":
                return .json(["cancelled": .bool(catalog.cancelSetup(path[0]))])
            case let path where path.count == 1:
                let answer = try await catalog.continueSetup(path[0], answers: body["answers"]?.objectValue ?? [:])
                noteSetup(answer, by: username)
                return .json(answer)
            default:
                return nil
            }
        } catch let error as CatalogError {
            return .error(400, error.message)
        } catch let error as SetupError {
            return .error(400, error.description)
        }
    }

    /// A Setup that is done changed config.json: the pages follow, as after any save.
    private func noteSetup(_ answer: JSONValue, by username: String) {
        guard answer["status"] == "done" else { return }
        logger.info("Web UI user \(username) set up \(answer["accessoryID"]?.stringValue ?? answer["name"]?.stringValue ?? "a plugin")")
        noteConfigChange(by: username)
    }
}
