import Foundation
import HomeswiftAI
import HomeswiftMCP

extension UIServer {
    /// The Status page's Matter card: `/api/matter` (the status, the pairing codes for an administrator while the
    /// window is open), `/api/matter/qr.svg`, and for administrators `POST /api/matter/window` and
    /// `POST /api/matter/fabrics/<index>/remove`.
    func matterRoute(_ route: [String], _ request: Request, body: JSONValue, username: String, admin: Bool) async throws -> Reply? {
        guard let matter = catalog.matter.current else {
            return route.isEmpty && request.method == .GET ? .json(["enabled": false]) : .error(404, "the Matter bridge is off: add a HomeswiftMatter block")
        }
        switch (request.method, route) {
        case (.GET, []):
            var status = await matter.statusJSON(includePairing: admin).objectValue ?? [:]
            status["enabled"] = true
            return .json(.object(status))
        case (.GET, ["qr.svg"]):
            // The pairing code is in it: for administrators, as the status's setup codes are.
            guard admin else { return .error(403, "only an administrator sees the pairing code") }
            guard let payload = await matter.statusJSON(includePairing: true)["pairing"]?["qrCode"]?.stringValue else {
                return .error(404, "the commissioning window is closed")
            }
            return .text(try QRCode(payload).svg(), contentType: "image/svg+xml")
        case (.POST, ["window"]):
            guard admin else { return .error(403, "only an administrator can open the commissioning window") }
            logger.info("Web UI user \(username) opened the Matter commissioning window")
            return .json(try await matter.openCommissioningWindow(minutes: body["minutes"]?.intValue ?? 15))
        case (.POST, _) where route.count == 3 && route[0] == "fabrics" && route[2] == "remove":
            guard admin else { return .error(403, "only an administrator can remove a fabric") }
            guard let index = Int(route[1]) else { return .error(400, "bad fabric index") }
            logger.info("Web UI user \(username) removed Matter fabric \(index)")
            do {
                return .json(try await matter.removeFabric(index: index))
            } catch let error as CatalogError {
                return .error(404, error.message)
            }
        default:
            return .error(404, "unknown Matter route")
        }
    }
}
