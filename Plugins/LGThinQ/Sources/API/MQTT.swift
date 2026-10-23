import Crypto
import Foundation
import HomeswiftNetwork
import _CryptoExtras

/// The client identity for AWS IoT: a 2048-bit RSA key and a PKCS#10 certificate request for it, which LG
/// signs (`service/users/client/certificate`). The Homebridge plugin builds the CSR with node-forge; this is
/// the same request in DER, subject `CN=AWS IoT Certificate, O=Amazon`, signed with SHA-256.
enum ClientIdentity {
    struct Keys: Codable, Sendable, Equatable {
        var privateKey: String
        var publicKey: String
    }

    static func generateKeys() throws -> Keys {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        return Keys(privateKey: key.pemRepresentation, publicKey: key.publicKey.pemRepresentation)
    }

    /// The certificate request, PEM.
    static func certificationRequest(keys: Keys) throws -> String {
        let privateKey = try _RSA.Signing.PrivateKey(pemRepresentation: keys.privateKey)
        let subjectPublicKeyInfo = try _RSA.Signing.PublicKey(pemRepresentation: keys.publicKey).derRepresentation
        let subject = DER.sequence([
            DER.set([DER.sequence([DER.objectIdentifier([2, 5, 4, 3]), DER.printableString("AWS IoT Certificate")])]),
            DER.set([DER.sequence([DER.objectIdentifier([2, 5, 4, 10]), DER.printableString("Amazon")])]),
        ])
        // version 0, subject, subjectPKInfo, attributes [0] (empty).
        let info = DER.sequence([DER.integer(0), subject, Array(subjectPublicKeyInfo), [0xA0, 0x00]])
        let signature = try privateKey.signature(for: SHA256.hash(data: Data(info)), padding: .insecurePKCS1v1_5)
        let sha256WithRSA = DER.sequence([DER.objectIdentifier([1, 2, 840, 113549, 1, 1, 11]), [0x05, 0x00]])
        let request = DER.sequence([info, sha256WithRSA, DER.bitString(Array(signature.rawRepresentation))])
        return pem(Data(request), label: "CERTIFICATE REQUEST")
    }

    /// The CSR as LG wants it: the base64 body on one line.
    static func stripped(_ csr: String) -> String {
        csr.replacingOccurrences(of: "-----BEGIN CERTIFICATE REQUEST-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE REQUEST-----", with: "")
            .components(separatedBy: .newlines).joined()
    }

    static func pem(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN \(label)-----\r\n" + lines.joined(separator: "\r\n") + "\r\n-----END \(label)-----\r\n"
    }
}

/// The few DER encodings a certificate request needs.
enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tagged(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tagged(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tagged(0x31, items.flatMap { $0 }) }
    static func printableString(_ string: String) -> [UInt8] { tagged(0x13, Array(string.utf8)) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tagged(0x03, [0x00] + bytes) }

    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tagged(0x02, bytes)
    }

    static func objectIdentifier(_ arcs: [UInt]) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var value = arc >> 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            bytes += chunk
        }
        return tagged(0x06, bytes)
    }
}

/// The roots of LG's MQTT brokers, bundled with the plugin: the Homebridge plugin used to download them, one
/// over plain HTTP, which let anyone on the path substitute a root.
enum RootCAs {
    /// Comodo AAA Certificate Services, for LG's own `*.iot.ruic.lgthinq.com`. Expires 2028-12-31.
    static let comodoAAACertificateServices = """
        -----BEGIN CERTIFICATE-----
        MIIEMjCCAxqgAwIBAgIBATANBgkqhkiG9w0BAQUFADB7MQswCQYDVQQGEwJHQjEb
        MBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVyMRAwDgYDVQQHDAdTYWxmb3JkMRow
        GAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEhMB8GA1UEAwwYQUFBIENlcnRpZmlj
        YXRlIFNlcnZpY2VzMB4XDTA0MDEwMTAwMDAwMFoXDTI4MTIzMTIzNTk1OVowezEL
        MAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4GA1UE
        BwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAfBgNVBAMM
        GEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczCCASIwDQYJKoZIhvcNAQEBBQADggEP
        ADCCAQoCggEBAL5AnfRu4ep2hxxNRUSOvkbIgwadwSr+GB+O5AL686tdUIoWMQua
        BtDFcCLNSS1UY8y2bmhGC1Pqy0wkwLxyTurxFa70VJoSCsN6sjNg4tqJVfMiWPPe
        3M/vg4aijJRPn2jymJBGhCfHdr/jzDUsi14HZGWCwEiwqJH5YZ92IFCokcdmtet4
        YgNW8IoaE+oxox6gmf049vYnMlhvB/VruPsUK6+3qszWY19zjNoFmag4qMsXeDZR
        rOme9Hg6jc8P2ULimAyrL58OAd7vn5lJ8S3frHRNG5i1R8XlKdH5kBjHYpy+g8cm
        ez6KJcfA3Z3mNWgQIJ2P2N7Sw4ScDV7oL8kCAwEAAaOBwDCBvTAdBgNVHQ4EFgQU
        oBEKIz6W8Qfs4q8p74Klf9AwpLQwDgYDVR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQF
        MAMBAf8wewYDVR0fBHQwcjA4oDagNIYyaHR0cDovL2NybC5jb21vZG9jYS5jb20v
        QUFBQ2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNqA0oDKGMGh0dHA6Ly9jcmwuY29t
        b2RvLm5ldC9BQUFDZXJ0aWZpY2F0ZVNlcnZpY2VzLmNybDANBgkqhkiG9w0BAQUF
        AAOCAQEACFb8AvCb6P+k+tZ7xkSAzk/ExfYAWMymtrwUSWgEdujm7l3sAg9g1o1Q
        GE8mTgHj5rCl7r+8dFRBv/38ErjHT1r0iWAFf2C3BUrz9vHCv8S5dIa2LX1rzNLz
        Rt0vxuBqw8M0Ayx9lt1awg6nCpnBBYurDC/zXDrPbDdVCYfeU0BsWO/8tqtlbgT2
        G9w84FoVxp7Z8VlIMCFlA2zs6SFz7JsDoeA3raAVGI/6ugLOpyypEBMs1OUIJqsi
        l2D4kF501KKaU73yqWjgom7C12yxow+ev+to51byrvLjKzg6CYG1a4XXvi3tPxq3
        smPi9WIsgtRqAEFQ8TmDn5XpNpaYbg==
        -----END CERTIFICATE-----

        """

    /// VeriSign Class 3 Public Primary Certification Authority - G5, for older endpoints. Expires 2036-07-16.
    static let verisignClass3G5 = """
        -----BEGIN CERTIFICATE-----
        MIIE0zCCA7ugAwIBAgIQGNrRniZ96LtKIVjNzGs7SjANBgkqhkiG9w0BAQUFADCB
        yjELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDlZlcmlTaWduLCBJbmMuMR8wHQYDVQQL
        ExZWZXJpU2lnbiBUcnVzdCBOZXR3b3JrMTowOAYDVQQLEzEoYykgMjAwNiBWZXJp
        U2lnbiwgSW5jLiAtIEZvciBhdXRob3JpemVkIHVzZSBvbmx5MUUwQwYDVQQDEzxW
        ZXJpU2lnbiBDbGFzcyAzIFB1YmxpYyBQcmltYXJ5IENlcnRpZmljYXRpb24gQXV0
        aG9yaXR5IC0gRzUwHhcNMDYxMTA4MDAwMDAwWhcNMzYwNzE2MjM1OTU5WjCByjEL
        MAkGA1UEBhMCVVMxFzAVBgNVBAoTDlZlcmlTaWduLCBJbmMuMR8wHQYDVQQLExZW
        ZXJpU2lnbiBUcnVzdCBOZXR3b3JrMTowOAYDVQQLEzEoYykgMjAwNiBWZXJpU2ln
        biwgSW5jLiAtIEZvciBhdXRob3JpemVkIHVzZSBvbmx5MUUwQwYDVQQDEzxWZXJp
        U2lnbiBDbGFzcyAzIFB1YmxpYyBQcmltYXJ5IENlcnRpZmljYXRpb24gQXV0aG9y
        aXR5IC0gRzUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCvJAgIKXo1
        nmAMqudLO07cfLw8RRy7K+D+KQL5VwijZIUVJ/XxrcgxiV0i6CqqpkKzj/i5Vbex
        t0uz/o9+B1fs70PbZmIVYc9gDaTY3vjgw2IIPVQT60nKWVSFJuUrjxuf6/WhkcIz
        SdhDY2pSS9KP6HBRTdGJaXvHcPaz3BJ023tdS1bTlr8Vd6Gw9KIl8q8ckmcY5fQG
        BO+QueQA5N06tRn/Arr0PO7gi+s3i+z016zy9vA9r911kTMZHRxAy3QkGSGT2RT+
        rCpSx4/VBEnkjWNHiDxpg8v+R70rfk/Fla4OndTRQ8Bnc+MUCH7lP59zuDMKz10/
        NIeWiu5T6CUVAgMBAAGjgbIwga8wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8E
        BAMCAQYwbQYIKwYBBQUHAQwEYTBfoV2gWzBZMFcwVRYJaW1hZ2UvZ2lmMCEwHzAH
        BgUrDgMCGgQUj+XTGoasjY5rw8+AatRIGCx7GS4wJRYjaHR0cDovL2xvZ28udmVy
        aXNpZ24uY29tL3ZzbG9nby5naWYwHQYDVR0OBBYEFH/TZafC3ey78DAJ80M5+gKv
        MzEzMA0GCSqGSIb3DQEBBQUAA4IBAQCTJEowX2LP2BqYLz3q3JktvXf2pXkiOOzE
        p6B4Eq1iDkVwZMXnl2YtmAl+X6/WzChl8gGqCBpH3vn5fJJaCGkgDdk+bW48DW7Y
        5gaRQBi5+MHt39tBquCWIMnNZBU4gcmU7qKEKQsTb47bDN0lAtukixlE0kF6BWlK
        WE9gyn6CagsCqiUXObXbf+eEZSqVir2G3l6BFoMtEMze/aiCKm0oHw0LxOXnGiYZ
        4fQRbxC1lfznQgUy286dUV4otp6F01vvpX1FQHKOtw5rDgb7MzVIcbidJ4vEZV8N
        hnacRHr2lVz2XTIIM6RUthg/aFzyQkqFOFSDX9HoLPKsEdao7WNq
        -----END CERTIFICATE-----

        """

    /// The root that signs a broker's certificate: Amazon Root CA 1 for AWS IoT `*-ats.iot.*.amazonaws.com`.
    static func forMQTTHost(_ host: String) -> TLSOptions.Trust {
        if host.range(of: #"^[^.]+-ats\.iot\.[^.]+\.amazonaws\.com$"#, options: .regularExpression) != nil { return .amazonRootCA1 }
        if host.range(of: #"^[^.]+\.iot\.ruic\.lgthinq\.com$"#, options: .regularExpression) != nil { return .roots(pem: comodoAAACertificateServices) }
        return .roots(pem: verisignClass3G5)
    }
}
