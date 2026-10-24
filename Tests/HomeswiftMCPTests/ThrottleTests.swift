import Foundation
import Testing

@testable import HomeswiftMCP

@Suite struct FailureThrottleTests {
    @Test func slowsAnAddressAfterItsThreshold() {
        let throttle = FailureThrottle(threshold: 2, maxDelay: 3)
        #expect(throttle.failed("a") == .zero)
        #expect(throttle.failed("a") == .seconds(1))
        #expect(throttle.delay(for: "a") == .seconds(1))
        #expect(throttle.delay(for: "b") == .zero)
        throttle.succeeded("a")
        #expect(throttle.delay(for: "a") == .zero)
    }

    /// A scan from ever new addresses keeps the table within its capacity; an address failing now stays in it.
    @Test func staysWithinItsCapacity() {
        let throttle = FailureThrottle(threshold: 2, capacity: 64)
        for index in 0..<1000 {
            throttle.failed("2001:db8::\(index)")
            #expect(throttle.count <= 64)
        }
        for _ in 0..<3 { throttle.failed("attacker") }
        for index in 0..<20 { throttle.failed("2001:db8:1::\(index)") }
        #expect(throttle.delay(for: "attacker") > .zero)
    }
}
