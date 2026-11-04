import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftGoogleNestSDM

@Suite(.timeLimit(.minutes(1)))
struct GoogleNestSDMTests {
    let environment = TestEnvironment()
    let thermostatID = GoogleNestSDMPlugin.accessoryID(deviceID: thermostatName)
    let fanID = GoogleNestSDMPlugin.accessoryID(deviceID: thermostatName + " Fan")

    func thermostat(_ host: PluginHost) throws -> Service {
        try #require(host.mainBridge.server.accessories.first { $0.id == thermostatID }?.service(.thermostat))
    }

    // MARK: Configuration

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(GoogleNestSDMPlugin.Configuration.self, from: Data(#"{"platform":"homebridge-google-nest-sdm"}"#.utf8))
        #expect(configuration.projectId == nil)
        #expect(NestOptions(configuration, debug: false).fanDuration == 900)
    }

    @Test func optionsWrittenAsStringsAreRead() throws {
        let json = #"{"showFan":"true","fanDuration":"600","analyzeDuration":"<optional>","vEncoder":"copy"}"#
        let configuration = try JSONDecoder().decode(GoogleNestSDMPlugin.Configuration.self, from: Data(json.utf8))
        let options = NestOptions(configuration, debug: false)
        #expect(options.showFan)
        #expect(options.fanDuration == 600)
        #expect(options.analyzeDuration == 15_000_000)
        #expect(options.copiesVideo)
        #expect(NestOptions(try JSONDecoder().decode(GoogleNestSDMPlugin.Configuration.self, from: Data(#"{"fanDuration":50000}"#.utf8)), debug: false).fanDuration == nil)
    }

    @Test func anIncompleteBlockNamesWhatIsMissingAndAddsNothing() async throws {
        let host = try await environment.start(settings: ["projectId": "PROJECT-UUID"])
        let check1 = await environment.plugin?.account()
        let account = try #require(check1)
        guard case .failure(.notConfigured(let missing)) = account else { Issue.record("expected missing keys"); return }
        #expect(missing == ["clientId", "clientSecret", "refreshToken", "subscriptionId"])
        #expect(environment.google.requests.isEmpty)
        await host.stop()
    }

    // MARK: Accessories

    @Test func eachDeviceBecomesItsAccessory() async throws {
        let host = try await environment.loaded()
        let thermostatAccessory = try #require(host.mainBridge.server.accessories.first { $0.id == thermostatID })
        #expect(thermostatAccessory.information.characteristic(.name).value == "Hallway Thermostat")
        #expect(thermostatAccessory.information.characteristic(.manufacturer).value == "Google Nest")
        #expect(thermostatAccessory.information.characteristic(.serialNumber).value == "THERMOSTAT-ID")
        #expect(thermostatAccessory.category == .thermostat)
        let fan = try #require(host.mainBridge.server.accessories.first { $0.id == fanID })
        #expect(fan.information.characteristic(.name).value == "Hallway Thermostat Fan")
        #expect(fan.service(.fan)?[.on]?.value == false)

        let check2 = await environment.plugin?.cameras
        let cameras = try #require(check2)
        #expect(cameras.count == 3)
        let camera = try #require(cameras[cameraName])
        #expect(camera.accessory.name == "Garage Camera")
        #expect(camera.accessory.category == .ipCamera)
        #expect(camera.controller.streamManagementServices.count == 11)
        #expect(camera.recorder != nil)
        #expect(camera.accessory.service(.motionSensor) != nil)
        let doorbell = try #require(cameras[doorbellName])
        #expect(doorbell.accessory.name == "Front Door Doorbell")
        #expect(doorbell.accessory.category == .videoDoorbell)
        #expect(doorbell.accessory.service(.doorbell) != nil)
        #expect(doorbell.recorder == nil)
        #expect(cameras[displayName]?.controller.streamManagementServices.count == 3)
        #expect(cameras[displayName]?.accessory.name == "Kitchen Display")
        await host.stop()
    }

    @Test func theThermostatShowsItsTraits() async throws {
        let host = try await environment.loaded()
        let service = try thermostat(host)
        #expect(service[.targetTemperature]?.type.minValue == 10)
        #expect(service[.targetTemperature]?.type.maxValue == 32.2)
        #expect(service[.currentTemperature]?.type.minValue == -17.8)
        #expect(service[.currentTemperature]?.type.maxValue == 71.1)
        #expect(service[.targetHeatingCoolingState]?.type.validValues == [1, 2, 3, 0])
        #expect(service[.targetHeatingCoolingState]?.value.intValue == 1)
        #expect(service[.currentHeatingCoolingState]?.value.intValue == 1)
        #expect(service[.targetTemperature]?.value.doubleValue == 20.5)
        #expect(service[.heatingThresholdTemperature]?.value.doubleValue == 20.5)
        #expect(service[.coolingThresholdTemperature]?.value.doubleValue == 20.0)
        #expect(service[.temperatureDisplayUnits]?.value.intValue == 1)
        #expect(service[.currentRelativeHumidity]?.value.doubleValue == 42)
        #expect(service[.currentTemperature]?.value.doubleValue == 19.8)
        #expect(service[NestThermostat.ecoType]?.value == false)
        await host.stop()
    }

    // MARK: Writes

    @Test func writesSendTheirCommands() async throws {
        let host = try await environment.loaded()
        let service = try thermostat(host)
        try await service[.targetTemperature]?.write(.double(21))
        let check3 = await eventually { environment.google.command("ThermostatTemperatureSetpoint.SetHeat").last
            == ["command": "sdm.devices.commands.ThermostatTemperatureSetpoint.SetHeat", "params": ["heatCelsius": 21]] }
        #expect(check3)
        try await service[.targetHeatingCoolingState]?.write(.int(3))
        #expect(environment.google.command("ThermostatMode.SetMode").last == ["command": "sdm.devices.commands.ThermostatMode.SetMode", "params": ["mode": "HEATCOOL"]])
        try await service[NestThermostat.ecoType]?.write(.bool(true))
        #expect(environment.google.command("ThermostatEco.SetMode").last == ["command": "sdm.devices.commands.ThermostatEco.SetMode", "params": ["mode": "MANUAL_ECO"]])

        let fan = try #require(host.mainBridge.server.accessories.first { $0.id == fanID }?.service(.fan)?[.on])
        try await fan.write(.bool(true))
        #expect(environment.google.command("Fan.SetTimer").last == ["command": "sdm.devices.commands.Fan.SetTimer", "params": ["timerMode": "ON", "duration": "900s"]])
        try await fan.write(.bool(false))
        #expect(environment.google.command("Fan.SetTimer").last == ["command": "sdm.devices.commands.Fan.SetTimer", "params": ["timerMode": "OFF"]])
        await host.stop()
    }

    @Test func aThresholdWriteInAutoSendsTheRange() async throws {
        environment.google.state.withLockedValue { state in
            var devices = state.devices["devices"]!.arrayValue!
            var traits = devices[0]["traits"]!.objectValue!
            traits["sdm.devices.traits.ThermostatMode"] = ["mode": "HEATCOOL", "availableModes": ["HEAT", "COOL", "HEATCOOL", "OFF"]]
            traits["sdm.devices.traits.ThermostatTemperatureSetpoint"] = ["heatCelsius": 18, "coolCelsius": 24]
            var device = devices[0].objectValue!
            device["traits"] = .object(traits)
            devices[0] = .object(device)
            state.devices = ["devices": .array(devices)]
        }
        let host = try await environment.loaded()
        let service = try thermostat(host)
        try await service[.heatingThresholdTemperature]?.write(.double(19))
        #expect(environment.google.command("ThermostatTemperatureSetpoint.SetRange").last
            == ["command": "sdm.devices.commands.ThermostatTemperatureSetpoint.SetRange", "params": ["heatCelsius": 19, "coolCelsius": 24]])
        // Both handles of the slider at once: one command with both.
        let heating = try #require(service[.heatingThresholdTemperature]), cooling = try #require(service[.coolingThresholdTemperature])
        async let heat: Void = heating.write(.double(18.5))
        async let cool: Void = cooling.write(.double(25))
        _ = try await (heat, cool)
        let ranges = environment.google.command("ThermostatTemperatureSetpoint.SetRange")
        #expect(ranges.count == 2)
        #expect(ranges.last?["params"] == ["heatCelsius": 18.5, "coolCelsius": 25])
        // The target temperature belongs to heat and cool.
        await #expect(throws: HAPStatusError.self) { try await service[.targetTemperature]?.write(.double(20)) }
        await host.stop()
    }

    @Test func aFailedCommandIsNoResponse() async throws {
        environment.google.state.withLockedValue { $0.failures["ThermostatTemperatureSetpoint.SetHeat"] = (400, "The device is offline.") }
        let host = try await environment.loaded()
        let service = try thermostat(host)
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure, reason: "HTTP 400: The device is offline.")) {
            try await service[.targetTemperature]?.write(.double(22))
        }
        await host.stop()
    }

    // MARK: Events

    @Test func traitEventsReachHomeKit() async throws {
        let host = try await environment.loaded()
        let service = try thermostat(host)
        let resource = #""name":"enterprises/PROJECT-UUID/devices/THERMOSTAT-ID""#
        environment.google.publish(#"{"eventId":"E1","timestamp":"2026-01-01T12:00:01Z","resourceUpdate":{\#(resource),"traits":{"sdm.devices.traits.ThermostatMode":{"mode":"COOL","availableModes":["HEAT","COOL","HEATCOOL","OFF"]}}}}"#)
        let check4 = await eventually { service[.targetHeatingCoolingState]?.value.intValue == 2 }
        #expect(check4)
        environment.google.publish(#"{"eventId":"E2","timestamp":"2026-01-01T12:00:02Z","resourceUpdate":{\#(resource),"traits":{"sdm.devices.traits.ThermostatTemperatureSetpoint":{"coolCelsius":24.5}}}}"#)
        let check5 = await eventually { service[.targetTemperature]?.value.doubleValue == 24.5 }
        #expect(check5)
        for traits in [
            #"{"sdm.devices.traits.Temperature":{"ambientTemperatureCelsius":21.3}}"#, #"{"sdm.devices.traits.Humidity":{"ambientHumidityPercent":47}}"#,
            #"{"sdm.devices.traits.ThermostatHvac":{"status":"COOLING"}}"#, #"{"sdm.devices.traits.Fan":{"timerMode":"ON","timerTimeout":"2026-01-01T12:15:00Z"}}"#,
            #"{"sdm.devices.traits.Settings":{"temperatureScale":"CELSIUS"}}"#,
        ] {
            environment.google.publish(#"{"eventId":"E","resourceUpdate":{\#(resource),"traits":\#(traits)}}"#)
        }
        // Celsius gives other ranges: the accessory is built again under its id.
        let check6 = await eventually { (try? thermostat(host))?[.targetTemperature]?.type.minValue == 9 }
        #expect(check6)
        let current = try thermostat(host)
        #expect(current[.temperatureDisplayUnits]?.value.intValue == 0)
        #expect(current[.currentTemperature]?.value.doubleValue == 21.3)
        #expect(current[.currentRelativeHumidity]?.value.doubleValue == 47)
        #expect(current[.currentHeatingCoolingState]?.value.intValue == 2)
        #expect(host.mainBridge.server.accessories.first { $0.id == fanID }?.service(.fan)?[.on]?.value == true)

        environment.google.publish(#"{"eventId":"E3","resourceUpdate":{\#(resource),"traits":{"sdm.devices.traits.ThermostatEco":{"availableModes":["OFF","MANUAL_ECO"],"mode":"MANUAL_ECO","heatCelsius":9.7,"coolCelsius":29.4}}}}"#)
        let check7 = await eventually { (try? thermostat(host))?[.targetTemperature]?.type.minValue == 4.5 }
        #expect(check7)
        let eco = try thermostat(host)
        #expect(eco[.heatingThresholdTemperature]?.value.doubleValue == 9.7)
        #expect(eco[.coolingThresholdTemperature]?.value.doubleValue == 29.4)
        #expect(eco[.targetHeatingCoolingState]?.value.intValue == 0)
        #expect(eco[NestThermostat.ecoType]?.value == true)
        await host.stop()
    }

    @Test func motionFetchesTheImageAndClearsAfterTheWindow() async throws {
        environment.google.state.withLockedValue {
            $0.results["CameraEventImage.GenerateImage"] = ["url": "https://domain/sdm_event_snapshot/abc", "token": "IMAGE-TOKEN"]
        }
        let host = try await environment.loaded()
        let check8 = await environment.plugin?.cameras[cameraName]
        let camera = try #require(check8)
        let motion = try #require(camera.motion[.motionDetected])
        environment.google.publish(freshEvent(#"{"eventId":"E10","timestamp":"<now>","resourceUpdate":{"name":"enterprises/PROJECT-UUID/devices/CAMERA-RTSP-ID","events":{"sdm.devices.events.CameraMotion.Motion":{"eventSessionId":"SESSION-1","eventId":"EVENT-ID-INNER"}}}}"#))
        let check9 = await eventually { motion.value == true }
        #expect(check9)
        #expect(environment.google.command("CameraEventImage.GenerateImage").last?["params"] == ["eventId": "EVENT-ID-INNER"])
        let image = try #require(environment.google.requests.first { $0.url.absoluteString.contains("sdm_event_snapshot") })
        #expect(image.header("Authorization") == "Basic IMAGE-TOKEN")
        let check10 = await camera.snapshot() == Data("EVENT-JPEG".utf8)
        #expect(check10)
        // 20 seconds at the tests' time scale.
        let check11 = await eventually { motion.value == false }
        #expect(check11)
        await host.stop()
    }

    @Test func aChimeRingsAWebRTCDoorbellWithoutAnImage() async throws {
        let host = try await environment.loaded()
        let check12 = await environment.plugin?.cameras[doorbellName]
        let doorbell = try #require(check12)
        let rings = NIOLockedBox()
        _ = doorbell.accessory.service(.doorbell)?.characteristic(.programmableSwitchEvent).observe { _ in rings.increment() }
        let chime = #"{"eventId":"E11","timestamp":"<now>","resourceUpdate":{"name":"enterprises/PROJECT-UUID/devices/DOORBELL-WEBRTC-ID","events":{"sdm.devices.events.DoorbellChime.Chime":{"eventSessionId":"SESSION-2","eventId":"EVENT-ID-2"}}},"eventThreadState":"STATE"}"#
        // Updates and ends of a thread, and old events, do nothing.
        environment.google.publish(freshEvent(chime.replacingOccurrences(of: "STATE", with: "UPDATED")))
        environment.google.publish(chime.replacingOccurrences(of: "STATE", with: "STARTED").replacingOccurrences(of: "<now>", with: "2026-01-01T12:00:00Z"))
        environment.google.publish("not JSON")
        environment.google.publish(#"{"eventId":"E20","relationUpdate":{"type":"CREATED","subject":"s","object":"o"}}"#)
        environment.google.publish(freshEvent(chime.replacingOccurrences(of: "STATE", with: "STARTED")))
        let check13 = await eventually { rings.value == 1 }
        #expect(check13)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rings.value == 1)
        #expect(environment.google.command("CameraEventImage.GenerateImage").isEmpty)
        let check14 = await doorbell.snapshot() == Placeholder.jpeg
        #expect(check14)
        await host.stop()
    }

    @Test func messagesAreAcknowledged() async throws {
        let host = try await environment.loaded()
        environment.google.publish("not JSON")
        let check15 = await eventually {
            environment.google.requests.contains { $0.url.absoluteString.hasSuffix(":acknowledge") && String(decoding: $0.body ?? Data(), as: UTF8.self).contains("ACK-1") }
        }
        #expect(check15)
        let pull = try #require(environment.google.requests.first { $0.url.absoluteString.hasSuffix(":pull") })
        #expect(pull.url.absoluteString == "https://pubsub.googleapis.com/v1/projects/gcp/subscriptions/nest:pull")
        #expect(pull.header("Authorization") == "Bearer ACCESS-TOKEN")
        await host.stop()
    }

    @Test func aRateLimitedListIsTriedAgain() async throws {
        environment.google.state.withLockedValue { $0.listFailures = 2 }
        let host = try await environment.loaded()
        let check16 = await environment.plugin?.thermostats.count == 1
        #expect(check16)
        await host.stop()
    }

    // MARK: Streams

    @Test func anRTSPStreamIsExtendedAndStopped() async throws {
        let sent = NIOLockedValueBox<[String]>([])
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        let send: Commander = { _, command, params in
            sent.withLockedValue { $0.append(command + " " + (params["streamExtensionToken"]?.stringValue ?? "")) }
            switch command {
            case "CameraLiveStream.GenerateRtspStream":
                return ["streamUrls": ["rtspUrl": "rtsps://stream.example/v1/x?auth=STREAM-TOKEN"], "streamExtensionToken": "EXT-1", "streamToken": "STREAM-TOKEN",
                        "expiresAt": .string(expires)]
            case "CameraLiveStream.ExtendRtspStream":
                return ["streamExtensionToken": "EXT-2", "streamToken": "STREAM-2", "expiresAt": "2999-01-01T00:00:00Z"]
            default:
                return [:]
            }
        }
        let stream = try await RTSPStream.open(device: cameraName, send: send, log: testLogger, lead: .seconds(1))
        #expect(stream.url == "rtsps://stream.example/v1/x?auth=STREAM-TOKEN")
        let check17 = await eventually { sent.withLockedValue { $0 }.contains("CameraLiveStream.ExtendRtspStream EXT-1") }
        #expect(check17)
        await stream.stop()
        #expect(sent.withLockedValue { $0 }.last == "CameraLiveStream.StopRtspStream EXT-2")
    }

    @Test func liveArgumentsFollowTheSpecification() throws {
        let request = StartStreamRequest(
            sessionID: "s",
            video: VideoInfo(codec: 0, profile: 1, level: 0, packetizationMode: 0, cvoId: nil, width: 1280, height: 720, fps: 30, pt: 99, ssrc: 1,
                             maxBitRate: 299, rtcpInterval: 0.5, mtu: 1378),
            audio: AudioInfo(codec: .aacELD, channel: 1, bitRate: .variable, sampleRate: 16, packetTime: 30, pt: 110, ssrc: 2, maxBitRate: 24,
                             rtcpInterval: 0.5, comfortPT: 13, comfortNoiseEnabled: false))
        let target = FFmpegArguments.Target(address: "10.0.0.2", videoPort: 5000, videoSRTP: Data(repeating: 1, count: 30), videoSSRC: 11,
                                            audioPort: 5002, audioSRTP: Data(repeating: 2, count: 30), audioSSRC: 22)
        let options = NestOptions(try JSONDecoder().decode(GoogleNestSDMPlugin.Configuration.self, from: Data("{}".utf8)), debug: false)
        let arguments = FFmpegArguments.live(input: FFmpegArguments.input(rtspURL: "rtsps://x", options: options), request: request, target: target,
                                             options: options, audioEncoder: ["-codec:a", "libfdk_aac", "-profile:a", "aac_eld"])
        let videoKey = Data(repeating: 1, count: 30).base64EncodedString(), audioKey = Data(repeating: 2, count: 30).base64EncodedString()
        #expect(arguments.joined(separator: " ") == [
            "-analyzeduration 15000000 -probesize 100000000 -i rtsps://x",
            "-an -sn -dn -codec:v libx264 -preset ultrafast -tune zerolatency -f rawvideo -pix_fmt yuv420p -color_range mpeg",
            "-bf 0 -r 30 -b:v 1196k -bufsize 1196k -maxrate 2392k -filter:v scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-payload_type 99 -ssrc 11 -f rtp -srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params \(videoKey) srtp://10.0.0.2:5000?rtcpport=5000&pkt_size=1378",
            "-vn -sn -dn -codec:a libfdk_aac -profile:a aac_eld -flags +global_header -ar 16k -b:a 24k -ac 1 -payload_type 110 -ssrc 22 -f rtp",
            "-srtp_out_suite AES_CM_128_HMAC_SHA1_80 -srtp_out_params \(audioKey) srtp://10.0.0.2:5002?rtcpport=5002&pkt_size=188",
        ].joined(separator: " "))
        #expect(FFmpegArguments.filter(width: 0, height: 0) == nil)
    }

    @Test func recordingsKeepTheirAudio() throws {
        let configuration = CameraRecordingConfiguration(
            prebufferLength: 4000, eventTriggerTypes: [.motion], mediaContainerConfiguration: MediaContainerConfiguration(fragmentLength: 4000),
            videoCodec: .init(type: .h264, parameters: .init(profile: .high, level: .level4_0, bitRate: 2000, iFrameInterval: 4000), resolution: VideoResolution(1920, 1080, 30)),
            audioCodec: .init(audioChannels: 1, type: .aacLC, samplerate: .khz48, bitrateMode: .variable, bitrate: 64))
        let arguments = try FFmpegArguments.recording(input: ["-i", "rtsps://x"], configuration: configuration, audioEncoder: ["-codec:a", "aac", "-profile:a", "aac_low"])
        #expect(arguments.joined(separator: " ") == "-i rtsps://x -codec:a aac -profile:a aac_low -ar 48k -b:a 64k -ac 1 -sn -dn -codec:v libx264 -pix_fmt yuv420p "
            + "-profile:v high -level:v 4.0 -b:v 2000k -force_key_frames expr:eq(t,n_forced*4) -r 30 -fflags +genpts -reset_timestamps 1 "
            + "-movflags frag_keyframe+empty_moov+default_base_moof -f mp4 pipe:1")
        #expect(!arguments.contains("-an"))
    }

    // MARK: Setup and settings

    @Test func setupSharesTheHomesAndKeepsTheToken() async throws {
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        let check18 = await plugin.accountAuthorized() == false
        #expect(check18)
        guard case .ask(let first, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected a prompt"); return }
        #expect(first.fields.map(\.key) == ["projectId", "clientId", "clientSecret", "subscriptionId", "gcpProjectId"])
        let answers = ["projectId": "PROJECT-UUID", "clientId": "CLIENT", "clientSecret": "SECRET", "subscriptionId": "projects/gcp/subscriptions/nest"]
        guard case .ask(let consent, let state) = try await plugin.authorize(SetupRequest(target: .account, answers: answers)) else {
            Issue.record("expected the consent page"); return
        }
        #expect(consent.url == "https://nestservices.google.com/partnerconnections/PROJECT-UUID/auth?redirect_uri=https://www.google.com&access_type=offline"
            + "&prompt=consent&client_id=CLIENT&response_type=code&scope=https://www.googleapis.com/auth/sdm.service+https://www.googleapis.com/auth/pubsub")
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(
            target: .account, answers: ["callbackUrl": "https://www.google.com?code=4/CODE&scope=x"], state: state)) else { Issue.record("expected done"); return }
        #expect(outcome.credentials == ["clientSecret": "SECRET"])
        #expect(outcome.settings["projectId"] == "PROJECT-UUID")
        #expect(outcome.settings["refreshToken"] == .null)
        let check19 = await plugin.tokens.load()?.refreshToken == "NEW-REFRESH"
        #expect(check19)
        let exchange = try #require(environment.google.requests.first { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("authorization_code") })
        #expect(URLEncoding.fields(String(decoding: exchange.body ?? Data(), as: UTF8.self))["code"] == "4/CODE")
        await host.stop()
    }

    @Test func pastedCodesAreRead() {
        #expect(GoogleOAuth.code(fromPasted: "https://www.google.com?code=4/0Ab%2Fx&scope=a") == "4/0Ab/x")
        #expect(GoogleOAuth.code(fromPasted: " 4/0Abc ") == "4/0Abc")
        #expect(GoogleOAuth.code(fromPasted: "https://www.google.com/") == nil)
    }

    @Test func canonicalSettingsMovesTheSecretsOut() async throws {
        let host = try await environment.loaded()
        let plugin = try #require(environment.plugin)
        let block = try JSONValue(string: #"{"platform":"homebridge-google-nest-sdm","projectId":"PROJECT-UUID","clientSecret":"CLIENT-SECRET","refreshToken":"REFRESH-TOKEN"}"#)
        let canonical = await plugin.canonicalSettings(block)
        #expect(canonical["clientSecret"] == nil)
        #expect(canonical["refreshToken"] == nil)
        #expect(canonical["projectId"] == "PROJECT-UUID")
        await host.stop()
    }

    @Test func googleErrorsReadTheirStatus() {
        let limited = HomeswiftNetwork.HTTPResponse(status: 429, body: Data(#"{"error":{"code":429,"message":"Rate limited.","status":"RESOURCE_EXHAUSTED"}}"#.utf8))
        #expect(NestError.from(limited) == .rateLimited("Rate limited."))
        let revoked = HomeswiftNetwork.HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8))
        #expect(NestError.from(revoked) == .unauthorized("invalid_grant"))
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(GoogleNestSDMPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/GoogleNestSDM GoogleNestSDMPlugin")
    }

    @Test func thePlaceholderIsAJPEG() {
        #expect(Placeholder.jpeg.prefix(2) == Data([0xFF, 0xD8]))
    }
}

/// A counter tests share with handlers.
final class NIOLockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
