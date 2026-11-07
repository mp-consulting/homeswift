import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// The server-sent events loop (docs/clean-room/SmartThings.md, 5.1): create a subscription, open it within the minute,
/// reconcile on its first welcome, apply events; on goodbye, an end, a silence past the watchdog or an error, a new
/// subscription after a back-off. A lasting 403 falls back to polling and tries again every 30 minutes.
extension SmartThingsPlugin {
    enum StreamEnd: Sendable, Equatable {
        case goodbye
        case ended
        case silent
    }

    func eventLoop() async {
        var attempt = 0
        let backoff = Backoff(initial: timing.seconds(5), maximum: timing.seconds(600), jitter: .proportional(0.2))
        while !Task.isCancelled, !stopped {
            var wait = backoff.delay(attempt: attempt)
            do {
                if let old = subscriptionID {
                    subscriptionID = nil
                    await api.deleteSubscription(old)
                }
                let subscription = try await api.createSubscription(name: "homeswift-\(context.name)", locationID: locationID ?? "ALL")
                subscriptionID = subscription.id
                let response = try await api.openStream(subscription)
                let end = try await consume(response.events)
                setActive(false)
                switch end {
                case .goodbye: logger.debug("SmartThings ended the event stream (goodbye): subscribing again")
                case .ended: logger.info("The SmartThings event stream ended: subscribing again")
                case .silent: logger.warning("The SmartThings event stream went quiet: subscribing again")
                }
                // A connection that welcomed us starts the back-off again.
                attempt = 0
                wait = end == .goodbye ? .zero : backoff.delay(attempt: 0)
            } catch let failure as TokenStore.Failure {
                setActive(false)
                if case .refused = failure { return }
                attempt += 1
            } catch let error as SmartThingsError {
                setActive(false)
                switch error.status {
                case 403?:
                    sseNote = "SmartThings refused the event stream (HTTP 403): updates come by polling; trying again in 30 minutes"
                    logger.warning("\(sseNote ?? "")")
                    wait = timing.seconds(1800)
                case 418?:
                    sseNote = "SmartThings flagged this client on the event stream (HTTP 418): updates come by polling; trying again in an hour"
                    logger.error("\(sseNote ?? "")")
                    wait = timing.seconds(3600)
                case 404?:
                    attempt += 1
                default:
                    if attempt == 0 { logger.warning("The SmartThings event stream failed: \(error)") }
                    attempt += 1
                }
            } catch is CancellationError {
                return
            } catch {
                setActive(false)
                if attempt == 0 { logger.warning("The SmartThings event stream failed: \(error)") }
                attempt += 1
            }
            guard !Task.isCancelled, !stopped else { return }
            try? await Task.sleep(for: wait)
        }
    }

    private func setActive(_ active: Bool) {
        guard sseActive != active else { return }
        sseActive = active
        if active { sseNote = nil }
    }

    /// Reads the stream until it says goodbye, ends, or stays silent past the watchdog.
    private func consume(_ events: HTTPStreamingResponse.Events) async throws -> StreamEnd {
        let last = NIOLockedValueBox(ContinuousClock.now)
        let watchdog = timing.seconds(dependencies.watchdogSeconds)
        return try await withThrowingTaskGroup(of: StreamEnd.self) { group in
            group.addTask { [weak self] in
                var welcomed = false
                for try await event in events {
                    last.withLockedValue { $0 = .now }
                    guard let self else { return .ended }
                    if let end = await self.handle(event, welcomed: &welcomed) { return end }
                }
                return .ended
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: max(watchdog / 10, .milliseconds(5)))
                    if ContinuousClock.now - last.withLockedValue({ $0 }) > watchdog { return .silent }
                }
            }
            let end = try await group.next() ?? .ended
            group.cancelAll()
            return end
        }
    }

    /// One message of the stream; a `StreamEnd` ends it.
    func handle(_ event: ServerSentEvent, welcomed: inout Bool) async -> StreamEnd? {
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if event.event.caseInsensitiveCompare("goodbye") == .orderedSame || data.caseInsensitiveCompare("goodbye") == .orderedSame { return .goodbye }
        switch event.event {
        case "CONTROL_EVENT":
            // The first welcome of a connection reconciles what the gap lost; the next ones are keepalives.
            if data.caseInsensitiveCompare("welcome") == .orderedSame, !welcomed {
                welcomed = true
                setActive(true)
                await reconcile()
            }
        case "DEVICE_EVENT":
            guard let json = try? JSONValue(string: data), let deviceEvent = DeviceEvent(json) else {
                logger.debug("A SmartThings event that is not one: \(event.event)")
                return nil
            }
            apply(deviceEvent)
        case "DEVICE_HEALTH_EVENT":
            guard let json = try? JSONValue(string: data) else { return nil }
            let health = json["deviceHealthEvent"] ?? json
            guard let deviceID = health["deviceId"]?.stringValue, let binding = bindings[deviceID] else { return nil }
            if let state = (health["status"] ?? health["state"])?.stringValue?.uppercased(), state == "ONLINE" || state == "OFFLINE" {
                binding.box.setHealth(state)
            }
        case "DEVICE_LIFECYCLE_EVENT":
            scheduleRediscovery()
        case "SCENE_LIFECYCLE_EVENT":
            scheduleRediscovery(scenes: true)
        default:
            logger.debug("Ignored a SmartThings event: \(event.event)")
        }
        return nil
    }

    /// A device event to its accessory; one of a device not known yet lists the devices again.
    func apply(_ event: DeviceEvent) {
        guard let binding = bindings[event.deviceID] else {
            let known = copies[event.deviceID] != nil || unsupported[event.deviceID] != nil || context.isExcluded(event.deviceID)
            if !known, listed.contains(where: { $0.deviceID == event.deviceID }) == false { scheduleRediscovery() }
            return
        }
        statusFailures[event.deviceID] = nil
        binding.apply(event, now: dependencies.now())
    }
}
