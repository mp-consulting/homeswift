import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftWingman

/// A slow lamp: each write is held until the test lets it go, and the ones sent are kept in order.
private final class SlowLamp: Sendable {
    private let state = NIOLockedValueBox<(sent: [String], held: [String: CheckedContinuation<Void, Never>], overlapped: Bool)>(([], [:], false))

    func send(_ value: String) async {
        await withCheckedContinuation { continuation in
            state.withLockedValue { state in
                if !state.held.isEmpty { state.overlapped = true }
                state.sent.append(value)
                state.held[value] = continuation
            }
        }
    }

    /// Whether a write was sent while another was under way.
    var overlapped: Bool { state.withLockedValue { $0.overlapped } }

    func release(_ value: String) {
        state.withLockedValue { $0.held.removeValue(forKey: value) }?.resume()
    }

    var sent: [String] { state.withLockedValue { $0.sent } }
    func isHeld(_ value: String) -> Bool { state.withLockedValue { $0.held[value] != nil } }
}

@Suite struct WriteOrderTests {
    /// On, then off and on again while the first is still under way: the off is never sent, and the last on goes after
    /// the first, never beside it.
    @Test func aWriteWaitsForTheOneBeforeAndTheLatestWins() async throws {
        let order = WriteOrder()
        let lamp = SlowLamp()
        let first = Task { try await order.write("lamp/on") { await lamp.send("on") } }
        #expect(await eventually { lamp.isHeld("on") })
        let off = Task { try await order.write("lamp/on") { await lamp.send("off") } }
        #expect(await eventually { await order.asked["lamp/on"] == 2 })
        let again = Task { try await order.write("lamp/on") { await lamp.send("on again") } }
        #expect(await eventually { await order.asked["lamp/on"] == 3 })
        #expect(lamp.sent == ["on"])
        lamp.release("on")
        try await first.value
        // The off is answered as written once its turn comes: a later write took its place.
        try await off.value
        #expect(await eventually { lamp.isHeld("on again") })
        lamp.release("on again")
        try await again.value
        #expect(lamp.sent == ["on", "on again"])
        #expect(!lamp.overlapped)
    }

    /// An Automation restarted while its write was under way: the write still finishes before the next one goes.
    @Test func aWriteGivenUpOnStillGoesFirst() async throws {
        let order = WriteOrder()
        let lamp = SlowLamp()
        let first = Task { try await order.write("lamp/on") { await lamp.send("on") } }
        #expect(await eventually { lamp.isHeld("on") })
        let off = Task { try await order.write("lamp/on") { await lamp.send("off") } }
        #expect(await eventually { await order.asked["lamp/on"] == 2 })
        first.cancel()
        lamp.release("on")
        #expect(await eventually { lamp.isHeld("off") })
        lamp.release("off")
        try await off.value
        #expect(lamp.sent == ["on", "off"])
        #expect(!lamp.overlapped)
    }

    /// A write whose caller stopped waiting before its turn is not sent.
    @Test func aWriteGivenUpOnBeforeItsTurnIsNotSent() async throws {
        let order = WriteOrder()
        let lamp = SlowLamp()
        let first = Task { try await order.write("lamp/on") { await lamp.send("on") } }
        #expect(await eventually { lamp.isHeld("on") })
        let off = Task { try await order.write("lamp/on") { await lamp.send("off") } }
        #expect(await eventually { await order.asked["lamp/on"] == 2 })
        off.cancel()
        lamp.release("on")
        try await first.value
        await #expect(throws: CancellationError.self) { try await off.value }
        #expect(lamp.sent == ["on"])
    }

    /// Different characteristics do not wait for each other.
    @Test func otherCharacteristicsDoNotWait() async throws {
        let order = WriteOrder()
        let lamp = SlowLamp()
        let on = Task { try await order.write("lamp/on") { await lamp.send("on") } }
        #expect(await eventually { lamp.isHeld("on") })
        let brightness = Task { try await order.write("lamp/brightness") { await lamp.send("50%") } }
        #expect(await eventually { lamp.isHeld("50%") })
        lamp.release("on")
        lamp.release("50%")
        try await on.value
        try await brightness.value
    }
}
