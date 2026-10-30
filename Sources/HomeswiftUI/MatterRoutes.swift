import Foundation
import HomeswiftAI
import HomeswiftMCP

extension UIServer {
    /// The Status page's Matter card: `/api/matter` (the status, the pairing codes for an administrator while a window
    /// is open), `/api/matter/qr.svg`, and for administrators `POST /api/matter/window` and
    /// `POST /api/matter/fabrics/<index>/remove`. The same under `/api/matter/devices/<accessory id>/` act on an
    /// accessory that is a Matter device of its own, and `PUT /api/matter/devices/<accessory id>` with `{"own": true}`
    /// makes it one (or `false` puts it back), which works with Matter off too: it turns Matter on for that accessory.
    func matterRoute(_ route: [String], _ request: Request, body: JSONValue, username: String, admin: Bool) async throws -> Reply? {
        do {
            return try await matterReply(route, request, body: body, username: username, admin: admin)
        } catch let error as CatalogError {
            return .error(404, error.message)
        }
    }

    private func matterReply(_ route: [String], _ request: Request, body: JSONValue, username: String, admin: Bool) async throws -> Reply {
        if request.method == .PUT, route.count == 2, route[0] == "devices" {
            guard admin else { return .error(403, "only an administrator changes what is on Matter") }
            guard let own = body["own"]?.boolValue else { return .error(400, "own must be true or false") }
            logger.info("Web UI user \(username) \(own ? "made" : "took back") \(route[1]) as a Matter device of its own")
            return .json(try await catalog.setMatterDevice(route[1], own: own))
        }
        guard let matter = catalog.matter.current else {
            return route.isEmpty && request.method == .GET ? .json(["enabled": false]) : .error(404, "Matter is off: add a HomeswiftMatter block")
        }
        // The device a route acts on, or nil for the bridge.
        var route = route
        var device: String?
        if route.count >= 2, route[0] == "devices" {
            device = route[1]
            route.removeFirst(2)
        }
        switch (request.method, route) {
        case (.GET, []) where device == nil:
            var status = await matter.statusJSON(includePairing: admin).objectValue ?? [:]
            status["enabled"] = true
            return .json(.object(status))
        case (.GET, ["qr.svg"]):
            // The pairing code is in it: for administrators, as the status's setup codes are.
            guard admin else { return .error(403, "only an administrator sees the pairing code") }
            guard let payload = await matter.qrCode(device: device) else { return .error(404, "the commissioning window is closed") }
            return .text(try QRCode(payload).svg(), contentType: "image/svg+xml")
        case (.POST, ["window"]):
            guard admin else { return .error(403, "only an administrator can open the commissioning window") }
            logger.info("Web UI user \(username) opened the Matter commissioning window of \(device ?? "the bridge")")
            return .json(try await matter.openCommissioningWindow(minutes: body["minutes"]?.intValue ?? 15, device: device))
        case (.POST, _) where route.count == 3 && route[0] == "fabrics" && route[2] == "remove":
            guard admin else { return .error(403, "only an administrator can remove a fabric") }
            guard let index = Int(route[1]) else { return .error(400, "bad fabric index") }
            logger.info("Web UI user \(username) removed Matter fabric \(index) of \(device ?? "the bridge")")
            return .json(try await matter.removeFabric(index: index, device: device))
        default:
            return .error(404, "unknown Matter route")
        }
    }
}
