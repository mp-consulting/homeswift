import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import HomeswiftTPLinkSmarthome

/// The cipher, the framing and the commands against the spec's vectors (docs/clean-room/TPLinkSmarthome.md, section 9).
struct ProtocolTests {
    @Test func cipherVectors() {
        let vectors = [
            (#"{"system":{"get_sysinfo":{}}}"#, "d0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf08bf68bf6"),
            (#"{"system":{"set_relay_state":{"state":1}}}"#, "d0f281f88bff9af7d5ef94b6c5a0d48bf99cf091e8b7c4b0d1a5c0e2d8a381f286e793f6d4eedfa2dfa2"),
            (#"{"emeter":{"get_realtime":{}}}"#, "d0f297fa9feb8efcdee49fbddabfcb94e683e28efa93fe9bb983f885f885"),
            (#"{"system":{"get_sysinfo":{"err_code":0}}}"#, "d0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf08ba9ccbecc93f09ffb9ebc86b6cbb6cb"),
        ]
        for (plaintext, ciphertext) in vectors {
            #expect(Data(KasaCipher.encrypt(plaintext)).hex == ciphertext)
            #expect(String(decoding: KasaCipher.decrypt(Data(hex: ciphertext)), as: UTF8.self) == plaintext)
        }
        #expect(KasaCipher.encrypt([UInt8]()).isEmpty)
        #expect(Data(KasaCipher.frame(#"{"system":{"get_sysinfo":{}}}"#).prefix(4)).hex == "0000001d")
    }

    @Test func requestsAreWrittenInOrder() {
        #expect(KasaRequest.sysinfo.json == #"{"system":{"get_sysinfo":{}}}"#)
        let off = KasaRequest(module: "system", method: "set_relay_state", [("state", .int(0))], childID: "800612345678901234567890123456789012345601")
        #expect(off.json == #"{"system":{"set_relay_state":{"state":0}},"context":{"child_ids":["800612345678901234567890123456789012345601"]}}"#)
        #expect(Data(KasaCipher.frame(off.json).prefix(4)).hex == "00000071")
        #expect(Data(KasaCipher.encrypt(off.json)).hex == "d0f281f88bff9af7d5ef94b6c5a0d48bf99cf091e8b7c4b0d1a5c0e2d8a381f286e793f6d4eedea3def2d0b3dcb2c6a3dbaf8db7ccee8de58ce084dbb2d6a587bde6c4fcccfccafbc9facefbcdfac2fbcbfac8fbcffaccfbc3facafbc9facefbcdfac2fbcbfac8fbcffaccfccdefb2cfb2")
        let bulb = KasaRequest(
            module: "smartlife.iot.smartbulb.lightingservice", method: "transition_light_state", [("ignore_default", .int(1)), ("on_off", .int(1)), ("brightness", .int(50))])
        #expect(Data(KasaCipher.frame(bulb.json).prefix(4)).hex == "00000076")
        #expect(Data(KasaCipher.encrypt(bulb.json)).hex == "d0f281ec8dff8be78ee88da3caa5d1ff8ce180f286e491fd9fb1ddb4d3bbcfa6c8afdcb9cbbdd4b7d2f0cab193e795f49ae980f49df29cc3afc6a1c9bde291e584f095b78df6d4bddab4dba9cc93f792f495e08cf8dae0d1fddfb0de81ee88eeccf6c7ebc9abd9b0d7bfcba5c0b3c0e2d8eddda0dda0")
    }

    @Test func responsesAreChecked() throws {
        let request = KasaRequest(module: "system", method: "set_relay_state", [("state", .int(1))])
        #expect(try request.result(of: #"{"system":{"set_relay_state":{"err_code":0}}}"#)["err_code"]?.intValue == 0)
        #expect(throws: KasaResponseError.self) { try request.result(of: #"{"system":{"set_relay_state":{"err_code":-3,"err_msg":"invalid argument"}}}"#) }
        #expect(throws: KasaResponseError.self) { try request.result(of: #"{"system":{"set_relay_state":{}}}"#) }
        #expect(throws: KasaResponseError.self) { try request.result(of: "not json") }
    }

    @Test func framesAreReadAcrossSegments() throws {
        let frame = KasaCipher.frame(#"{"system":{"get_sysinfo":{"err_code":0}}}"#)
        var reader = KasaFrameReader()
        #expect(try reader.add(frame[0..<2]) == nil)
        #expect(try reader.add(frame[2..<20]) == nil)
        #expect(try reader.add(frame[20...]) == #"{"system":{"get_sysinfo":{"err_code":0}}}"#)
        // Bytes after the announced length are not part of it.
        var trailing = KasaFrameReader()
        #expect(try trailing.add(frame + [0x41, 0x42]) == #"{"system":{"get_sysinfo":{"err_code":0}}}"#)
        var huge = KasaFrameReader()
        #expect(throws: KasaFrameReader.Failure.self) { try huge.add([0x7F, 0, 0, 0]) }
    }

    @Test func energyReadingsOfBothFirmwares() throws {
        let v2 = KasaEnergyReading(try JSONValue(string: #"{"voltage_mv":121512,"current_ma":82,"power_mw":4380,"total_wh":1520,"err_code":0}"#))
        #expect(v2.volts == 121.512)
        #expect(v2.amperes == 0.082)
        #expect(v2.watts == 4.38)
        #expect(v2.kilowattHours == 1.52)
        #expect(abs((v2.voltAmperes ?? 0) - 9.964) < 0.001)
        let v1 = KasaEnergyReading(try JSONValue(string: #"{"current":0.1256,"voltage":122.05,"power":3.14,"total":51.493,"err_code":0}"#))
        #expect(v1.watts == 3.14)
        #expect(v1.kilowattHours == 51.493)
    }

    @Test func colourTemperatures() {
        #expect(KasaColorTemperature.miredRange(model: "LB130(US)") == 112...400)
        #expect(KasaColorTemperature.miredRange(model: "KL120(US)") == 200...370)
        #expect(KasaColorTemperature.miredRange(model: "KL125(US)") == 154...400)
        #expect(KasaColorTemperature.miredRange(model: "KL120(JP)") == 154...370)
        let wide = 112...400
        #expect(KasaColorTemperature.mireds(kelvin: 2700, within: 154...370) == 370)
        #expect(KasaColorTemperature.mireds(kelvin: 6500, within: 154...370) == 154)
        #expect(KasaColorTemperature.mireds(kelvin: 4000, within: wide) == 250)
        // 9000 K rounds to 111, below the props: clamped.
        #expect(KasaColorTemperature.mireds(kelvin: 9000, within: wide) == 112)
        #expect(KasaColorTemperature.kelvin(mireds: 250) == 4000)
        #expect(KasaColorTemperature.kelvin(mireds: 112) == 8929)
        #expect(KasaColorTemperature.kelvin(mireds: 370) == 2703)
    }

    @Test func macPatterns() {
        #expect(KasaMACFilter(allow: ["aa:bb:*"], deny: nil).rejection(of: "AA:BB:CC:00:11:22") == nil)
        #expect(KasaMACFilter(allow: ["AABBCC00112?"], deny: nil).rejection(of: "AA:BB:CC:00:11:22") == nil)
        #expect(KasaMACFilter(allow: ["AABB"], deny: nil).rejection(of: "AA:BB:CC:00:11:22") != nil)
        #expect(KasaMACFilter(allow: nil, deny: ["*1122"]).rejection(of: "aa-bb-cc-00-11-22") != nil)
        #expect(KasaMACFilter(allow: [], deny: []).rejection(of: "AA:BB:CC:00:11:22") == nil)
    }

    @Test func childIDs() {
        let device = String(repeating: "D", count: 40)
        #expect(KasaSysinfo.childID("3", deviceID: device) == device + "03")
        #expect(KasaSysinfo.childID("03", deviceID: device) == device + "03")
        #expect(KasaSysinfo.childID(device + "03", deviceID: device) == device + "03")
    }

    @Test func sysinfoShapes() throws {
        let plug = try #require(KasaSysinfo(try JSONValue(string: Fixtures.hs110)))
        #expect(plug.kind == .plug)
        #expect(plug.supportsEnergy)
        #expect(KasaPresentation.of(plug, switchModels: ["HS200", "HS210"]) == .outlet)
        let dimmer = try #require(KasaSysinfo(try JSONValue(string: Fixtures.hs220)))
        #expect(KasaPresentation.of(dimmer, switchModels: ["HS200", "HS210"]) == .dimmer)
        #expect(KasaPresentation.of(dimmer, switchModels: ["HS220"]) == .switch)
        let strip = try #require(KasaSysinfo(try JSONValue(string: Fixtures.hs300(shortIDs: true))))
        #expect(strip.children?.first?.id == Fixtures.hs300ID + "00")
        let light = try #require(KasaSysinfo(try JSONValue(string: Fixtures.kl430Off)))
        #expect(light.isLightStrip)
        #expect(KasaSysinfo(try JSONValue(string: #"{"alias":"x","deviceId":"1","model":"m","sw_ver":"1","hw_ver":"1","type":"IOT.SMARTPLUGSWITCH","mac":"","feature":"TIM","children":null}"#)) == nil)
        #expect(KasaSysinfo(try JSONValue(string: Fixtures.hs110.replacingOccurrences(of: Fixtures.hs110ID, with: "../../etc"))) == nil)
        #expect(KasaSysinfo.firmwareRevision("1.5.7 Build 180912 Rel.104837") == "1.5.7")
        #expect(KasaSysinfo.discoveryReply(Data(KasaCipher.encrypt("garbage"))) == nil)
        #expect(KasaSysinfo.discoveryReply(Data(KasaCipher.encrypt(#"{"system":{}}"#))) == nil)
    }

    @Test func locationIsMaskedInLogs() {
        #expect(KasaLog.masked(#"{"latitude_i":515000,"longitude":-0.12,"alias":"x"}"#) == #"{"latitude_i":"…","longitude":"…","alias":"x"}"#)
    }

    @Test func configurationTakesPortAsNumberOrString() throws {
        let block = #"{"platform":"TplinkSmarthome","name":"TplinkSmarthome","devices":[{"host":"10.0.0.5","port":"9999"},{"host":"10.0.0.6","port":10000},{"host":"10.0.0.7"}]}"#
        let configuration = try JSONDecoder().decode(TPLinkSmarthomePlugin.Configuration.self, from: Data(block.utf8))
        #expect(configuration.devices?.map(\.port) == [9999, 10000, nil])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TPLinkSmarthomePlugin.Configuration.self, from: Data(#"{"devices":[{"host":"a","port":"x"}]}"#.utf8))
        }
        let minimal = try JSONDecoder().decode(TPLinkSmarthomePlugin.Configuration.self, from: Data(#"{"platform":"TplinkSmarthome","name":"TplinkSmarthome"}"#.utf8))
        #expect(minimal.pollingInterval == nil)
    }

    /// The real TCP transport against a device on the loopback that answers in three segments.
    @Test(.timeLimit(.minutes(1))) func tcpTransportReadsASplitResponse() async throws {
        let response = KasaCipher.frame(#"{"system":{"get_sysinfo":{"alias":"Lamp","err_code":0}}}"#)
        let received = NIOLockedValueBoxString()
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(SplitResponder(response: response, received: received)) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }
        let port = try #require(server.localAddress?.port)
        let answer = try await KasaNetworkTransport().send(KasaRequest.sysinfo.json, host: "127.0.0.1", port: port, udp: false, timeout: .seconds(5))
        #expect(answer == #"{"system":{"get_sysinfo":{"alias":"Lamp","err_code":0}}}"#)
        #expect(received.value == #"{"system":{"get_sysinfo":{}}}"#)
    }

    @Test(.timeLimit(.minutes(1))) func tcpTransportTimesOut() async throws {
        // A server that never answers.
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }
        let port = try #require(server.localAddress?.port)
        await #expect(throws: KasaTimeout.self) {
            _ = try await KasaNetworkTransport().send(KasaRequest.sysinfo.json, host: "127.0.0.1", port: port, udp: false, timeout: .milliseconds(200))
        }
    }
}

final class NIOLockedValueBoxString: Sendable {
    private let box = NIOLockedValueBox("")
    var value: String { box.withLockedValue { $0 } }
    func set(_ value: String) { box.withLockedValue { $0 = value } }
}

/// Reads one request frame, then answers `response` in three writes.
private final class SplitResponder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let response: [UInt8]
    let received: NIOLockedValueBoxString
    var reader = KasaFrameReader()

    init(response: [UInt8], received: NIOLockedValueBoxString) {
        self.response = response
        self.received = received
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let request = try? reader.add(unwrapInboundIn(data).readableBytesView) else { return }
        received.set(request)
        let thirds = [response[0..<3], response[3..<10], response[10...]]
        for part in thirds {
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: part)), promise: nil)
        }
    }
}
