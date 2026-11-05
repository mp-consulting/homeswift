import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftRenault

/// The specification's vectors (docs/clean-room/Renault.md, 8) and the per-model table.
@Suite(.timeLimit(.minutes(1)))
struct RenaultProtocolTests {
    @Test func localesResolve() throws {
        let portugal = try #require(RenaultLocale.servers(for: "pt_PT"))
        #expect(portugal.gigyaRoot == "https://accounts.eu1.gigya.com")
        #expect(portugal.gigyaKey == "3_VgdkgtIRH3AdHvJm-cjV2ug2EFE0lxt0IJzMC4MFqZjFpn_GYFXVdNZ19L7wZX0N")
        #expect(portugal.kamereonRoot == "https://api-wired-prod-1-euw1.wrd-aws.com")
        #expect(portugal.kamereonKey == "YjkKtHmGfaceeuExUDKGxrLZGGvtVS0J")
        #expect(portugal.country == "PT")
        #expect(portugal.language == "pt")
        let australia = try #require(RenaultLocale.servers(for: "en_AU"))
        #expect(australia.gigyaRoot == "https://gigya-prod-au1.renaultgroup.com")
        #expect(australia.gigyaKey == "4_GC9iGd3sH8sMJpz2x0q0CQ")
        #expect(australia.kamereonRoot == "https://api-wired-prod-1-apn1.wrd-aws.com")
        #expect(australia.country == "AU")
        #expect(RenaultLocale.servers(for: "es_MX")?.kamereonRoot == "https://api-wired-prod-1-usw2.wrd-aws.com")
        #expect(RenaultLocale.servers(for: "xx_XX") == nil)
        #expect(RenaultLocale.known.count == 30)
    }

    @Test func theSchemaOffersEveryKnownLocale() throws {
        let schema = try JSONValue(string: try #require(RenaultPlugin.configurationSchemaJSON))
        let offered = (schema["schema"]?["properties"]?["locale"]?["oneOf"]?.arrayValue ?? []).compactMap { $0["enum"]?[0]?.stringValue }
        #expect(Set(offered) == Set(RenaultLocale.known))
    }

    @Test func jwtExpiresAMinuteEarly() {
        let token = Fixtures.jwt(exp: 1767225600)
        #expect(JWT.expiry(of: token) == Date(timeIntervalSince1970: 1767225600))
        let issued = Date(timeIntervalSince1970: 1767225000)
        #expect(!JWT.isExpired(token, issued: issued, now: Date(timeIntervalSince1970: 1767225539)))
        #expect(JWT.isExpired(token, issued: issued, now: Date(timeIntervalSince1970: 1767225540)))
    }

    @Test func gigyaErrorsAreReadBeforeTheStatus() {
        func check(_ status: Int, _ body: String) -> RenaultError? {
            do { _ = try GigyaClient.check(HomeswiftNetwork.HTTPResponse(status: status, body: Data(body.utf8))); return nil } catch { return error as? RenaultError }
        }
        #expect(check(403, #"{"errorCode":403042,"errorDetails":"invalid loginID or password"}"#) == .invalidCredentials)
        #expect(check(403, #"{"errorCode":403101,"regToken":"RT-example"}"#) == .needsTwoFactor(regToken: "RT-example"))
        #expect(check(200, "<html>") == .gigya(code: -1, details: "HTTP 200, not JSON"))
        #expect(check(200, #"{"errorCode":0,"id_token":"x"}"#) == nil)
    }

    @Test func kamereonAnswersAreReadInOrder() throws {
        func check(_ status: Int, _ body: String) throws -> JSONValue { try Kamereon.check(HomeswiftNetwork.HTTPResponse(status: status, body: Data(body.utf8))) }
        // An HTML 502 is the HTTP error, not invalid JSON.
        #expect(throws: RenaultError.http(status: 502)) { try check(502, "<html>Bad gateway</html>") }
        #expect(throws: RenaultError.invalidJSON) { try check(200, "<html>") }
        // An array is wrapped under `data`.
        #expect(try check(200, "[1,2]")["data"]?.arrayValue?.count == 2)
        // `errors` wins over a 200.
        do {
            _ = try check(200, Fixtures.notSupported)
            Issue.record("no error")
        } catch RenaultError.kamereon(let error) {
            #expect(error.code == "err.tech.501")
            #expect(error.detail == "This feature is not technically supported by this gateway")
            #expect(error.alwaysDrops)
        }
        // 8.10: no attributes is every field absent.
        let empty = Kamereon.attributes(try check(200, #"{"data":{"type":"ChargeMode","id":"VF1TEST"}}"#), plain: false)
        #expect(BatteryStatus(attributes: empty).level == nil)
    }

    @Test func errorDetailsJoinTitlePointerAndDetail() {
        #expect(KamereonError.detail(of: #"{"errors":[{"status":"403","code":"403011","title":"Operation not supported","detail":"Operation not supported for this can (C1A)"}]}"#)
            == "Operation not supported Operation not supported for this can (C1A)")
        #expect(KamereonError.detail(of: #"{"errors":[{"source":{"pointer":"/data/attributes/startDateTime"},"detail":"must be a future date"}]}"#)
            == "/data/attributes/startDateTime must be a future date")
        #expect(KamereonError.detail(of: "You have reached your quota limit") == "You have reached your quota limit")
    }

    @Test func theRenault5Table() {
        func resolved(_ endpoint: Endpoint, _ model: String = "R5E1VE") -> Resolution { ModelEndpoints.resolve(endpoint, model: model, vin: Fixtures.vin).resolution }
        #expect(resolved(.batteryStatus) == .supported(path: "/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status", mode: .default))
        #expect(resolved(.socLevels) == .supported(path: "/kcm/v1/vehicles/\(Fixtures.vin)/ev/soc-levels", mode: .default))
        #expect(resolved(.hvacStop) == .supported(path: "/kca/car-adapter/v1/cars/\(Fixtures.vin)/actions/hvac-start", mode: .kcaStop))
        #expect(resolved(.chargeStart) == .supported(path: "/kcm/v1/vehicles/\(Fixtures.vin)/ev/settings", mode: .kcmSettings))
        #expect(resolved(.chargeSchedule) == .supported(path: "/kcm/v1/vehicles/\(Fixtures.vin)/ev/settings", mode: .kcmSettings))
        #expect(resolved(.hornStart) == .supported(path: "/kca/car-adapter/v1/cars/\(Fixtures.vin)/actions/horn-lights", mode: .default))
        for refused: Endpoint in [.chargeStop, .chargeSetMode, .chargeSetSchedule, .hvacSetSchedule, .chargeMode, .chargingSettings, .chargeHistory,
            .hvacHistory, .hvacSessions, .lockStatus, .pressure, .resState, .notificationSettings] {
            #expect(!resolved(refused).isSupported, "\(refused.rawValue) should be none on an R5")
        }
        // Documented keys warn nothing; an R4's unlisted climate stop takes the default ("cancel").
        #expect(ModelEndpoints.resolve(.cockpit, model: "R5E1VE", vin: Fixtures.vin).documented)
        #expect(resolved(.hvacStop, "A4E1VE") == .supported(path: "/kca/car-adapter/v1/cars/\(Fixtures.vin)/actions/hvac-start", mode: .default))
        #expect(!ModelEndpoints.resolve(.hvacStop, model: "A4E1VE", vin: Fixtures.vin).documented)
        // ZOE phase 2 stops through kcm pause-resume; an unknown model takes the defaults.
        #expect(resolved(.chargeStop, "X102VE") == .supported(path: "/kcm/v1/vehicles/\(Fixtures.vin)/charge/pause-resume", mode: .kcmPauseResume))
        #expect(resolved(.chargeStop, "NEW1VE") == .supported(path: "/kca/car-adapter/v1/cars/\(Fixtures.vin)/actions/charging-start", mode: .default))
        #expect(!ModelEndpoints.isKnown("NEW1VE"))
    }

    @Test func theRenault5sParts() {
        let r5 = VehicleInfo(vin: Fixtures.vin, registrationNumber: "AA-00-AA", brand: "RENAULT", modelCode: "R5E1VE", modelLabel: "RENAULT 5", energyCode: "ELECX")
        #expect(r5.usesElectricity)
        #expect(r5.displayName == "AA-00-AA")
        #expect(r5.modelName == "Renault 5")
        #expect(r5.manufacturer == "Renault")
        #expect(RenaultVehicle.parts(for: r5, dropped: []) == [.climate, .charging, .pluggedIn, .horn, .lights, .interiorTemperature, .exteriorTemperature, .batteryTemperature])
        #expect(!VehiclePart.horn.includedByDefault)
        #expect(RenaultVehicle.parts(for: r5, dropped: [.hvacStatus]) == [.charging, .pluggedIn, .horn, .lights, .batteryTemperature])
    }

    @Test func chargingStatusesAndThePlug() {
        let unplugged = BatteryStatus(attributes: try! JSONValue(string: Fixtures.battery)["data"]!["attributes"]!)
        #expect(unplugged.level == 73)
        #expect(unplugged.autonomy == 261)
        #expect(unplugged.isCharging == false)
        #expect(unplugged.isPluggedIn == false)
        let charging = BatteryStatus(attributes: try! JSONValue(string: #"{"batteryLevel":60,"plugStatus":1,"chargingStatus":1,"chargingInstantaneousPower":27.0}"#))
        #expect(charging.isCharging == true)
        #expect(charging.isPluggedIn == true)
        #expect(charging.powerKW == 27)
        #expect(BatteryStatus(attributes: try! JSONValue(string: #"{"chargingInstantaneousPower":2700}"#), reportsWatts: true).powerKW == 2.7)
        #expect(BatteryStatus(plugStatus: nil, chargingStatus: 0.3).isPluggedIn == true)
        #expect(BatteryStatus(plugStatus: nil, chargingStatus: 0.0).isPluggedIn == false)
        #expect(BatteryStatus(plugStatus: -2147483648, chargingStatus: 0.0).isPluggedIn == nil)
        #expect(BatteryStatus(chargingStatus: -1.6).isCharging == true)
        #expect(ChargingStatus.normalised(0.30000001) == 0.3)
        #expect(BatteryStatus(attributes: try! JSONValue(string: #"{"batteryLevel":1e300}"#)).level == 100)
    }

    @Test func lockStatusAliases() throws {
        let json = try JSONValue(string: #"{"data":{"id":"VF1TEST0000000002","attributes":{"lockStatus":"locked","statusDoorDriver":"closed","statusDoorPassenger":"closed","statusDoorRearLeft":"closed","statusDoorRearRight":"open","statusDoorTailGate":"closed","lastUpdateTime":"2026-10-20T18:32:24Z"}}}"#)
        let lock = LockStatus(attributes: Kamereon.attributes(json, plain: false))
        #expect(lock.locked == true)
        #expect(lock.openings["RearRight"] == true)
        #expect(lock.openings["Hatch"] == false)
    }

    @Test func pollIntervals() {
        func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
        let hour = Duration.seconds(3600)
        #expect(abs(seconds(RenaultPlugin.pollInterval(pollers: 5, hourly: 1, budget: 60, hour: hour)) - 305.08) < 0.01)
        #expect(abs(seconds(RenaultPlugin.pollInterval(pollers: 10, hourly: 1, budget: 60, hour: hour)) - 610.17) < 0.01)
        #expect(abs(seconds(RenaultPlugin.pollInterval(pollers: 6, hourly: 1, budget: 60, hour: hour)) - 366.10) < 0.01)
    }

    @Test func vinsAreMasked() {
        #expect(maskedVIN(Fixtures.vin) == "VF1…0001")
        #expect(maskingVINs(in: "There is no data for VF1TEST0000000001 here") == "There is no data for VF1…0001 here")
    }

    @Test func vinsBecomeExclusions() throws {
        let block = try JSONValue(string: #"{"platform":"Renault","vins":["VF1TEST0000000001"]}"#)
        let canonical = RenaultPlugin.canonical(block, knownVINs: [Fixtures.vin, "VF1TEST0000000002"])
        #expect(canonical["vins"] == nil)
        #expect(canonical["_accessories"]?["VF1TEST0000000002"]?["excluded"] == true)
        #expect(canonical["_accessories"]?[Fixtures.vin] == nil)
        #expect(RenaultPlugin.canonical(canonical, knownVINs: [Fixtures.vin]) == canonical)
        // A VIN the plugin does not know yet: left as it is.
        #expect(RenaultPlugin.canonical(try JSONValue(string: #"{"vins":["VF1OTHER000000009"]}"#), knownVINs: [Fixtures.vin])["vins"] != nil)
    }

    @Test func droppedEndpointsAreForgotten() {
        let info = VehicleInfo(vin: Fixtures.vin, modelCode: "R5E1VE")
        let now = Date()
        let all = [Fixtures.vin: RenaultPlugin.DroppedEndpoints(model: "R5E1VE", endpoints: ["cockpit": now.addingTimeInterval(-3600), "location": now.addingTimeInterval(-8 * 86400)])]
        #expect(RenaultPlugin.dropped(in: all, for: info, forgetAfter: .seconds(7 * 86400), now: now) == [.cockpit])
        #expect(RenaultPlugin.dropped(in: all, for: VehicleInfo(vin: Fixtures.vin, modelCode: "A4E1VE"), forgetAfter: .seconds(7 * 86400), now: now).isEmpty)
    }

    @Test func theBudgetNeverExceedsTheHour() async throws {
        let budget = RequestBudget(maxCallsPerHour: 12, hour: .seconds(3600), cooldown: .seconds(60))
        #expect(await budget.pollBudget == 6)
        for _ in 0..<6 { try await budget.record(.poll) }
        await #expect(throws: RenaultError.quota) { try await budget.record(.poll) }
        await #expect(throws: RenaultError.quota) { try await budget.record(.confirmation) }
        for _ in 0..<6 { try await budget.record(.action) }
        await #expect(throws: RenaultError.quota) { try await budget.record(.action) }
        #expect(await budget.sentInLastHour == 12)
    }
}
