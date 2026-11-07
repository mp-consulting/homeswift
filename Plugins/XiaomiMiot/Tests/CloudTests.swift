import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import HomeswiftXiaomiMiot

/// The Xiaomi cloud's arithmetic against docs/clean-room/XiaomiMiot.md section 12's vectors.
@Suite struct CloudTests {
    static let ssecurity = "AAECAwQFBgcICQoLDA0ODw=="
    static let nonce = "AQIDBAUGBwgBsFUV"
    static let signedNonce = "5ep+rMHy/Bph+UDBR3Cb6aW2JDdKFCrVRtJBDO5BLUQ="
    static let data = #"{"getVirtualModel":false,"getHuamiDevices":0}"#

    /// 12.11: RC4 without a drop, and with 1024 bytes dropped.
    @Test func rc4() {
        var plain = RC4(key: Array("Key".utf8))
        #expect(hexString(plain.apply(Array("Plaintext".utf8))) == "bbf316e8d940af0ad3")
        var dropped = RC4(key: Array(0...15), drop: 1024)
        #expect(hexString(dropped.apply(Array("hello rc4 drop".utf8))) == "e264c47a560e03fa95f0e2d11658")
    }

    /// 12.10: the password's hash.
    @Test func passwordHash() {
        #expect(MiCloudSigning.passwordHash("hunter2") == "2AB96390C7DBE3439DE74D0C9B0B1767")
        #expect(MiCloudSigning.passwordHash("p@ss w0rd") == "23DBDF3E325C805DD816B0700C11F831")
    }

    /// 12.7: the nonce, the signed nonce, the path, the hashes, the encrypted parameters and the form body.
    @Test func signing() throws {
        #expect(MiCloudSigning.nonce(random: [1, 2, 3, 4, 5, 6, 7, 8], milliseconds: 1_700_000_000_000) == Self.nonce)
        #expect(MiCloudSigning.signedNonce(ssecurity: Self.ssecurity, nonce: Self.nonce) == Self.signedNonce)
        let url = "https://de.api.io.mi.com/app/home/device_list"
        #expect(MiCloudSigning.path(of: url) == "/home/device_list")
        let hash = MiCloudSigning.hash(path: "/home/device_list", parameters: [("data", Self.data)], signedNonce: Self.signedNonce)
        #expect(hash == "8KEisSlWPUyqxLodoNEAWiatFh4=")
        #expect(MiCloudSigning.encrypt(Self.data, signedNonce: Self.signedNonce) == "J+nVv/2+M4saS0L4nnHnA8E07rvtJlPuNpqvffaY9vFBsK1kE9aB20TZKYuL")
        #expect(MiCloudSigning.encrypt(hash, signedNonce: Self.signedNonce) == "ZID3s/q7Nq4+a1rlq1LsAsJYkZzbI0H/XND8JQ==")
        let signed = try #require(MiCloudSigning.fields(url: url, data: Self.data, ssecurity: Self.ssecurity, nonce: Self.nonce))
        #expect(signed.fields.first { $0.0 == "signature" }?.1 == "Epje01XuZn7xOMBsyOEOqVv9mT8=")
        #expect(URLEncoding.form(signed.fields) == "data=J%2BnVv%2F2%2BM4saS0L4nnHnA8E07rvtJlPuNpqvffaY9vFBsK1kE9aB20TZKYuL&rc4_hash__=ZID3s%2Fq7Nq4%2Ba1rlq1LsAsJYkZzbI0H%2FXND8JQ%3D%3D&signature=Epje01XuZn7xOMBsyOEOqVv9mT8%3D&ssecurity=AAECAwQFBgcICQoLDA0ODw%3D%3D&_nonce=AQIDBAUGBwgBsFUV")
        // Both decrypt back.
        #expect(MiCloudSigning.decrypt("J+nVv/2+M4saS0L4nnHnA8E07rvtJlPuNpqvffaY9vFBsK1kE9aB20TZKYuL", signedNonce: Self.signedNonce).map { String(decoding: $0, as: UTF8.self) } == Self.data)
        // The cloud property path's hash.
        let propertyURL = "https://de.api.io.mi.com/app/miotspec/prop/get"
        #expect(MiCloudSigning.path(of: propertyURL) == "/miotspec/prop/get")
        #expect(MiCloudSigning.hash(path: "/miotspec/prop/get", parameters: [("data", #"{"params":[{"did":"123456789","siid":2,"piid":1}]}"#)],
                                    signedNonce: Self.signedNonce) == "mmXIvfzVMA9wdD9LIqeFCdR+D3M=")
        // The device list's data, in its order.
        #expect(OrderedJSON.object([("getVirtualModel", .value(false)), ("getHuamiDevices", .int(0))]).text == Self.data)
    }

    static let response = "J+nRte2NeMNeEgH5tm3wB8pz9ueuJUupNpq6ffGl7+QO45IjCdaRyhXBSMDUbxg2OLyHUTY74ka9ksHigc8+Kw4DuFMB64W/ldtZcw+NlHA5jItJoLXeINtFvS4mscJFvbELpXGkiVhv1ffd09Sgwcq8EfxsfLlLlltEpTeQWBG12G3ruwLjLTeGcdFtOtmaEqCviRmMSReyKXhIrw/dwVbgXRGeBcsrnoiUQ8EM54FaTvMRH4HSmzRMSY3e7un0WwBQ+3AaAZN0gQdYUTRtVtUezdeq/EfL+br6ARd0mVPBwd+/EiIJ37oboU0hbKqWwaRFKMaWRuh5DSO72MsqBFVGwnG/c47b7gez0vqGeCQTkmCdu9M5z2wnvlpWhYMOTr9dWscacnuvOR9/XuR8/SZ2OhSrhZX8xqtM5r/SjMhl+3NbBLN6H6KKQG4+fysCrz3STbVKKcYcFqGP/f1bOiJ8l19gwQp1YhMeyLEZNUVUUyG13aRLo+OGWZRxT6ablLmisEDsMf8mBOPKDZgiR4MzO8HpMfy9QpwAteIqihtUpkCKR95BMGcxoW7Q4hHbpbQQiDShdG5TD5slIaDR19Q9MLyyMl8Z0TfSQHcSnB5NAdQSM5vUGwLETlI9cdbbLC6XWDtOyjYN2DoiK/oOdqy0fxiFgiy3VUCArbnqDgm9wESZTLEunE1JrZFzChtkc2OPMTU9buXAwg54fP2aZOkQY82Wl4W9AH0vtApQFQA9yocle9Kt5eJ/oEKf9iVbNU78YjLYl3HgdcYI22dAo7l+lC+jUUvIvdEu+tFjXRwqhdUEwT8MYmreOz1P32lwOll98eLgo0JSGDEEPwH30BHr"

    /// 12.8: the response decrypts to the device list, whose entry is one Discovered Device with its MAC as serial number.
    @Test func responseDecryption() throws {
        let plain = try #require(MiCloudSigning.decrypt(Self.response, signedNonce: Self.signedNonce))
        let json = try JSONValue(data: plain)
        #expect(json["code"]?.intValue == 0)
        let device = try #require(json["result"]?["list"]?[0].flatMap(CloudDevice.init(json:)))
        #expect(device.did == "123456789")
        #expect(device.token == "00112233445566778899aabbccddeeff")
        #expect(device.name == "Desk Lamp")
        #expect(device.model == "yeelink.light.colorc")
        #expect(device.ip == "192.168.1.50")
        #expect(device.serialNumber == "AABBCCDDEE01")
        #expect(device.firmware == "2.1.8_0042")
        #expect(!device.isOutOfScope)
        #expect(MiotSpec.kind(model: device.model ?? "") == "light")
    }

    /// 12.9 (reference only): the legacy unsigned form's signature.
    @Test func legacySignature() {
        #expect(MiCloudSigning.legacySignature(path: "/home/device_list", signedNonce: Self.signedNonce, nonce: Self.nonce, data: Self.data)
            == "JbxFY1bUVgANhq7Ncm2kpKLkJUFoszxRc0Y4TO1X3CM=")
    }

    /// Section 10: what the account lists that is out of scope.
    /// The sign-in's cookies only go to Xiaomi's hosts over HTTPS.
    @Test func xiaomiHosts() {
        #expect(MiCloud.isXiaomiHTTPS("https://account.xiaomi.com/identity/result/check"))
        #expect(MiCloud.isXiaomiHTTPS("https://sts.api.io.mi.com/sts?ticket=1"))
        #expect(!MiCloud.isXiaomiHTTPS("http://account.xiaomi.com/pass"))
        #expect(!MiCloud.isXiaomiHTTPS("https://xiaomi.com.example.net/"))
        #expect(!MiCloud.isXiaomiHTTPS("https://evilmi.com/"))
    }

    @Test func outOfScope() throws {
        func device(_ fields: [String: JSONValue]) -> CloudDevice {
            var base: [String: JSONValue] = ["did": "1", "localip": "192.168.1.9", "ssid": "Home", "model": "zhimi.fan.za5"]
            base.merge(fields) { $1 }
            return CloudDevice(json: .object(base))!
        }
        #expect(!device([:]).isOutOfScope)
        #expect(device(["did": "blt.3.abc"]).isOutOfScope)
        #expect(device(["parent_id": "12345"]).isOutOfScope)
        #expect(device(["localip": ""]).isOutOfScope)
        #expect(device(["ssid": ""]).isOutOfScope)
        #expect(device(["model": "chuangmi.ir.v2"]).isOutOfScope)
        #expect(MiotSpec.needsCloud(model: "zhimi.airpurifier.m1"))
        #expect(!MiotSpec.needsCloud(model: "zhimi.airpurifier.ma4"))
    }

    /// `&&&START&&&` and a JSONP wrapper are taken off an account response.
    @Test func accountResponses() {
        #expect(MiCloud.accountJSON(Data(#"&&&START&&&{"code":0}"#.utf8))?["code"]?.intValue == 0)
        #expect(MiCloud.accountJSON(Data(#"callback({"code":1})"#.utf8))?["code"]?.intValue == 1)
        let response = HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Set-Cookie", "serviceToken=abc==; Path=/; Domain=.mi.com"), ("set-cookie", "userId=42; Path=/")])
        #expect(MiCloud.cookies(from: response) == ["serviceToken": "abc==", "userId": "42"])
        #expect(MiCloud.apiBase(country: "cn") == "https://api.io.mi.com/app")
        #expect(MiCloud.apiBase(country: "de") == "https://de.api.io.mi.com/app")
    }
}
