import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing
#if canImport(Glibc)
import Glibc
#endif

@testable import Homeswift
@testable import HomeswiftUniFiProtect

@Suite struct ConfigurationTests {
    /// A block as users have it in Homebridge's config.json, every option set.
    static let fullBlock = """
    {
      "platform": "UniFi Protect",
      "name": "UniFi Protect",
      "controllers": [
        {
          "address": "192.168.1.1",
          "username": "homebridge",
          "password": "your-password",
          "name": "UNVR",
          "overrideAddress": "10.0.0.1",
          "verifyTls": false,
          "playlistAddress": "127.0.0.1",
          "playlistToken": "a-long-random-string",
          "mqttUrl": "mqtt://user:pass@1.2.3.4",
          "mqttTopic": "unifi/protect",
          "mqttVerifyTls": "false",
          "doorbellMessages": [
            { "message": "I'll be there soon.", "duration": 60 },
            { "message": "Leave it at the door", "duration": "0" },
            { "message": "Default duration" }
          ],
          "cameraOverrides": [
            { "mac": "F6:24:49:03:A5:B3", "rtspUrl": "rtsp://user:pass@192.168.1.50:8554/stream", "snapshotUrl": "http://192.168.1.50:8080/snapshot",
              "onvifPort": "2020", "onvifUsername": "admin", "onvifPassword": "pw", "onvifServicePath": "/onvif/device_service" },
            { "rtspUrl": "rtsp://no-mac" }
          ]
        },
        { "address": "192.168.2.1", "username": "u", "password": "p" }
      ],
      "options": ["Enable.Motion.SmartDetect", "Disable.Device.F4E2C6000001", 42],
      "ringDelay": "5",
      "verboseFfmpeg": true,
      "videoProcessor": "/usr/local/bin/ffmpeg",
      "debug": true,
      "_bridge": { "username": "0E:1A:2B:3C:4D:5F" }
    }
    """

    @Test func decodesAFullBlock() throws {
        let configuration = try JSONDecoder().decode(UniFiProtectPlugin.Configuration.self, from: Data(Self.fullBlock.utf8))
        #expect(configuration.controllers.count == 2)
        let controller = configuration.controllers[0]
        #expect(controller.address == "192.168.1.1" && controller.username == "homebridge" && controller.password == "your-password")
        #expect(controller.name == "UNVR" && controller.overrideAddress == "10.0.0.1" && controller.verifyTls == false)
        #expect(controller.playlistAddress == "127.0.0.1" && controller.playlistToken == "a-long-random-string")
        #expect(controller.mqttUrl == "mqtt://user:pass@1.2.3.4" && controller.mqttTopic == "unifi/protect" && controller.mqttVerifyTls == false)
        #expect(controller.doorbellMessages.map(\.message) == ["I'll be there soon.", "Leave it at the door", "Default duration"])
        #expect(controller.doorbellMessages.map(\.duration) == [60, 0, nil])
        #expect(controller.cameraOverrides.count == 1)
        #expect(controller.cameraOverrides[0].onvifPort == 2020)
        #expect(controller.cameraOverride(mac: "f6244903a5b3")?.rtspUrl == "rtsp://user:pass@192.168.1.50:8554/stream")
        #expect(controller.cameraOverride(mac: "F6-24-49-03-A5-B3") != nil)
        #expect(controller.cameraOverride(mac: "") == nil && controller.cameraOverride(mac: "001122334455") == nil)
        #expect(configuration.controllers[1].mqttTopic == "unifi/protect" && configuration.controllers[1].mqttUrl == nil)
        #expect(configuration.options == ["Enable.Motion.SmartDetect", "Disable.Device.F4E2C6000001"])
        #expect(configuration.ringDelay == 5 && configuration.verboseFfmpeg && configuration.debug)
        #expect(configuration.videoProcessor == "/usr/local/bin/ffmpeg")
    }

    @Test func decodesAMinimalBlock() throws {
        let configuration = try JSONDecoder().decode(UniFiProtectPlugin.Configuration.self, from: Data(#"{"platform":"UniFi Protect"}"#.utf8))
        #expect(configuration.controllers.isEmpty && configuration.options.isEmpty && configuration.ringDelay == 0 && !configuration.debug)
    }

    @Test func schemaIsEmbedded() throws {
        let schema = try JSONValue(string: try #require(UniFiProtectPlugin.configurationSchemaJSON))
        #expect(schema.string("pluginAlias") == "UniFi Protect")
        #expect(schema.at("schema.properties.controllers.items.properties.cameraOverrides") != nil)
        #expect(UniFiProtectPlugin.webFiles["index.html"] != nil)
    }

    /// The embedded page and schema match the files: run Scripts/embed-assets.swift after editing them.
    @Test func embeddedFilesAreCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let web = root.appendingPathComponent("Web")
        let names = try FileManager.default.contentsOfDirectory(atPath: web.path).filter { !$0.hasPrefix(".") }
        #expect(Set(names) == Set(UniFiProtectPlugin.webFiles.keys))
        for name in names {
            #expect(UniFiProtectPlugin.webFiles[name]?.body == (try String(contentsOf: web.appendingPathComponent(name), encoding: .utf8)), "\(name) is stale")
        }
        let schema = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(UniFiProtectPlugin.configurationSchemaJSON == schema)
    }

    @Test func normalizesMACs() {
        #expect(normalizeMAC("F6:24:49:03:A5:B3") == "f6244903a5b3")
        #expect(normalizeMAC("f6-24-49-03-a5-b3") == normalizeMAC("F6244903A5B3"))
    }
}

@Suite struct UtilityTests {
    @Test func mergesJSON() {
        let base: JSONValue = ["a": 1, "nested": ["x": 1, "y": 2], "list": [1, 2]]
        #expect(base.merging(["b": 2]) == ["a": 1, "b": 2, "nested": ["x": 1, "y": 2], "list": [1, 2]])
        #expect(base.merging(["nested": ["y": 3, "z": 4]]).at("nested") == ["x": 1, "y": 3, "z": 4])
        #expect(base.merging(["list": [3]]).at("list") == [3])
        #expect(base.merging(["nested": [1]]).at("nested") == [1])
        #expect(base.merging(["list": ["k": true]]).at("list") == ["k": true])
        #expect(base.merging(["a": .null]).at("a") == .null)
        #expect(base.merging([:]) == base)
        #expect(JSONValue.object([:]).merging(["a": 1]) == ["a": 1])
        let deep: JSONValue = ["l1": ["l2": ["l3": ["keep": true, "change": 1]]]]
        #expect(deep.merging(["l1": ["l2": ["l3": ["change": 2]]]]) == ["l1": ["l2": ["l3": ["keep": true, "change": 2]]]])
        // A camera update: the ISP settings change, the channels stay.
        let camera = Fixtures.camera()
        let updated = camera.merging(["ispSettings": ["irLedMode": "off"], "isConnected": false])
        #expect(updated.string("ispSettings.irLedMode") == "off" && updated.int("ispSettings.icrCustomValue") == 5 && !updated.bool("isConnected"))
        #expect(updated.array("channels").count == 3)
    }

    @Test func names() {
        #expect(toCamelCase("hello world") == "Hello World")
        #expect(toCamelCase("x") == "X" && toCamelCase("") == "")
        #expect(toCamelCase("licensePlate") == "LicensePlate")
        #expect(sanitizeName("Front Door") == "Front Door")
        #expect(sanitizeName("  Garage 🚗 Cam!! ") == "Garage Cam")
        #expect(sanitizeName("#1 Camera") == "1 Camera")
        #expect(ProtectCamera.parseLicensePlates("abc123-XYZ--9") == ["ABC123", "XYZ", "9"])
        #expect(ProtectCamera.parseLicensePlates("-") == [] && ProtectCamera.parseLicensePlates(nil) == [])
    }

    @Test func audioFilters() {
        #expect(buildAudioFilterPipeline(fftNr: 14, highpass: nil, lowpass: nil) == ["asendcmd=c='1.0 afftdn sn start ; 3.0 afftdn sn stop', afftdn=nt=c:tn=1:nr=14"])
        #expect(buildAudioFilterPipeline(fftNr: 200, highpass: 150, lowpass: 9000)
            == ["highpass=p=2:f=150", "lowpass=p=2:f=9000", "asendcmd=c='1.0 afftdn sn start ; 3.0 afftdn sn stop', afftdn=nt=c:tn=1:nr=97"])
        #expect(buildAudioFilterPipeline(fftNr: 0, highpass: nil, lowpass: nil).last?.hasSuffix("nr=0.01") == true)
    }

    // MARK: RTSP selection (rtsp-resolution.test.ts, resolution-generation.test.ts)

    static func entry(_ name: String, _ width: Int, _ height: Int, _ fps: Int = 30) -> RtspEntry {
        let channel = ProtectChannel(["name": .string(name), "width": .number(Double(width)), "height": .number(Double(height)), "fps": .number(Double(fps))])
        return RtspEntry(channel: channel, name: name, resolution: VideoResolution(width, height, fps), url: "rtsps://x/\(name)")
    }

    static let entries = [entry("High", 3840, 2160), entry("Medium", 1920, 1080), entry("Low", 1280, 720)]

    @Test func findsStreams() {
        #expect(RtspSelection.find(Self.entries, width: 1920, height: 1080)?.channel.name == "Medium")
        #expect(RtspSelection.find(Self.entries, width: 3840, height: 2160)?.channel.name == "High")
        #expect(RtspSelection.find(Self.entries, width: 1280, height: 720)?.channel.name == "Low")
        #expect(RtspSelection.find(Self.entries, width: 2560, height: 1440)?.channel.name == "Medium")
        #expect(RtspSelection.find(Self.entries, width: 320, height: 180)?.channel.name == "Low")
        // Same width, other height: a strictly narrower stream.
        #expect(RtspSelection.find(Self.entries, width: 1920, height: 1440)?.channel.name == "Low")
        #expect(RtspSelection.find(Self.entries, width: 2560, height: 1440, options: .init(biasHigher: true))?.channel.name == "High")
        #expect(RtspSelection.find(Self.entries, width: 7680, height: 4320, options: .init(biasHigher: true))?.channel.name == "High")
        #expect(RtspSelection.find(Self.entries, width: 320, height: 180, options: .init(biasHigher: true))?.channel.name == "Low")
        #expect(RtspSelection.find(Self.entries, width: 320, height: 180, options: .init(preferred: "high"))?.channel.name == "High")
        #expect(RtspSelection.find(Self.entries, width: 320, height: 180, options: .init(preferred: "Nope")) == nil)
        #expect(RtspSelection.find([], width: 1920, height: 1080) == nil)
        #expect(RtspSelection.find([Self.entries[2]], width: 3840, height: 2160)?.channel.name == "Low")
        #expect(RtspSelection.find(Self.entries, width: 3840, height: 2160, options: .init(maxPixels: 1920 * 1080))?.channel.name == "Medium")
        #expect(RtspSelection.find(Self.entries, width: 3840, height: 2160, options: .init(maxPixels: 100)) == nil)
        let sorted = [Self.entry("a", 1280, 720), Self.entry("b", 1920, 1080), Self.entry("c", 1920, 1440), Self.entry("d", 1920, 1080, 15)].sorted(by: RtspSelection.sortByResolutions)
        #expect(sorted.map(\.channel.name) == ["c", "b", "d", "a"])
        #expect(VideoResolution(1920, 1080, 30).formatted == "1920x1080@30fps")
    }

    @Test func generatesHomeKitResolutions() throws {
        let native = [Self.entry("High", 2688, 1512), Self.entry("Medium", 1280, 720), Self.entry("Low", 640, 360)]
        let entries = try #require(ProtectCamera.homeKitResolutions(for: native))
        let sizes = entries.map { "\($0.resolution.width)x\($0.resolution.height)" }
        // 16:9 sizes below the native width, plus 1080p and 720p which HomeKit requires.
        #expect(sizes.contains("2688x1512") && sizes.contains("2560x1440") && sizes.contains("1920x1080") && sizes.contains("1280x720") && !sizes.contains("3840x2160"))
        #expect(entries.first { $0.resolution.width == 1920 }?.channel.name == "Medium")
        #expect(entries.first { $0.resolution.width == 2560 }?.channel.name == "Medium")
        #expect(entries.first { $0.resolution.width == 320 }?.channel.name == "Low")
        let fourThree = try #require(ProtectCamera.homeKitResolutions(for: [Self.entry("High", 2560, 1920, 20), Self.entry("Low", 1280, 960, 20)]))
        #expect(fourThree.contains { $0.resolution.width == 1920 && $0.resolution.height == 1440 })
        // HKSV wants 15, 24 or 30 fps: the 1080p-class entry is adjusted when the camera's rate is none of those.
        #expect(fourThree.first { $0.resolution.width == 1920 && $0.resolution.height == 1440 }?.resolution.fps == 24)
        #expect(ProtectCamera.homeKitResolutions(for: []) == nil)
    }

    // MARK: Assistant (homebridge-ui/assistant.js)

    @Test func assistantBackground() throws {
        let background = try #require(UniFiProtectPlugin.assistantBackground)
        #expect(background.count > 1000 && background.contains("Homeswift") && !background.contains("Homebridge"))
        // The files and messages the port has.
        #expect(background.contains(ProtectSettings.tlsPinFile) && background.contains("plugins/"))
        #expect(background.contains("Invalid login credentials given") && background.contains("Throttling API calls"))
    }

    // MARK: Playlist (protect-playlist.test.ts, playlist-filter.test.ts)

    @Test func playlist() {
        #expect(ProtectPlaylist.sanitize("A \"quoted\"\nname") == "A quotedname")
        #expect(ProtectPlaylist.sanitize("Front, Door", isTitle: true) == "Front Door")
        #expect(ProtectPlaylist.generate(nil) == "#EXTM3U\n")
        let av1 = Fixtures.camera(id: "c3", mac: "C3", name: "AV1").setting("videoCodec", "av1")
        let noRtsp = Fixtures.camera(id: "c4", mac: "C4", name: "Dark").setting("channels", Fixtures.channels(rtsp: false))
        let evil = Fixtures.camera(id: "c5", mac: "C5", name: "Evil\"\n#EXTINF:0,Injected\nrtsp://evil")
        let bootstrap = Fixtures.bootstrap(cameras: [Fixtures.doorbell(), Fixtures.camera(), av1, noRtsp, evil])
        let playlist = ProtectPlaylist.generate(bootstrap)
        let lines = playlist.split(separator: "\n").map(String.init)
        #expect(lines.first == "#EXTM3U")
        #expect(lines.filter { $0.hasPrefix("#EXTINF") }.count == 4)
        #expect(!playlist.contains("AV1") && !playlist.contains("Dark"))
        #expect(!lines.contains { $0.hasPrefix("rtsp://evil") })
        // Sorted by name, the package camera right after its doorbell.
        let names = lines.filter { $0.hasPrefix("#EXTINF") }.map { $0.components(separatedBy: ", ").last ?? "" }
        #expect(names == ["Driveway", "Evil#EXTINF:0Injectedrtsp://evil", "Front Door", "Front Door Package Camera"])
        #expect(lines.contains("rtsp://192.168.1.1:7447/highAlias") && lines.contains("rtsp://192.168.1.1:7447/packageAlias"))
        #expect(ProtectPlaylist.isAuthorized(path: "/", token: nil))
        #expect(ProtectPlaylist.isAuthorized(path: "/?token=secret", token: "secret"))
        #expect(!ProtectPlaylist.isAuthorized(path: "/?token=wrong", token: "secret"))
        #expect(!ProtectPlaylist.isAuthorized(path: "/", token: "secret"))
    }

    // MARK: The settings page's helpers (ui-server.test.ts)

    @Test func addressValidation() async throws {
        for blocked in ["127.0.0.1", "0.0.0.0", "169.254.169.254", "::1", "::", "fe80::1", "::ffff:127.0.0.1", "::ffff:7f00:1", "fd00:ec2::254", "not-an-ip"] {
            #expect(AddressValidation.isBlocked(blocked), "\(blocked)")
        }
        for allowed in ["192.168.1.1", "10.0.0.5", "fd12::1", "2001:db8::1"] { #expect(!AddressValidation.isBlocked(allowed), "\(allowed)") }
        #expect(AddressValidation.canonicalHostname("0x7f.1") == "127.0.0.1")
        #expect(AddressValidation.canonicalHostname("2130706433") == "127.0.0.1")
        #expect(AddressValidation.canonicalHostname("unvr.local:443") == "unvr.local")
        #expect(AddressValidation.canonicalHostname("[fe80::1]") == "fe80::1")
        #expect(AddressValidation.canonicalHostname("  ") == nil)
        await #expect(throws: AddressValidation.Failure.notPermitted("evil.local")) {
            try await AddressValidation.resolveAllowed("evil.local") { _ in ["192.168.1.5", "127.0.0.1"] }
        }
        let vetted = try await AddressValidation.resolveAllowed("unvr.local") { _ in ["192.168.1.5"] }
        #expect(vetted == .init(address: "192.168.1.5", hostname: "unvr.local"))
        await #expect(throws: AddressValidation.Failure.notPermitted("127.0.0.1")) { try await AddressValidation.resolveAllowed("0x7f.1") }
    }

    final class SnapshotServer: ProtectHTTPTransport, @unchecked Sendable {
        let status: Int
        let contentType: String?
        let body: Data
        var seen: [HomeswiftNetwork.HTTPRequest] = []

        init(status: Int = 200, contentType: String? = "image/jpeg", body: Data = Data([0xFF, 0xD8])) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        func send(_ request: HomeswiftNetwork.HTTPRequest, tls: HTTPClient.TLS) async throws -> HomeswiftNetwork.HTTPResponse {
            seen.append(request)
            var headers: [(name: String, value: String)] = [("WWW-Authenticate", "Digest realm=\"cam\"")]
            if let contentType { headers.append(("Content-Type", contentType)) }
            return HomeswiftNetwork.HTTPResponse(status: status, headers: headers, body: body)
        }
    }

    @Test func fetchesSnapshots() async throws {
        let server = SnapshotServer()
        let result = try await AddressValidation.fetchSnapshot("http://admin:p%40ss@cam.local/snap.jpg", expectedHost: "cam.local", resolve: { _ in ["192.168.1.50"] }, transport: server)
        #expect(result.contentType == "image/jpeg" && result.data == Data([0xFF, 0xD8]))
        let request = try #require(server.seen.first)
        #expect(request.url.absoluteString == "http://192.168.1.50/snap.jpg")
        #expect(request.header("Authorization") == "Basic " + Data("admin:p@ss".utf8).base64EncodedString())
        // Credentials only go to the host the user named.
        let other = SnapshotServer()
        _ = try await AddressValidation.fetchSnapshot("http://admin:pw@other.local/snap.jpg", expectedHost: "cam.local", resolve: { _ in ["192.168.1.51"] }, transport: other)
        #expect(other.seen.first?.header("Authorization") == nil)
        await #expect(throws: AddressValidation.Failure.notPermitted("localhost")) {
            try await AddressValidation.fetchSnapshot("http://localhost/snap.jpg", expectedHost: nil, resolve: { _ in ["127.0.0.1"] }, transport: server)
        }
        await #expect(throws: AddressValidation.SnapshotError.self) { try await AddressValidation.fetchSnapshot(nil, expectedHost: nil) }
        await #expect(throws: AddressValidation.SnapshotError.self) {
            try await AddressValidation.fetchSnapshot("http://cam.local/", expectedHost: nil, resolve: { _ in ["192.168.1.50"] }, transport: SnapshotServer(contentType: "text/html"))
        }
        do {
            _ = try await AddressValidation.fetchSnapshot("http://cam.local/", expectedHost: nil, resolve: { _ in ["192.168.1.50"] }, transport: SnapshotServer(status: 401))
            Issue.record("a 401 must fail")
        } catch {
            #expect("\(error)" == "HTTP 401 (Digest realm=\"cam\")")
        }
        await #expect(throws: AddressValidation.SnapshotError.self) {
            try await AddressValidation.fetchSnapshot("ftp://cam.local/", expectedHost: nil, resolve: { _ in ["192.168.1.50"] }, transport: server)
        }
    }

    @Test func checksControllerStatus() async {
        #expect(await AddressValidation.checkStatus("192.168.1.1", transport: SnapshotServer()))
        #expect(await !AddressValidation.checkStatus("127.0.0.1", transport: SnapshotServer()))
    }

    @Test func onvifHostMatching() {
        #expect(ONVIF.injectCredentials("rtsp://192.168.1.50:554/stream1", username: "admin", password: "p@ss", host: "192.168.1.50").url == "rtsp://admin:p%40ss@192.168.1.50:554/stream1")
        #expect(ONVIF.urlMatchesHost("http://CAM.local:8080/x", host: "cam.local"))
        let foreign = ONVIF.injectCredentials("rtsp://other:pw@10.0.0.9/stream", username: "admin", password: "p", host: "192.168.1.50")
        #expect(foreign.url == "rtsp://10.0.0.9/stream" && foreign.credentialsWithheld)
        #expect(ONVIF.injectCredentials(nil, username: "a", password: "b", host: "h").url == nil)
        #expect(ONVIF.injectCredentials("not a url", username: "a", password: "b", host: "h").url == "not a url")
        #expect(ONVIF.resolveMediaServiceURL("http://192.168.1.50/onvif/media", host: "192.168.1.50", port: 80) == ("http://192.168.1.50/onvif/media", false))
        let rewritten = ONVIF.resolveMediaServiceURL("http://10.0.0.9:8899/onvif/Media", host: "192.168.1.50", port: 2020)
        #expect(rewritten.url == "http://192.168.1.50:2020/onvif/Media" && rewritten.rewritten)
        #expect(ONVIF.stripNamespaces("<tt:Uri>rtsp://x</tt:Uri>") == "<Uri>rtsp://x</Uri>")
        #expect(ONVIF.extractTag("<Uri a=\"b\"> rtsp://x </Uri>", "Uri") == "rtsp://x")
        let header = ONVIF.securityHeader(username: "admin", password: "pw", nonce: [UInt8](repeating: 1, count: 16), created: Date(timeIntervalSince1970: 0))
        #expect(header.contains("<wsse:Username>admin</wsse:Username>") && header.contains("<wsu:Created>1970-01-01T00:00:00.000Z</wsu:Created>"))
    }

    final class FakeCamera: ProtectHTTPTransport, @unchecked Sendable {
        func send(_ request: HomeswiftNetwork.HTTPRequest, tls: HTTPClient.TLS) async throws -> HomeswiftNetwork.HTTPResponse {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            if request.url.port == 80 { throw HTTPClientError.cannotConnect(host: "cam", port: 80, code: ECONNREFUSED, reason: "refused") }
            let reply: String
            if body.contains("GetCapabilities") {
                reply = "<s:Envelope><s:Body><tds:Capabilities><tt:Media><tt:XAddr>http://10.0.0.9:8000/onvif/Media</tt:XAddr></tt:Media></tds:Capabilities></s:Body></s:Envelope>"
            } else if body.contains("GetProfiles") {
                reply = "<trt:Profiles token=\"main\"><tt:Name>MainStream</tt:Name><tt:VideoEncoderConfiguration><tt:Encoding>H264</tt:Encoding><tt:Resolution><tt:Width>2560</tt:Width><tt:Height>1440</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration></trt:Profiles>"
                    + "<trt:Profiles token=\"sub\"><tt:Name>SubStream</tt:Name></trt:Profiles>"
            } else if body.contains("GetStreamUri") {
                reply = "<tt:Uri>rtsp://192.168.1.50:554/\(body.contains(">main<") ? "stream1" : "stream2")</tt:Uri>"
            } else {
                reply = "<tt:Uri>http://192.168.1.50/snapshot.jpg</tt:Uri>"
            }
            return HomeswiftNetwork.HTTPResponse(status: 200, body: Data(reply.utf8))
        }
    }

    @Test func discoversONVIFProfiles() async throws {
        let result = try await ONVIF.discover(host: "192.168.1.50", port: nil, servicePath: nil, username: "admin", password: "pw", transport: FakeCamera())
        #expect(result.port == 8000 && result.servicePath == "/onvif/device_service")
        #expect(result.attempts.map(\.port) == [80])
        #expect(result.profiles.map(\.name) == ["MainStream", "SubStream"])
        #expect(result.profiles[0].rtspUrl == "rtsp://admin:pw@192.168.1.50:554/stream1" && result.profiles[0].width == 2560)
        #expect(result.profiles[1].snapshotUrl == "http://admin:pw@192.168.1.50/snapshot.jpg")
        #expect(result.warnings.first?.contains("different host") == true)
        await #expect(throws: ONVIF.Failure.self) { try await ONVIF.discover(host: "", port: nil, servicePath: nil, username: "admin", password: "", transport: FakeCamera()) }
    }

    @Test func discoveryAnswers() {
        var message: [UInt8] = [1, 0, 0, 0]
        message += [0x02, 0, 10, 0x74, 0xAC, 0xB9, 0x01, 0x02, 0x03, 192, 168, 1, 1]
        message += [0x0B, 0, 4] + Array("unvr".utf8)
        message += [0x0C, 0, 4] + Array("UNVR".utf8)
        message += [0x03, 0, 5] + Array("4.2.1".utf8)
        let console = UbiquitiDiscovery.parse(message)
        #expect(console == .init(firmware: "4.2.1", ip: "192.168.1.1", mac: "74:ac:b9:01:02:03", model: "UNVR", modelLong: "", name: "unvr"))
        #expect(UbiquitiDiscovery.parse([1, 0]) == nil)
        let network = { (address: String) in IPv4Network(address: IPv4Network.parse(address)!, netmask: 0xFFFF_FF00) }
        let targets = UbiquitiDiscovery.targets(networks: [network("192.168.10.20")])
        #expect(targets.prefix(2) == ["255.255.255.255", "192.168.10.255"])
        #expect(targets.contains("192.168.15.254") && targets.contains("192.168.5.1") && !targets.contains("192.168.10.5") && !targets.contains("192.168.16.1"))
        #expect(targets.count == 2 + 10 * 254)
        // Subnets below 0 do not exist.
        #expect(UbiquitiDiscovery.targets(networks: [network("10.0.1.2")]).count == 2 + 6 * 254)
    }

    @Test func mqttRedaction() {
        #expect(ProtectMQTTClient.redact("mqtt://user:pass@1.2.3.4") == "mqtt://REDACTED@1.2.3.4")
        #expect(ProtectMQTTClient.redact("user:p@ss@host") == "user:REDACTED@host")
        #expect(ProtectMQTTClient.redact("host-only@broker") == "REDACTED@broker")
        #expect(ProtectMQTTClient.redact("mqtt://1.2.3.4") == "mqtt://1.2.3.4")
        #expect(throws: ProtectMQTTURLError.unsupportedProtocol("http:")) { try MQTTBrokerURL.validate("http://broker") }
        #expect(throws: ProtectMQTTURLError.missingProtocol) { try MQTTBrokerURL.validate("broker") }
    }

    @Test func doorbellDurations() {
        #expect(DoorbellLcdMessages.mqttDuration(30, default: 60000) == 30000)
        #expect(DoorbellLcdMessages.mqttDuration(nil, default: 45000) == 45000)
        #expect(DoorbellLcdMessages.mqttDuration(-5, default: 60000) == 60000)
        #expect(DoorbellLcdMessages.mqttDuration(0, default: 60000) == 0)
        #expect(DoorbellLcdMessages.mqttDuration(1.5, default: 60000) == 1500)
        #expect(DoorbellChimes.clampDigitalDuration(500) == 1000)
        #expect(DoorbellChimes.clampDigitalDuration(2500) == 2500)
        #expect(DoorbellChimes.clampDigitalDuration(20000) == 10000)
        #expect(DoorbellChimes.clampDigitalDuration(nil) == 1000)
    }

    @Test func settings() {
        #expect(ProtectSettings.snapshotTimeout < 5000)
        #expect(ProtectSettings.hksvTimeshiftBufferMaxDuration == ProtectSettings.livestreamAPIIDRInterval * 1000 * 2)
        #expect(ProtectSettings.ffmpegProbesize < ProtectSettings.ffmpegProbesizePackage && ProtectSettings.ffmpegProbesizePackage < ProtectSettings.ffmpegProbesizeMax)
        #expect(ProtectSettings.segmentQueueMaxLength == 300)
        #expect(UniFiProtectPlugin.platform == "UniFi Protect")
        #expect(ProtectReservedNames.all.count == Set(ProtectReservedNames.all).count)
    }
}
