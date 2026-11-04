import Foundation
import Testing

@testable import HomeswiftNetwork

@Suite struct SSDPTests {
    @Test func theSearchRequestIsExact() {
        let request = String(decoding: SSDP.searchRequest(searchTarget: "urn:schemas-upnp-org:device:ZonePlayer:1", mx: 5), as: UTF8.self)
        #expect(request == "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 5\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n")
    }

    @Test func answersAndAnnouncementsAreParsed() throws {
        let answer = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age = 1800\r\nEXT:\r\nLOCATION: http://192.168.1.10:1400/xml/device_description.xml\r\nST: urn:x\r\nUSN: uuid:A::urn:x\r\n\r\n"
        let message = try #require(SSDPMessage.parse(Data(answer.utf8)))
        #expect(message.isSearchResponse && !message.isNotify)
        #expect(message["location"] == "http://192.168.1.10:1400/xml/device_description.xml")
        #expect(message["Cache-Control"] == "max-age = 1800")
        #expect(message["ext"] == "")
        #expect(message.type == "urn:x")
        let alive = try #require(SSDPMessage.parse(Data("NOTIFY * HTTP/1.1\nNT: urn:x\nNTS: ssdp:alive\n".utf8)))
        #expect(alive.isNotify && alive.isAlive && alive.type == "urn:x")
        #expect(SSDPMessage.parse(Data("\r\n\r\n".utf8)) == nil)
        #expect(SSDPMessage.parse(Data([0xFF, 0xFE])) == nil)
    }
}
