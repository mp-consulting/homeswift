import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers

@testable import HomeswiftTapo

/// A camera's control API in memory (docs/clean-room/TapoPTZ.md): discover, the encrypt_type 3 login checked step by
/// step, and `securePassthrough` requests whose `Seq` and `Tapo_tag` are checked before they are answered.
final class FakeTapoControlCamera: HTTPSending, @unchecked Sendable {
    struct State {
        var password = "password123"
        var presets: [(id: String, name: String)] = [("1", "Gate"), ("2", "Drive")]
        /// The error getPresetConfig answers with (a camera without a motor), when set.
        var presetError: Int?
        var moves: [(x: Int, y: Int)] = []
        var presetsVisited: [String] = []
        /// The sweeps started (`x`, `y`) and stopped (`stop`), in order.
        var cruises: [String] = []
        /// What getDeviceInfo answers in `basic_info` (docs/clean-room/TapoBattery.md, 2.1), and how often it was asked.
        var basicInfo: [String: Any] = ["power": "SOLAR", "battery_percent": 64, "battery_charging": "NO", "low_battery": false]
        var deviceInfoReads = 0
        var logins = 0
        var discovers = 0
        var badTags = 0
        /// The next requests fail as a pinned certificate that changed would.
        var certificateChanges = 0
        var cnonce = "", nonce = "", stok = "", seq = 0
        var cipher: SecurePassthrough.Cipher?
        var hash = ""
        /// Holds each reply this long, so calls can overlap.
        var delay: Duration = .zero
    }

    let state = NIOLockedValueBox(State())

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let delay = state.withLockedValue { $0.delay }
        if delay > .zero { try await Task.sleep(for: delay) }
        let changed = state.withLockedValue { state -> Bool in
            guard state.certificateChanges > 0 else { return false }
            state.certificateChanges -= 1
            return true
        }
        if changed { throw HTTPClientError.certificateMismatch(expected: "aa", observed: "bb") }
        let body = request.body ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let headers = Dictionary(request.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let answer: [String: Any] = try state.withLockedValue { state in
            let path = request.url.path
            if path == "/" {
                let params = json["params"] as? [String: Any] ?? [:]
                if params["sub_method"] as? String == "discover" {
                    state.discovers += 1
                    return ["error_code": -40413, "result": ["data": ["encrypt_type": ["3"]]]]
                }
                let cnonce = params["cnonce"] as? String ?? ""
                let hash = Streamd.passwordHash(state.password, sha256: true)
                guard let digest = params["digest_passwd"] as? String else {
                    state.cnonce = cnonce
                    state.nonce = "9F8E7D6C5B4A39281706F5E4D3C2B1A0"
                    return ["error_code": -40413, "result": ["data": [
                        "nonce": state.nonce, "device_confirm": TapoControlCrypto.deviceConfirm(cnonce: cnonce, hash: hash, nonce: state.nonce),
                    ]]]
                }
                guard cnonce == state.cnonce, digest == TapoControlCrypto.digestPassword(cnonce: cnonce, hash: hash, nonce: state.nonce) else {
                    return ["error_code": -40209]
                }
                state.logins += 1
                state.stok = "stok\(state.logins)"
                state.seq = 100
                state.hash = hash
                state.cipher = TapoControlCrypto.cipher(cnonce: cnonce, hash: hash, nonce: state.nonce)
                return ["error_code": 0, "result": ["stok": state.stok, "start_seq": state.seq, "user_group": "root"]]
            }
            guard path == "/stok=\(state.stok)/ds", let cipher = state.cipher else { return ["error_code": -40401] }
            let text = String(decoding: body, as: UTF8.self)
            guard headers["seq"] == String(state.seq),
                  headers["tapo_tag"] == TapoControlCrypto.tag(hash: state.hash, cnonce: state.cnonce, body: text, seq: state.seq) else {
                state.badTags += 1
                return ["error_code": -40401]
            }
            state.seq += 1
            let encrypted = ((json["params"] as? [String: Any])?["request"] as? String) ?? ""
            let inner = try JSONSerialization.jsonObject(with: try cipher.decrypt(encrypted)) as? [String: Any] ?? [:]
            let call = (((inner["params"] as? [String: Any])?["requests"] as? [[String: Any]]) ?? []).first ?? [:]
            let method = call["method"] as? String ?? ""
            let params = call["params"] as? [String: Any] ?? [:]
            var entry: [String: Any] = ["method": method, "result": [String: Any](), "error_code": 0]
            switch method {
            case "getPresetConfig":
                if let code = state.presetError {
                    entry["error_code"] = code
                } else {
                    entry["result"] = ["preset": ["preset": ["id": state.presets.map(\.id), "name": state.presets.map(\.name)]]]
                }
            case "relativeMove":
                let move = ((params["motor"] as? [String: Any])?["move"] as? [String: Any]) ?? [:]
                state.moves.append((Int(move["x_coord"] as? String ?? "") ?? 0, Int(move["y_coord"] as? String ?? "") ?? 0))
            case "cruiseMove":
                state.cruises.append((((params["motor"] as? [String: Any])?["cruise"] as? [String: Any])?["coord"] as? String) ?? "?")
            case "cruiseStop":
                state.cruises.append("stop")
            case "getDeviceInfo":
                state.deviceInfoReads += 1
                entry["result"] = ["device_info": ["basic_info": state.basicInfo]]
            case "motorMoveToPreset":
                let id = (((params["preset"] as? [String: Any])?["goto_preset"] as? [String: Any])?["id"] as? String) ?? ""
                if state.presets.contains(where: { $0.id == id }) { state.presetsVisited.append(id) } else { entry["error_code"] = -64302 }
            default:
                entry["error_code"] = -40106
            }
            let reply = try JSONSerialization.data(withJSONObject: ["result": ["responses": [entry]], "error_code": 0])
            return ["error_code": 0, "result": ["response": try cipher.encrypt(reply)]]
        }
        return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: answer))
    }
}
