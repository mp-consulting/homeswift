import Foundation
import Homeswift
import HomeswiftPlugin

/// The accessory types of section 5, each a function from an entry to its services.
extension Thing {
    func services(for entry: Entry) -> [Service] {
        let config = entry.config
        var services: [Service]
        switch config.type {
        case "airPressureSensor": services = airPressureSensor(entry)
        case "airPurifier": services = airPurifier(entry)
        case "airQualitySensor": services = airQualitySensor(entry)
        case "battery": services = battery(entry, standalone: true).map { [$0] } ?? []
        case "carbonDioxideSensor": services = carbonDioxideSensor(entry)
        case "carbonMonoxideSensor": services = carbonMonoxideSensor(entry)
        case "contactSensor": services = contactSensor(entry)
        case "dehumidifier": services = dehumidifier(entry)
        case "door": services = positioned(entry, .door)
        case "window": services = positioned(entry, .window)
        case "doorbell": services = doorbell(entry)
        case "fan": services = fan(entry)
        case "fanv2": services = fanv2(entry)
        case "garageDoorOpener": services = garageDoorOpener(entry)
        case "heaterCooler": services = heaterCooler(entry)
        case "humiditySensor": services = humiditySensor(entry)
        case "irrigationSystem": services = irrigationSystem(entry)
        case "leakSensor": services = leakSensor(entry)
        case "lightbulb": services = lightbulb(entry)
        case "lightSensor": services = lightSensor(entry)
        case "lockMechanism": services = lockMechanism(entry)
        case "motionSensor": services = motionSensor(entry)
        case "microphone": services = muted(entry, .microphone)
        case "speaker": services = muted(entry, .speaker)
        case "occupancySensor": services = occupancySensor(entry)
        case "outlet": services = outlet(entry)
        case "securitySystem": services = securitySystem(entry)
        case "smokeSensor": services = smokeSensor(entry)
        case "statelessProgrammableSwitch": services = statelessSwitch(entry)
        case "switch": services = switchService(entry)
        case "television": services = television(entry)
        case "temperatureSensor": services = temperatureSensor(entry)
        case "thermostat": services = thermostat(entry)
        case "valve": services = valve(entry)
        case "weatherStation": services = weatherStation(entry)
        default:
            logger.error("\(config.name): unrecognized type \(config.rawType)")
            return []
        }
        if config.type != "battery", !services.isEmpty, let battery = battery(entry, standalone: false) { services.append(battery) }
        if let history = entry.history { services.append(history.service) }
        return services
    }

    // MARK: Sensors

    func airPressureSensor(_ entry: Entry, name: String? = nil) -> [Service] {
        let service = ServiceBuilder(Eve.airPressureSensor)
        float(service, Eve.airPressure, entry, get: "getAirPressure", property: "airPressure", initial: 700) { value in
            self.record(entry, EveHistory.Entry(time: self.dependencies.now(), pressure: value))
        }
        service.add(Eve.elevation, .int(100))
        status(service, entry)
        return [primary(service, entry, name: name)]
    }

    func airQualitySensor(_ entry: Entry) -> [Service] {
        let config = entry.config
        let room2 = config.flag("room2")
        let service = ServiceBuilder(.airQualitySensor)
        enumerated(
            service, .airQuality, entry, keys: ["airQualityValues"], defaults: ["UNKNOWN", "EXCELLENT", "GOOD", "FAIR", "INFERIOR", "POOR"],
            get: "getAirQuality", property: "airQuality", initial: 0)
        status(service, entry)
        let densities: [(String, CharacteristicType, String)] = [
            ("getCarbonDioxideLevel", .carbonDioxideLevel, "carbonDioxideLevel"), ("getPM10Density", .pm10Density, "pm10density"),
            ("getPM2_5Density", .pm2_5Density, "pm2_5density"), ("getOzoneDensity", .ozoneDensity, "ozoneDensity"),
            ("getNitrogenDioxideDensity", .nitrogenDioxideDensity, "nitrogenDioxideDensity"), ("getSulphurDioxideDensity", .sulphurDioxideDensity, "sulphurDioxideDensity"),
            ("getVOCDensity", .vocDensity, "VOCDensity"), ("getCarbonMonoxideLevel", .carbonMonoxideLevel, "carbonMonoxideLevel"),
        ]
        for (topic, type, property) in densities where config.has(topic) {
            float(service, type, entry, get: topic, property: property) { value in
                if room2, topic == "getVOCDensity" { self.record(entry, EveHistory.Entry(time: self.dependencies.now(), voc: value)) }
            }
        }
        if entry.history != nil, !room2, config.has("getAirQualityPPM") {
            float(service, Eve.airParticulateDensity, entry, get: "getAirQualityPPM", property: "airQualityPPM") { value in
                self.record(entry, EveHistory.Entry(time: self.dependencies.now(), ppm: value))
            }
        }
        var services = [primary(service, entry, name: config.serviceName("airQuality", config.name))]
        if config.has("getCurrentTemperature") {
            let temperature = ServiceBuilder(.temperatureSensor)
            currentTemperature(temperature, entry) { value in self.record(entry, EveHistory.Entry(time: self.dependencies.now(), temp: value)) }
            temperatureDisplayUnits(temperature, entry)
            status(temperature, entry)
            services.append(temperature.build(name: config.serviceName("temperature", "\(config.name)-Temperature"), subtype: entry.subtype))
        }
        if config.has("getCurrentRelativeHumidity") {
            services.append(secondaryHumidity(entry, name: config.serviceName("humidity", "\(config.name)-Humidity")))
        }
        return services
    }

    func carbonDioxideSensor(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.carbonDioxideSensor)
        enumerated(
            service, .carbonDioxideDetected, entry, keys: ["carbonDioxideDetectedValues"], defaults: ["NORMAL", "ABNORMAL"],
            get: "getCarbonDioxideDetected", property: "carbonDioxideDetected", initial: 0)
        status(service, entry)
        if entry.config.has("getCarbonDioxideLevel") { float(service, .carbonDioxideLevel, entry, get: "getCarbonDioxideLevel", property: "carbonDioxideLevel") }
        if entry.config.has("getCarbonDioxidePeakLevel") {
            float(service, .carbonDioxidePeakLevel, entry, get: "getCarbonDioxidePeakLevel", property: "carbonDioxidePeakLevel")
        }
        return [primary(service, entry)]
    }

    /// The documented level keys, and the lower-case ones the Homebridge plugin checks (section 5.5, Gaps 3).
    func carbonMonoxideSensor(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.carbonMonoxideSensor)
        enumerated(
            service, .carbonMonoxideDetected, entry, keys: ["carbonMonoxideDetectedValues"], defaults: ["NORMAL", "ABNORMAL"],
            get: "getCarbonMonoxideDetected", property: "carbonMonoxideDetected", initial: 0)
        status(service, entry)
        for topic in ["getCarbonMonoxideLevel", "getcarbonMonoxideLevel"] where entry.config.has(topic) {
            float(service, .carbonMonoxideLevel, entry, get: topic, property: "carbonMonoxideLevel")
            break
        }
        for topic in ["getCarbonMonoxidePeakLevel", "getcarbonMonoxidePeakLevel"] where entry.config.has(topic) {
            float(service, .carbonMonoxidePeakLevel, entry, get: topic, property: "carbonMonoxidePeakLevel", initial: 0)
            break
        }
        return [primary(service, entry)]
    }

    /// The HumiditySensor beside another type's primary service (air quality, weather station).
    func secondaryHumidity(_ entry: Entry, name: String) -> Service {
        let humidity = ServiceBuilder(.humiditySensor)
        float(humidity, .currentRelativeHumidity, entry, get: "getCurrentRelativeHumidity", property: "currentRelativeHumidity") { value in
            self.record(entry, EveHistory.Entry(time: self.dependencies.now(), humidity: value))
        }
        status(humidity, entry)
        return humidity.build(name: name, subtype: entry.subtype)
    }

    func humiditySensor(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.humiditySensor)
        float(service, .currentRelativeHumidity, entry, get: "getCurrentRelativeHumidity", property: "currentRelativeHumidity") { value in
            self.record(entry, EveHistory.Entry(time: self.dependencies.now(), humidity: value))
        }
        status(service, entry)
        return [primary(service, entry)]
    }

    func temperatureSensor(_ entry: Entry, name: String? = nil) -> [Service] {
        let service = ServiceBuilder(.temperatureSensor)
        currentTemperature(service, entry) { value in self.record(entry, EveHistory.Entry(time: self.dependencies.now(), temp: value)) }
        status(service, entry)
        return [primary(service, entry, name: name)]
    }

    func lightSensor(_ entry: Entry, name: String? = nil) -> [Service] {
        let service = ServiceBuilder(.lightSensor)
        float(service, .currentAmbientLightLevel, entry, get: "getCurrentAmbientLightLevel", property: "currentAmbientLightLevel", initial: 0.0001)
        status(service, entry)
        return [primary(service, entry, name: name)]
    }

    func leakSensor(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.leakSensor)
        boolean(service, .leakDetected, entry, get: "getLeakDetected", property: "leakDetected", reset: entry.config.milliseconds("resetStateAfterms"))
        if entry.config.hasAny("getWaterLevel", "setWaterLevel") { integer(service, .waterLevel, entry, get: "getWaterLevel", set: "setWaterLevel", property: "waterLevel") }
        status(service, entry)
        return [primary(service, entry)]
    }

    func smokeSensor(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.smokeSensor)
        boolean(service, .smokeDetected, entry, get: "getSmokeDetected", property: "smokeDetected", reset: entry.config.milliseconds("resetStateAfterms"))
        status(service, entry)
        return [primary(service, entry)]
    }

    func occupancySensor(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.occupancySensor)
        boolean(service, .occupancyDetected, entry, get: "getOccupancyDetected", property: "occupancyDetected")
        status(service, entry)
        return [primary(service, entry)]
    }

    func contactSensor(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.contactSensor)
        var door: ((Bool) -> Void)?
        if let history = entry.history { door = doorHistory(service, entry, history) }
        boolean(service, .contactSensorState, entry, get: "getContactSensorState", property: "contactSensorState", reset: entry.config.milliseconds("resetStateAfterms")) {
            door?($0)
        }
        status(service, entry)
        return [primary(service, entry)]
    }

    func motionSensor(_ entry: Entry, name: String? = nil, subtype: String?? = nil, withStatus: Bool = true) -> [Service] {
        let service = ServiceBuilder(.motionSensor)
        var motion: ((Bool) -> Void)?
        if withStatus, let history = entry.history { motion = motionHistory(service, entry, history) }
        boolean(service, .motionDetected, entry, get: "getMotionDetected", property: "motionDetected", reset: entry.config.milliseconds("turnOffAfterms")) {
            motion?($0)
        }
        if withStatus {
            status(service, entry)
            return [primary(service, entry, name: name, subtype: subtype)]
        }
        return [service.build(name: name, subtype: subtype ?? entry.subtype)]
    }

    func securitySystem(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.securitySystem)
        enumerated(
            service, .securitySystemTargetState, entry, keys: ["targetStateValues"], defaults: ["SA", "AA", "NA", "D"],
            get: "getTargetState", set: "setTargetState", property: "targetState", initial: 3, restrict: "restrictTargetState")
        enumerated(
            service, .securitySystemCurrentState, entry, keys: ["currentStateValues"], defaults: ["SA", "AA", "NA", "D", "T"],
            get: "getCurrentState", property: "currentState", initial: 3)
        if entry.config.has("getStatusFault") { boolean(service, .statusFault, entry, get: "getStatusFault", property: "statusFault") }
        if entry.config.has("getStatusTampered") { boolean(service, .statusTampered, entry, get: "getStatusTampered", property: "statusTampered") }
        if entry.config.has("getAltSensorState") {
            let booleans = Booleans(entry.config)
            subscribe(entry.config, "getAltSensorState", property: "AltSensorState") { message in
                if let state = booleans.decode(message) { self.logger.warning("\(entry.name): AltSensorState \(state)") }
            }
        }
        return [primary(service, entry)]
    }

    func weatherStation(_ entry: Entry) -> [Service] {
        let config = entry.config
        var services = temperatureSensor(entry, name: config.serviceName("temperature", "\(config.name) Temperature"))
        if config.has("getCurrentRelativeHumidity") {
            services.append(secondaryHumidity(entry, name: config.serviceName("humidity", "\(config.name) Humidity")))
        }
        if config.has("getAirPressure") {
            let pressure = ServiceBuilder(Eve.airPressureSensor)
            float(pressure, Eve.airPressure, entry, get: "getAirPressure", property: "airPressure", initial: 700) { value in
                self.record(entry, EveHistory.Entry(time: self.dependencies.now(), pressure: value))
            }
            pressure.add(Eve.elevation, .int(100))
            status(pressure, entry)
            services.append(pressure.build(name: config.serviceName("airPressure", "\(config.name) AirPressure"), subtype: entry.subtype))
        }
        if config.has("getCurrentAmbientLightLevel") {
            let light = ServiceBuilder(.lightSensor)
            float(light, .currentAmbientLightLevel, entry, get: "getCurrentAmbientLightLevel", property: "currentAmbientLightLevel", initial: 0.0001)
            status(light, entry)
            services.append(light.build(name: config.serviceName("ambientLightLevel", "\(config.name) Light Level"), subtype: entry.subtype))
        }
        let weather: [(String, CharacteristicType, String, Kind)] = [
            ("getWeatherCondition", Eve.condition, "weatherCondition", .string), ("getRain1h", Eve.rain1h, "rain1h", .int),
            ("getRain24h", Eve.rain24h, "rain24h", .int), ("getUVIndex", Eve.uvIndex, "uvIndex", .int), ("getVisibility", Eve.visibility, "visibility", .int),
            ("getWindDirection", Eve.windDirection, "windDirection", .string), ("getWindSpeed", Eve.windSpeed, "windSpeed", .float),
            ("getmaxWind", Eve.maximumWindSpeed, "maxWind", .float), ("getDewPoint", Eve.dewPoint, "DewPoint", .float),
        ]
        let configured = weather.filter { config.has($0.0) }
        if !configured.isEmpty {
            let service = ServiceBuilder(Eve.weatherService)
            for (topic, type, property, kind) in configured {
                let characteristic = service.add(type, type.format == .string ? .string("-") : nil)
                bind(characteristic, config, kind, get: topic, set: nil, property: property, online: entry.online)
            }
            services.append(service.build(name: config.serviceName("weather", "\(config.name) Weather"), subtype: entry.subtype))
        }
        return services
    }

    // MARK: Switches, outlets, fans

    func switchService(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.switch)
        var history: ((Bool) -> Void)?
        if let eve = entry.history { history = switchHistory(service, eve) }
        on(service, entry) { history?($0) }
        return [primary(service, entry)]
    }

    func outlet(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.outlet)
        on(service, entry)
        if config.has("getInUse") { boolean(service, .outletInUse, entry, get: "getInUse", property: "outletInUse") }
        var energy: ((Double) -> Void)?
        if let history = entry.history { energy = energyHistory(service, entry, history, counts: !config.has("getTotalConsumption")) }
        if config.has("getWatts") {
            float(service, Eve.currentConsumption, entry, get: "getWatts", property: "currentConsumption", initial: 0) { energy?($0) }
        }
        if config.has("getVolts") {
            let minimum = config.number("minVolts"), maximum = config.number("maxVolts")
            let initial = min(max(0, minimum ?? 0), maximum ?? 380)
            float(service, Eve.voltage, entry, get: "getVolts", property: "voltage", initial: initial, minimum: minimum, maximum: maximum)
        }
        if config.has("getAmperes") { float(service, Eve.electricCurrent, entry, get: "getAmperes", property: "electricCurrent", initial: 0) }
        if config.has("getTotalConsumption") { float(service, Eve.totalConsumption, entry, get: "getTotalConsumption", property: "totalConsumption", initial: 0) }
        return [primary(service, entry)]
    }

    func fan(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.fan)
        rotationDirection(service, entry)
        if config.hasAny("getRotationSpeed", "setRotationSpeed") {
            if config.has("setOn") {
                on(service, entry)
                rotationSpeed(service, entry)
            } else {
                levelMeansOff(service, entry, level: .rotationSpeed, get: "getRotationSpeed", set: "setRotationSpeed", property: "rotationSpeed")
            }
        } else {
            on(service, entry)
        }
        return [primary(service, entry)]
    }

    func fanv2(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.fanv2)
        active(service, entry)
        // The block-level key too, which is what the Homebridge plugin checks (Gaps 5).
        if config.has("getCurrentFanState") || config.flag("getCurrentFanState") {
            enumerated(
                service, .currentFanState, entry, keys: ["currentFanValues", "currentFanStateValues"], defaults: ["INACTIVE", "IDLE", "BLOWING_AIR"],
                get: "getCurrentFanState", property: "currentFanState", initial: 0)
        }
        if config.hasAny("getTargetFanState", "setTargetFanState") {
            enumerated(
                service, .targetFanState, entry, keys: ["targetFanStateValues", "targetFanValues"], defaults: ["MANUAL", "AUTO"],
                get: "getTargetFanState", set: "setTargetFanState", property: "targetFanState", initial: 1)
        }
        lockPhysicalControls(service, entry)
        rotationDirection(service, entry)
        rotationSpeed(service, entry)
        swingMode(service, entry)
        return [primary(service, entry)]
    }

    func airPurifier(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.airPurifier)
        active(service, entry)
        enumerated(
            service, .currentAirPurifierState, entry, keys: ["currentAirPurifierStateValues", "currentAirPurifierValues"], defaults: ["INACTIVE", "IDLE", "PURIFYING"],
            get: "getCurrentAirPurifierState", property: "currentAirPurifierState", initial: 0)
        enumerated(
            service, .targetAirPurifierState, entry, keys: ["targetAirPurifierStateValues", "targetAirPurifierValues"], defaults: ["MANUAL", "AUTO"],
            get: "getTargetAirPurifierState", set: "setTargetAirPurifierState", property: "targetAirPurifierState", initial: 1)
        rotationSpeed(service, entry)
        swingMode(service, entry)
        lockPhysicalControls(service, entry)
        var linked: [Service] = []
        if config.hasAny("getFilterChangeIndication", "getFilterLifeLevel", "setResetFilterIndication") {
            let filter = ServiceBuilder(.filterMaintenance)
            boolean(filter, .filterChangeIndication, entry, get: "getFilterChangeIndication", property: "filterChangeIndication")
            if config.has("getFilterLifeLevel") { float(filter, .filterLifeLevel, entry, get: "getFilterLifeLevel", property: "filterLifeLevel", initial: 100) }
            if config.has("setResetFilterIndication") {
                let reset = filter.add(.resetFilterIndication)
                let booleans = Booleans(config)
                onWrite(reset) { value in
                    if value.intValue == 1 { self.publish(config, "setResetFilterIndication", property: "resetFilterIndication", booleans.on) }
                }
            }
            linked.append(filter.build(name: config.serviceName("filter", "\(config.name)-Filter"), subtype: entry.subtype))
        }
        return [primary(service, entry, linked: linked)] + linked
    }

    func dehumidifier(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.humidifierDehumidifier)
        active(service, entry)
        float(service, .currentRelativeHumidity, entry, get: "getCurrentRelativeHumidity", property: "currentRelativeHumidity")
        enumerated(
            service, .currentHumidifierDehumidifierState, entry, keys: ["currentHumidifierDehumidifierState"],
            defaults: ["INACTIVE", "IDLE", "HUMIDIFYING", "DEHUMIDIFYING"], get: "getCurrentHumidifierDehumidifierState",
            property: "currentHumidifierDehumidifierState", initial: 0)
        // `restrictDehumidifierState` as the valid targets, as intended (Gaps 4).
        enumerated(
            service, .targetHumidifierDehumidifierState, entry, keys: ["targetHumidifierDehumidifierState"],
            defaults: ["HUMIDIFIER_OR_DEHUMIDIFIER", "HUMIDIFIER", "DEHUMIDIFIER"], get: "getTargetHumidifierDehumidifierState",
            set: "setTargetHumidifierDehumidifierState", property: "targetHumidifierDehumidifierState", initial: 2, restrict: "restrictDehumidifierState")
        if config.has("setRelativeHumidityDehumidifierThreshold") {
            let threshold = service.add(.relativeHumidityDehumidifierThreshold)
            bind(
                threshold, config, .float, get: "getRelativeHumidityDehumidifierThreshold", set: "setRelativeHumidityDehumidifierThreshold",
                property: "relativeHumidityDehumidifierThreshold", online: entry.online)
        }
        if config.has("getWaterLevel") { integer(service, .waterLevel, entry, get: "getWaterLevel", set: "setWaterLevel", property: "waterLevel") }
        return [primary(service, entry)]
    }

    func heaterCooler(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.heaterCooler)
        active(service, entry)
        enumerated(
            service, .currentHeaterCoolerState, entry, keys: ["currentHeaterCoolerValues"], defaults: ["INACTIVE", "IDLE", "HEATING", "COOLING"],
            get: "getCurrentHeaterCoolerState", property: "currentHeaterCoolerState", initial: 0)
        enumerated(
            service, .targetHeaterCoolerState, entry, keys: ["targetHeaterCoolerValues"], defaults: ["AUTO", "HEAT", "COOL"],
            get: "getTargetHeaterCoolerState", set: "setTargetHeaterCoolerState", property: "targetHeaterCoolerState", initial: 0, restrict: "restrictHeaterCoolerState")
        currentTemperature(service, entry)
        lockPhysicalControls(service, entry)
        swingMode(service, entry)
        thresholds(service, entry)
        if config.hasAny("getTemperatureDisplayUnits", "setTemperatureDisplayUnits") { temperatureDisplayUnits(service, entry) }
        rotationSpeed(service, entry)
        if config.has("getStatusFault") { boolean(service, .statusFault, entry, get: "getStatusFault", property: "statusFault") }
        return [primary(service, entry)]
    }

    func thresholds(_ service: ServiceBuilder, _ entry: Entry) {
        let config = entry.config
        let minimum = config.number("minTemperature"), maximum = config.number("maxTemperature")
        if config.hasAny("getCoolingThresholdTemperature", "setCoolingThresholdTemperature") {
            float(
                service, .coolingThresholdTemperature, entry, get: "getCoolingThresholdTemperature", set: "setCoolingThresholdTemperature",
                property: "coolingThresholdTemperature", initial: 25, minimum: minimum, maximum: maximum)
        }
        if config.hasAny("getHeatingThresholdTemperature", "setHeatingThresholdTemperature") {
            float(
                service, .heatingThresholdTemperature, entry, get: "getHeatingThresholdTemperature", set: "setHeatingThresholdTemperature",
                property: "heatingThresholdTemperature", initial: 20, minimum: minimum, maximum: maximum)
        }
    }

    func thermostat(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.thermostat)
        // Not in HAP's Thermostat, kept for parity (Gaps 13).
        active(service, entry)
        let modes = ["heatingCoolingStateValues"]
        enumerated(
            service, .currentHeatingCoolingState, entry, keys: modes, defaults: ["OFF", "HEAT", "COOL"],
            get: "getCurrentHeatingCoolingState", property: "currentHeatingCoolingState", initial: 0)
        enumerated(
            service, .targetHeatingCoolingState, entry, keys: modes, defaults: ["OFF", "HEAT", "COOL", "AUTO"],
            get: "getTargetHeatingCoolingState", set: "setTargetHeatingCoolingState", property: "targetHeatingCoolingState", initial: 0,
            restrict: "restrictHeatingCoolingState")
        currentTemperature(service, entry)
        float(
            service, .targetTemperature, entry, get: "getTargetTemperature", set: "setTargetTemperature", property: "targetTemperature", initial: 10,
            minimum: config.number("minTemperature"), maximum: config.number("maxTemperature"))
        temperatureDisplayUnits(service, entry)
        if config.has("getCurrentRelativeHumidity") { float(service, .currentRelativeHumidity, entry, get: "getCurrentRelativeHumidity", property: "currentRelativeHumidity") }
        if config.hasAny("getTargetRelativeHumidity", "setTargetRelativeHumidity") {
            float(service, .targetRelativeHumidity, entry, get: "getTargetRelativeHumidity", set: "setTargetRelativeHumidity", property: "targetRelativeHumidity")
        }
        thresholds(service, entry)
        if config.has("getStatusFault") { boolean(service, .statusFault, entry, get: "getStatusFault", property: "statusFault") }
        return [primary(service, entry)]
    }

    // MARK: Doors, locks, positions

    func positioned(_ entry: Entry, _ type: ServiceType) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(type)
        let minimum = config.integer("minPosition"), maximum = config.integer("maxPosition")
        integer(service, .currentPosition, entry, get: "getCurrentPosition", property: "currentPosition", initial: minimum ?? 0, minimum: minimum, maximum: maximum)
        integer(
            service, .targetPosition, entry, get: "getTargetPosition", set: "setTargetPosition", property: "targetPosition", initial: minimum ?? 0,
            minimum: minimum, maximum: maximum)
        enumerated(
            service, .positionState, entry, keys: ["positionStateValues"], defaults: ["DECREASING", "INCREASING", "STOPPED"],
            get: "getPositionState", property: "positionState", initial: 2)
        if config.has("setHoldPosition") {
            let hold = service.add(.holdPosition)
            let booleans = Booleans(config)
            onWrite(hold) { value in self.publish(config, "setHoldPosition", property: "holdPosition", booleans.encode(value.boolValue == true)) }
        }
        if config.has("getObstructionDetected") { boolean(service, .obstructionDetected, entry, get: "getObstructionDetected", property: "obstructionDetected") }
        return [primary(service, entry)]
    }

    func lockMechanism(_ entry: Entry) -> [Service] {
        let service = ServiceBuilder(.lockMechanism)
        lockStates(service, entry)
        return [primary(service, entry)]
    }

    func muted(_ entry: Entry, _ type: ServiceType) -> [Service] {
        let service = ServiceBuilder(type)
        boolean(service, .mute, entry, get: "getMute", set: "setMute", property: "mute")
        if entry.config.hasAny("getVolume", "setVolume") { float(service, .volume, entry, get: "getVolume", set: "setVolume", property: "volume") }
        return [primary(service, entry)]
    }

    func doorbell(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.doorbell)
        switchEvent(service, entry, topic: "getSwitch", property: "switch", values: config["switchValues"], restrict: config["restrictSwitchValues"])
        if config.hasAny("getBrightness", "setBrightness") {
            if config.has("setOn") {
                on(service, entry)
                integer(service, .brightness, entry, get: "getBrightness", set: "setBrightness", property: "brightness")
            } else {
                levelMeansOff(service, entry, level: .brightness, get: "getBrightness", set: "setBrightness", property: "brightness")
            }
        }
        if config.hasAny("getVolume", "setVolume") { float(service, .volume, entry, get: "getVolume", set: "setVolume", property: "volume", initial: 0) }
        var services = [primary(service, entry)]
        if config.has("getMotionDetected") {
            services += motionSensor(entry, name: config.serviceName("motion", "\(config.name)-motion"), withStatus: false)
        }
        return services
    }

    /// A ProgrammableSwitchEvent on one topic: `values` (by default `1`, `2`, `L`) fire single, double and long presses.
    func switchEvent(_ service: ServiceBuilder, _ entry: Entry, topic: String, property: String, values: JSONValue?, restrict: JSONValue?) {
        let allowed = restrict?.arrayValue?.compactMap(\.doubleValue).map { Int($0) }
        let characteristic = service.add(allowed.map { CharacteristicType.programmableSwitchEvent.with(validValues: $0) } ?? .programmableSwitchEvent)
        let enumeration = values?.arrayValue.map { Enumeration(values: $0) } ?? Enumeration(values: ["1", "2", "L"].map(JSONValue.string))
        bind(characteristic, entry.config, .enumeration(enumeration), get: topic, set: nil, property: property, online: entry.online, eventOnly: true)
    }

    func statelessSwitch(_ entry: Entry) -> [Service] {
        let config = entry.config
        guard let topics = config.topics["getSwitch"]?.arrayValue else {
            let service = ServiceBuilder(.statelessProgrammableSwitch)
            switchEvent(service, entry, topic: "getSwitch", property: "switch", values: config["switchValues"], restrict: config["restrictSwitchValues"])
            return [primary(service, entry)]
        }
        let label = ServiceBuilder(.serviceLabel)
        label.add(.serviceLabelNamespace, .int(config.string("labelType") == "numerals" ? 1 : 0))
        var services = [primary(label, entry, subtype: .some(nil))]
        // One list for every button, or a list per button (the first for those without one).
        func perButton(_ value: JSONValue?, _ index: Int) -> JSONValue? {
            guard let lists = value?.arrayValue, let first = lists.first, first.arrayValue != nil else { return value }
            return index < lists.count ? lists[index] : first
        }
        for (index, topic) in topics.enumerated() {
            var values = config.values
            var buttonTopics = config.topics
            buttonTopics["getSwitch\(index)"] = topic
            values["topics"] = .object(buttonTopics)
            let button = Entry(config: Config(values), online: entry.online)
            let service = ServiceBuilder(.statelessProgrammableSwitch)
            service.add(.serviceLabelIndex, .int(index + 1))
            switchEvent(
                service, button, topic: "getSwitch\(index)", property: "switch\(index)", values: perButton(config["switchValues"], index),
                restrict: perButton(config["restrictSwitchValues"], index))
            services.append(service.build(name: "\(config.name) \(index)", subtype: String(index + 1)))
        }
        return services
    }

    func garageDoorOpener(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.garageDoorOpener)
        let doorValues = config["doorValues"]?.arrayValue
        let target = service.add(.targetDoorState, .int(0))
        let targets = Enumeration(values: config["doorTargetValues"]?.arrayValue ?? doorValues.map { Array($0.prefix(2)) } ?? [.string("O"), .string("C")])
        let current = service.add(.currentDoorState, .int(1))
        let derived = config.has("getDoorMoving")
        let moving = Box(false)
        func derive() {
            after("door-derive", .seconds(1)) { [weak current, weak target] in
                guard let current, let target else { return }
                let open = target.value.intValue == 0
                current.value = .int(moving.value ? (open ? 2 : 3) : (open ? 0 : 1))
            }
        }
        bind(
            target, config, .enumeration(targets), get: "getTargetDoorState", set: "setTargetDoorState", property: "targetDoorState", online: entry.online,
            received: { _, changed in if derived, changed { derive() } }, wrote: { _ in if derived { derive() } })
        if derived {
            serveReads(current, entry.online)
            let booleans = Booleans(config)
            subscribe(config, "getDoorMoving", property: "doorMoving") { message in
                guard let flag = booleans.decode(message), flag != moving.value else { return }
                moving.value = flag
                derive()
            }
            derive()
        } else {
            let currents = Enumeration(
                values: config["doorCurrentValues"]?.arrayValue ?? doorValues ?? ["O", "C", "o", "c", "S"].map(JSONValue.string))
            bind(current, config, .enumeration(currents), get: "getCurrentDoorState", set: nil, property: "currentDoorState", online: entry.online)
        }
        boolean(service, .obstructionDetected, entry, get: "getObstructionDetected", property: "obstructionDetected")
        lockStates(service, entry)
        return [primary(service, entry)]
    }
}

/// A value the closures of one accessory share.
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
