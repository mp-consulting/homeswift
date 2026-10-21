import Foundation
import Homeswift
import Logging

// A Homeswift bridge with ACCESSORIES lightbulbs (On, Brightness, Hue, Saturation), the counterpart of
// hap-nodejs/server.js. Configured through the environment hap-bench sets: PORT, PIN, ACCESSORIES, STORAGE
// (a directory), ADVERTISE (0 to skip Bonjour) and DEVICE_ID.
@main
struct BenchServer {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = Int(env["PORT"] ?? "52000") ?? 52000
        let pin = env["PIN"] ?? "031-45-154"
        let count = Int(env["ACCESSORIES"] ?? "30") ?? 30
        var logger = Logger(label: "homeswift")
        logger.logLevel = env["HAP_DEBUG"] != nil ? .trace : .warning

        var lamps: [Accessory] = []
        for index in 1...max(1, count) {
            let light = Service(.lightbulb, name: "Bench Lamp \(index)", optional: [.brightness, .hue, .saturation], isPrimary: true)
            for type in [CharacteristicType.on, .brightness, .hue, .saturation] {
                light.characteristic(type).onWrite { _ in }
            }
            lamps.append(Accessory(
                id: "bench-lamp-\(index)", name: "Bench Lamp \(index)", manufacturer: "Bench", model: "Lamp",
                category: .lightbulb, services: [light]))
        }
        let bridge = Accessory(
            id: "bench-bridge", name: "Bench Bridge Homeswift", manufacturer: "Bench", model: "Bridge", category: .bridge,
            services: [Service(.protocolInformation, extra: [Characteristic(.version, value: "1.1.0")])])
        let storage: any HAPStorage = env["STORAGE"].map { FileStorage(url: URL(fileURLWithPath: $0).appendingPathComponent("homeswift.json")) } ?? MemoryStorage()
        guard let code = SetupCode(pin) else {
            FileHandle.standardError.write(Data("PIN must look like 031-45-154\n".utf8))
            exit(1)
        }
        let server = try HAPServer(
            bridge: bridge, accessories: lamps, storage: storage,
            options: .init(setupCode: code, deviceID: env["DEVICE_ID"], port: port, advertise: env["ADVERTISE"] != "0", logger: logger))
        try await server.run()
    }
}
