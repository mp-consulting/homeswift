import Crypto
import Foundation
import HomeswiftNetwork

/// What DTLS runs over: datagrams out, datagrams in. `ICEDemultiplexer.dtls` gives the ICE agent's DTLS share,
/// `UDPPeerTransport` a plain socket.
public protocol DatagramTransport: Sendable {
    func send(_ datagram: [UInt8]) async throws
    var incoming: AsyncStream<[UInt8]> { get }
}

/// DTLS 1.2 (RFC 6347) with DTLS-SRTP (RFC 5764), written from the RFCs, for a WebRTC peer: one cipher suite this side
/// signs with, TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 (as a client it also accepts TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
/// from an RSA server), P-256 ECDHE, extended master secret (RFC 7627), use_srtp with SRTP_AES128_CM_HMAC_SHA1_80, and
/// mutual authentication by certificate as WebRTC has it: the peer's certificate is checked against the SHA-256
/// fingerprint from its SDP, never by chain.
///
/// Records carry an epoch and a 48-bit sequence number, several to a datagram; handshake messages are fragmented to
/// the MTU and reassembled; the last flight is sent again when the timer runs out (1 s, doubling, a bounded number of
/// times) or when the peer repeats its own; a server answers the first ClientHello with a stateless HelloVerifyRequest
/// cookie (an HMAC of the hello). No anti-replay window. Keys, secrets and handshake bodies never reach a log.
public actor DTLSTransport {
    public let role: DTLSRole
    public let certificate: DTLSCertificate
    /// Application data after the handshake (SCTP, for a data channel).
    public nonisolated let received: AsyncStream<[UInt8]>
    private let receivedContinuation: AsyncStream<[UInt8]>.Continuation

    private let transport: any DatagramTransport
    private let remoteFingerprint: [UInt8]?
    private let mtu: Int
    private let retransmitTimeout: Duration
    private let maximumRetransmissions: Int

    private enum Phase {
        case idle, handshaking, connected, failed(DTLSError), closed
    }

    private enum Step {
        // Client
        case awaitServerHello, awaitCertificate, awaitServerKeyExchange, awaitCertificateRequestOrDone, awaitServerHelloDone
        // Server
        case awaitClientHello, awaitClientCertificate, awaitClientKeyExchange, awaitCertificateVerify
        // Both
        case awaitFinished, done
    }

    private enum FlightItem {
        case handshake(HandshakeMessage, epoch: UInt16)
        case changeCipherSpec
    }

    private var phase: Phase = .idle
    private var step: Step

    // Records
    private var writeEpoch: UInt16 = 0
    private var writeSequence: [UInt16: UInt64] = [0: 0, 1: 0]
    private var writeCiphers: [UInt16: DTLSRecordCipher] = [:]
    private var readEpoch: UInt16 = 0
    private var readCipher: DTLSRecordCipher?
    private var pendingReadCipher: DTLSRecordCipher?
    private var futureRecords: [DTLSRecord] = []

    // Handshake
    private var reassembler = HandshakeReassembler()
    private var nextSendSeq: UInt16 = 0
    private var nextReceiveSeq: UInt16 = 0
    private var transcript: [UInt8] = []
    private var clientRandom: [UInt8] = []
    private var serverRandom: [UInt8] = []
    private var clientHello: ClientHello?
    private var cipherSuite: UInt16 = DTLSConstants.ecdheECDSAAES128GCMSHA256
    private var extendedMasterSecret = false
    private var ecdhKey = P256.KeyAgreement.PrivateKey()
    private var peerPoint: [UInt8] = []
    private var peerKey: PeerPublicKey?
    private var certificateRequested = false
    private var masterSecret: [UInt8] = []
    private var lastClientHelloRecordSeq: UInt64 = 0
    private let cookieSecret = SymmetricKey(size: .bits256)

    // Retransmission
    private var lastFlight: [FlightItem] = []
    private var timer: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    private var keys: SRTPKeys?
    private var waiters: [CheckedContinuation<SRTPKeys, any Error>] = []

    /// `remoteFingerprint` is the peer's `a=fingerprint:sha-256` value (`AA:BB:…`). `mtu` bounds each datagram;
    /// `retransmitTimeout` is the first wait before a flight is sent again (RFC 6347 suggests 1 s), doubled each time,
    /// `maximumRetransmissions` times at most.
    public init(
        role: DTLSRole, certificate: DTLSCertificate, remoteFingerprint: String, transport: any DatagramTransport, mtu: Int = 1200,
        retransmitTimeout: Duration = .seconds(1), maximumRetransmissions: Int = 6
    ) {
        self.role = role
        self.certificate = certificate
        self.remoteFingerprint = DTLSCertificate.fingerprintBytes(remoteFingerprint)
        self.transport = transport
        self.mtu = max(mtu, 128)
        self.retransmitTimeout = retransmitTimeout
        self.maximumRetransmissions = maximumRetransmissions
        step = role == .client ? .awaitServerHello : .awaitClientHello
        (received, receivedContinuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .bufferingNewest(512))
    }

    /// Runs the handshake (once; later calls wait for the same one) and returns the SRTP keys it exports. Fails on a
    /// fingerprint mismatch, a fatal alert, a bad signature or Finished, or when `timeout` passes first.
    public func handshake(timeout: Duration = .seconds(20)) async throws -> SRTPKeys {
        switch phase {
        case .connected: if let keys { return keys }
        case .failed(let error): throw error
        case .closed: throw DTLSError.closed
        case .handshaking: break
        case .idle:
            phase = .handshaking
            let stream = transport.incoming
            reader = Task { [weak self] in
                for await datagram in stream { await self?.handle(datagram: datagram) }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.fail(.timeout, alert: nil)
            }
            if role == .client { await sendClientHello(cookie: []) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let keys {
                    continuation.resume(returning: keys)
                } else if case .failed(let error) = phase {
                    continuation.resume(throwing: error)
                } else {
                    waiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.fail(.closed, alert: nil) }
        }
    }

    /// Sends application data (one record) once the handshake has completed.
    public func send(application data: [UInt8]) async throws {
        guard case .connected = phase else { throw DTLSError.notConnected }
        let record = try makeRecord(type: DTLSConstants.ContentType.applicationData, epoch: 1, plaintext: data)
        try await transport.send(record)
    }

    /// Sends close_notify when connected and stops.
    public func close() async {
        if case .connected = phase, let alert = try? makeRecord(type: DTLSConstants.ContentType.alert, epoch: 1, plaintext: [1, DTLSConstants.Alert.closeNotify]) {
            try? await transport.send(alert)
        }
        finish(.closed)
        phase = .closed
    }

    // MARK: Ending

    private func fail(_ error: DTLSError, alert: UInt8?) async {
        guard case .handshaking = phase else {
            if case .idle = phase { phase = .failed(error) }
            return
        }
        if let alert, let record = try? makeRecord(type: DTLSConstants.ContentType.alert, epoch: writeEpoch, plaintext: [2, alert]) {
            try? await transport.send(record)
        }
        phase = .failed(error)
        finish(error)
    }

    private func finish(_ error: DTLSError) {
        timer?.cancel()
        deadline?.cancel()
        reader?.cancel()
        receivedContinuation.finish()
        for waiter in waiters { waiter.resume(throwing: error) }
        waiters = []
    }

    private func complete() {
        let material = TLSPRF.prf(secret: masterSecret, label: SRTPKeys.exporterLabel, seed: clientRandom + serverRandom, length: SRTPKeys.length)
        let exported = SRTPKeys(material: material, role: role)
        keys = exported
        phase = .connected
        step = .done
        timer?.cancel()
        deadline?.cancel()
        for waiter in waiters { waiter.resume(returning: exported) }
        waiters = []
    }

    // MARK: Records out

    private func makeRecord(type: UInt8, epoch: UInt16, plaintext: [UInt8]) throws -> [UInt8] {
        let sequence = writeSequence[epoch, default: 0]
        writeSequence[epoch] = sequence + 1
        var record = DTLSRecord(type: type, version: DTLSConstants.version, epoch: epoch, sequence: sequence, fragment: plaintext)
        if epoch > 0 {
            guard let cipher = writeCiphers[epoch] else { throw DTLSError.notConnected }
            record.fragment = try cipher.seal(plaintext, sequence: record.sequenceBytes, type: type, version: record.version)
        }
        return record.encode()
    }

    /// Sends a flight: each handshake message cut to fit the MTU, records packed into as few datagrams as fit, each
    /// record with a fresh sequence number (a retransmission too).
    private func send(flight: [FlightItem]) async {
        var datagrams: [[UInt8]] = []
        var current: [UInt8] = []
        func add(_ record: [UInt8]) {
            if !current.isEmpty, current.count + record.count > mtu {
                datagrams.append(current)
                current = []
            }
            current += record
        }
        for item in flight {
            switch item {
            case .changeCipherSpec:
                if let record = try? makeRecord(type: DTLSConstants.ContentType.changeCipherSpec, epoch: 0, plaintext: [1]) { add(record) }
            case .handshake(let message, let epoch):
                let room = mtu - DTLSConstants.recordHeaderLength - DTLSConstants.handshakeHeaderLength - (epoch > 0 ? DTLSRecordCipher.overhead : 0)
                for fragment in message.fragments(maximum: room) {
                    if let record = try? makeRecord(type: DTLSConstants.ContentType.handshake, epoch: epoch, plaintext: fragment.encode()) { add(record) }
                }
            }
        }
        if !current.isEmpty { datagrams.append(current) }
        for datagram in datagrams { try? await transport.send(datagram) }
    }

    private func sendNewFlight(_ flight: [FlightItem], retransmit: Bool = true) async {
        lastFlight = flight
        timer?.cancel()
        if retransmit {
            let initial = retransmitTimeout, maximum = maximumRetransmissions
            timer = Task { [weak self] in
                var wait = initial
                for _ in 0..<maximum {
                    do { try await Task.sleep(for: wait) } catch { return }
                    guard let self, await self.retransmitIfWaiting() else { return }
                    wait = min(wait * 2, .seconds(60))
                }
                do { try await Task.sleep(for: wait) } catch { return }
                await self?.fail(.timeout, alert: nil)
            }
        }
        await send(flight: flight)
    }

    private func retransmitIfWaiting() async -> Bool {
        guard case .handshaking = phase else { return false }
        await send(flight: lastFlight)
        return true
    }

    private func message(_ type: UInt8, _ body: [UInt8]) -> HandshakeMessage {
        defer { nextSendSeq &+= 1 }
        return HandshakeMessage(type: type, messageSeq: nextSendSeq, body: body)
    }

    // MARK: Records in

    private func handle(datagram: [UInt8]) async {
        // RFC 7983: only 20-63 is DTLS.
        guard let first = datagram.first, (20...63).contains(first) else { return }
        var duplicate = false
        for record in DTLSRecord.decodeAll(datagram) {
            if await handle(record: record) { duplicate = true }
        }
        if duplicate {
            switch phase {
            case .handshaking where step != .awaitClientHello: await send(flight: lastFlight)
            case .connected where role == .server: await send(flight: lastFlight)
            default: break
            }
        }
        await processMessages()
    }

    /// Takes one record in; true when it repeats a handshake message already processed (the peer lost this side's flight).
    private func handle(record: DTLSRecord) async -> Bool {
        guard record.version == DTLSConstants.version || record.version == DTLSConstants.version10 else { return false }
        if record.epoch > readEpoch {
            if record.epoch == readEpoch + 1, futureRecords.count < 16 { futureRecords.append(record) }
            return false
        }
        if record.epoch < readEpoch { return record.type == DTLSConstants.ContentType.handshake }
        var plaintext = record.fragment
        if record.epoch > 0 {
            guard let readCipher, let opened = try? readCipher.open(record.fragment, sequence: record.sequenceBytes, type: record.type, version: record.version) else {
                return false  // forged or damaged: dropped silently (RFC 6347 section 4.1.2.1)
            }
            plaintext = opened
        }
        switch record.type {
        case DTLSConstants.ContentType.changeCipherSpec:
            guard readEpoch == 0, let pendingReadCipher, plaintext == [1] else { return false }
            readCipher = pendingReadCipher
            self.pendingReadCipher = nil
            readEpoch = 1
            let buffered = futureRecords
            futureRecords = []
            var duplicate = false
            for record in buffered where await handle(record: record) { duplicate = true }
            return duplicate
        case DTLSConstants.ContentType.alert:
            guard plaintext.count >= 2 else { return false }
            if plaintext[1] == DTLSConstants.Alert.closeNotify {
                if case .handshaking = phase { await fail(.closed, alert: nil) } else { finish(.closed); phase = .closed }
            } else if plaintext[0] == 2 {
                if case .handshaking = phase { await fail(.alert(level: plaintext[0], description: plaintext[1]), alert: nil) } else {
                    finish(.closed)
                    phase = .closed
                }
            }
            return false
        case DTLSConstants.ContentType.handshake:
            guard let fragments = try? HandshakeFragment.decodeAll(plaintext) else { return false }
            var duplicate = false
            for fragment in fragments {
                if fragment.messageSeq < nextReceiveSeq {
                    duplicate = true
                } else if fragment.messageSeq < nextReceiveSeq &+ 16 {
                    // Finished only ever comes encrypted.
                    if fragment.type == DTLSConstants.HandshakeType.finished, record.epoch == 0 { continue }
                    if fragment.type == DTLSConstants.HandshakeType.clientHello { lastClientHelloRecordSeq = record.sequence }
                    reassembler.add(fragment)
                }
            }
            return duplicate
        case DTLSConstants.ContentType.applicationData:
            if case .connected = phase, record.epoch == 1 { receivedContinuation.yield(plaintext) }
            return false
        default:
            return false
        }
    }

    private func processMessages() async {
        while case .handshaking = phase {
            let next = step == .awaitClientHello
                ? reassembler.takeFirstComplete(type: DTLSConstants.HandshakeType.clientHello)
                : reassembler.take(nextReceiveSeq)
            guard let message = next else { return }
            if step != .awaitClientHello { nextReceiveSeq = message.messageSeq &+ 1 }
            do {
                try await process(message)
            } catch let error as DTLSError {
                await fail(error, alert: Self.alert(for: error))
            } catch {
                await fail(.decodeError, alert: DTLSConstants.Alert.decodeError)
            }
        }
    }

    private static func alert(for error: DTLSError) -> UInt8 {
        switch error {
        case .fingerprintMismatch, .badCertificate, .unsupportedCertificate, .missingCertificate: DTLSConstants.Alert.badCertificate
        case .badSignature, .badFinished: DTLSConstants.Alert.decryptError
        case .decodeError: DTLSConstants.Alert.decodeError
        case .unexpectedMessage: DTLSConstants.Alert.unexpectedMessage
        default: DTLSConstants.Alert.handshakeFailure
        }
    }

    // MARK: The handshake

    private func process(_ message: HandshakeMessage) async throws {
        typealias H = DTLSConstants.HandshakeType
        switch (step, message.type) {
        // Client
        case (.awaitServerHello, H.helloVerifyRequest):
            var reader = TLSReader(message.body)
            _ = try reader.u16()
            let cookie = try reader.vector8()
            // Neither the first ClientHello nor the HelloVerifyRequest is in the transcript (RFC 6347 section 4.2.1).
            transcript = []
            await sendClientHello(cookie: cookie)
        case (.awaitServerHello, H.serverHello):
            let hello = try ServerHello(message.body)
            guard [DTLSConstants.ecdheECDSAAES128GCMSHA256, DTLSConstants.ecdheRSAAES128GCMSHA256].contains(hello.cipherSuite),
                  hello.compressionMethod == 0 else { throw DTLSError.noSharedCipherSuite }
            guard let srtp = hello.extensions[DTLSConstants.Extension.useSRTP],
                  try TLSExtensions.srtpProfiles(srtp) == [DTLSConstants.srtpAES128CMSHA1_80] else { throw DTLSError.noSRTPProfile }
            extendedMasterSecret = hello.extensions[DTLSConstants.Extension.extendedMasterSecret] != nil
            serverRandom = hello.random
            cipherSuite = hello.cipherSuite
            transcript += message.transcriptBytes
            step = .awaitCertificate
        case (.awaitCertificate, H.certificate):
            peerKey = try checkCertificate(message.body)
            switch peerKey {
            case .p256?: guard cipherSuite == DTLSConstants.ecdheECDSAAES128GCMSHA256 else { throw DTLSError.unsupportedCertificate }
            case .rsa?: guard cipherSuite == DTLSConstants.ecdheRSAAES128GCMSHA256 else { throw DTLSError.unsupportedCertificate }
            case nil: throw DTLSError.badCertificate
            }
            transcript += message.transcriptBytes
            step = .awaitServerKeyExchange
        case (.awaitServerKeyExchange, H.serverKeyExchange):
            var reader = TLSReader(message.body)
            guard try reader.u8() == 3, try reader.u16() == DTLSConstants.secp256r1 else { throw DTLSError.noSharedCipherSuite }
            peerPoint = try reader.vector8()
            let params = Array(message.body[0..<reader.index])
            let scheme = try reader.u16()
            let signature = try reader.vector16()
            guard let peerKey, peerKey.schemes.contains(scheme),
                  peerKey.verify(scheme: scheme, signature: signature, data: clientRandom + serverRandom + params) else { throw DTLSError.badSignature }
            transcript += message.transcriptBytes
            step = .awaitCertificateRequestOrDone
        case (.awaitCertificateRequestOrDone, H.certificateRequest):
            var reader = TLSReader(message.body)
            _ = try reader.vector8()  // certificate types
            _ = try reader.vector16()  // signature algorithms: this side signs ecdsa_secp256r1_sha256 whatever they say
            _ = try reader.vector16()  // certificate authorities
            certificateRequested = true
            transcript += message.transcriptBytes
            step = .awaitServerHelloDone
        case (.awaitCertificateRequestOrDone, H.serverHelloDone), (.awaitServerHelloDone, H.serverHelloDone):
            transcript += message.transcriptBytes
            try await sendClientFlight()
        case (.awaitFinished, H.finished):
            let peerLabel = role == .client ? "server finished" : "client finished"
            let expected = TLSPRF.prf(secret: masterSecret, label: peerLabel, seed: Array(SHA256.hash(data: transcript)), length: 12)
            guard Secrets.constantTimeEqual(expected, message.body) else { throw DTLSError.badFinished }
            transcript += message.transcriptBytes
            if role == .server {
                let verify = TLSPRF.prf(secret: masterSecret, label: "server finished", seed: Array(SHA256.hash(data: transcript)), length: 12)
                let finished = self.message(H.finished, verify)
                writeEpoch = 1
                // No timer for the last flight: it goes again when the client repeats its own.
                await sendNewFlight([.changeCipherSpec, .handshake(finished, epoch: 1)], retransmit: false)
            }
            complete()

        // Server
        case (.awaitClientHello, H.clientHello):
            try await receiveClientHello(message)
        case (.awaitClientCertificate, H.certificate):
            peerKey = try checkCertificate(message.body)
            transcript += message.transcriptBytes
            step = .awaitClientKeyExchange
        case (.awaitClientKeyExchange, H.clientKeyExchange):
            var reader = TLSReader(message.body)
            peerPoint = try reader.vector8()
            transcript += message.transcriptBytes
            try deriveKeys()
            step = .awaitCertificateVerify
        case (.awaitCertificateVerify, H.certificateVerify):
            var reader = TLSReader(message.body)
            let scheme = try reader.u16()
            let signature = try reader.vector16()
            guard let peerKey, peerKey.schemes.contains(scheme), peerKey.verify(scheme: scheme, signature: signature, data: transcript) else {
                throw DTLSError.badSignature
            }
            transcript += message.transcriptBytes
            step = .awaitFinished
        default:
            throw DTLSError.unexpectedMessage(message.type)
        }
    }

    /// The peer's certificate chain: its first certificate must have the SDP's fingerprint.
    private func checkCertificate(_ body: [UInt8]) throws -> PeerPublicKey {
        var reader = TLSReader(body)
        var list = TLSReader(try reader.vector24())
        guard !list.isAtEnd else { throw DTLSError.missingCertificate }
        let leaf = try list.vector24()
        guard let remoteFingerprint, Secrets.constantTimeEqual(Array(SHA256.hash(data: leaf)), remoteFingerprint) else {
            throw DTLSError.fingerprintMismatch
        }
        return try PeerPublicKey(certificate: leaf)
    }

    private var certificateMessageBody: [UInt8] {
        var list = TLSWriter()
        list.vector24(certificate.der)
        var writer = TLSWriter()
        writer.vector24(list.bytes)
        return writer.bytes
    }

    /// The pre-master secret from ECDHE, the master secret (extended when both offered it), the key block and the
    /// record ciphers: this side's for epoch 1, the peer's waiting for its ChangeCipherSpec.
    private func deriveKeys() throws {
        guard peerPoint.count == 65, let peer = try? P256.KeyAgreement.PublicKey(x963Representation: peerPoint) else { throw DTLSError.decodeError }
        let shared = try ecdhKey.sharedSecretFromKeyAgreement(with: peer)
        let preMaster = shared.withUnsafeBytes { Array($0) }
        masterSecret = extendedMasterSecret
            ? TLSPRF.prf(secret: preMaster, label: "extended master secret", seed: Array(SHA256.hash(data: transcript)), length: 48)
            : TLSPRF.prf(secret: preMaster, label: "master secret", seed: clientRandom + serverRandom, length: 48)
        let block = TLSPRF.prf(secret: masterSecret, label: "key expansion", seed: serverRandom + clientRandom, length: 40)
        let client = DTLSRecordCipher(key: Array(block[0..<16]), salt: Array(block[32..<36]))
        let server = DTLSRecordCipher(key: Array(block[16..<32]), salt: Array(block[36..<40]))
        writeCiphers[1] = role == .client ? client : server
        pendingReadCipher = role == .client ? server : client
    }

    // MARK: Client flights

    private func sendClientHello(cookie: [UInt8]) async {
        if clientRandom.isEmpty { clientRandom = Self.random() }
        let extensions = TLSExtensions([
            (DTLSConstants.Extension.renegotiationInfo, [0]),
            (DTLSConstants.Extension.extendedMasterSecret, []),
            (DTLSConstants.Extension.supportedGroups, TLSExtensions.u16Vector([DTLSConstants.secp256r1])),
            (DTLSConstants.Extension.ecPointFormats, [1, 0]),
            (DTLSConstants.Extension.signatureAlgorithms, TLSExtensions.u16Vector(DTLSConstants.signatureSchemes)),
            (DTLSConstants.Extension.useSRTP, TLSExtensions.useSRTP([DTLSConstants.srtpAES128CMSHA1_80])),
        ])
        let hello = ClientHello(random: clientRandom, cookie: cookie,
                                cipherSuites: [DTLSConstants.ecdheECDSAAES128GCMSHA256, DTLSConstants.ecdheRSAAES128GCMSHA256], extensions: extensions)
        clientHello = hello
        let message = self.message(DTLSConstants.HandshakeType.clientHello, hello.encode())
        // The server's answer carries the ClientHello's message_seq (HelloVerifyRequest) or the next (RFC 6347 4.2.2).
        nextReceiveSeq = message.messageSeq
        reassembler.discard(below: nextReceiveSeq)
        transcript = message.transcriptBytes
        await sendNewFlight([.handshake(message, epoch: 0)])
    }

    /// Certificate, ClientKeyExchange, CertificateVerify, ChangeCipherSpec, Finished.
    private func sendClientFlight() async throws {
        typealias H = DTLSConstants.HandshakeType
        var flight: [FlightItem] = []
        if certificateRequested {
            let message = message(H.certificate, certificateMessageBody)
            transcript += message.transcriptBytes
            flight.append(.handshake(message, epoch: 0))
        }
        var exchange = TLSWriter()
        exchange.vector8(Array(ecdhKey.publicKey.x963Representation))
        let keyExchange = message(H.clientKeyExchange, exchange.bytes)
        transcript += keyExchange.transcriptBytes
        flight.append(.handshake(keyExchange, epoch: 0))
        try deriveKeys()
        if certificateRequested {
            let signature = try certificate.privateKey.signature(for: transcript)
            var body = TLSWriter()
            body.u16(DTLSConstants.ecdsaP256SHA256)
            body.vector16(Array(signature.derRepresentation))
            let verify = message(H.certificateVerify, body.bytes)
            transcript += verify.transcriptBytes
            flight.append(.handshake(verify, epoch: 0))
        }
        let verifyData = TLSPRF.prf(secret: masterSecret, label: "client finished", seed: Array(SHA256.hash(data: transcript)), length: 12)
        let finished = message(H.finished, verifyData)
        transcript += finished.transcriptBytes
        flight += [.changeCipherSpec, .handshake(finished, epoch: 1)]
        writeEpoch = 1
        step = .awaitFinished
        await sendNewFlight(flight)
    }

    // MARK: Server flights

    private func cookie(for hello: ClientHello) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: hello.cookieInput, using: cookieSecret))
    }

    private func receiveClientHello(_ message: HandshakeMessage) async throws {
        typealias H = DTLSConstants.HandshakeType
        let hello = try ClientHello(message.body)
        let expected = cookie(for: hello)
        guard Secrets.constantTimeEqual(hello.cookie, expected) else {
            // Stateless: answer with a cookie and forget the hello. The HelloVerifyRequest takes the ClientHello's
            // record sequence number and message_seq (RFC 6347 section 4.2.1).
            reassembler.removeAll()
            var body = TLSWriter()
            body.u16(DTLSConstants.version10)
            body.vector8(expected)
            let verify = HandshakeMessage(type: H.helloVerifyRequest, messageSeq: message.messageSeq, body: body.bytes)
            writeSequence[0] = lastClientHelloRecordSeq
            await send(flight: [.handshake(verify, epoch: 0)])
            writeSequence[0] = max(writeSequence[0, default: 0], lastClientHelloRecordSeq + 1)
            return
        }
        guard hello.cipherSuites.contains(DTLSConstants.ecdheECDSAAES128GCMSHA256), hello.compressionMethods.contains(0) else {
            throw DTLSError.noSharedCipherSuite
        }
        if let groups = hello.extensions[DTLSConstants.Extension.supportedGroups] {
            guard try TLSExtensions.u16List(groups).contains(DTLSConstants.secp256r1) else { throw DTLSError.noSharedCipherSuite }
        }
        guard let schemes = hello.extensions[DTLSConstants.Extension.signatureAlgorithms],
              try TLSExtensions.u16List(schemes).contains(DTLSConstants.ecdsaP256SHA256) else { throw DTLSError.noSharedCipherSuite }
        guard let srtp = hello.extensions[DTLSConstants.Extension.useSRTP],
              try TLSExtensions.srtpProfiles(srtp).contains(DTLSConstants.srtpAES128CMSHA1_80) else { throw DTLSError.noSRTPProfile }
        extendedMasterSecret = hello.extensions[DTLSConstants.Extension.extendedMasterSecret] != nil
        let secureRenegotiation = hello.extensions[DTLSConstants.Extension.renegotiationInfo] != nil || hello.cipherSuites.contains(0x00ff)
        clientHello = hello
        clientRandom = hello.random
        serverRandom = Self.random()
        reassembler.discard(below: message.messageSeq &+ 1)
        nextReceiveSeq = message.messageSeq &+ 1
        nextSendSeq = message.messageSeq
        transcript = message.transcriptBytes

        var extensions: [(type: UInt16, data: [UInt8])] = []
        if secureRenegotiation { extensions.append((DTLSConstants.Extension.renegotiationInfo, [0])) }
        if extendedMasterSecret { extensions.append((DTLSConstants.Extension.extendedMasterSecret, [])) }
        extensions.append((DTLSConstants.Extension.useSRTP, TLSExtensions.useSRTP([DTLSConstants.srtpAES128CMSHA1_80])))
        if hello.extensions[DTLSConstants.Extension.ecPointFormats] != nil { extensions.append((DTLSConstants.Extension.ecPointFormats, [1, 0])) }
        let serverHello = self.message(H.serverHello, ServerHello(random: serverRandom, cipherSuite: DTLSConstants.ecdheECDSAAES128GCMSHA256,
                                                                  extensions: TLSExtensions(extensions)).encode())
        let certificateMessage = self.message(H.certificate, certificateMessageBody)

        var params = TLSWriter()
        params.u8(3)  // named_curve
        params.u16(DTLSConstants.secp256r1)
        params.vector8(Array(ecdhKey.publicKey.x963Representation))
        let signature = try certificate.privateKey.signature(for: clientRandom + serverRandom + params.bytes)
        var keyExchange = params
        keyExchange.u16(DTLSConstants.ecdsaP256SHA256)
        keyExchange.vector16(Array(signature.derRepresentation))
        let serverKeyExchange = self.message(H.serverKeyExchange, keyExchange.bytes)

        var request = TLSWriter()
        request.vector8([64, 1])  // ecdsa_sign, rsa_sign
        request.vector16(DTLSConstants.signatureSchemes.flatMap { STUNMessage.be16($0) })
        request.vector16([])
        let certificateRequest = self.message(H.certificateRequest, request.bytes)
        let done = self.message(H.serverHelloDone, [])

        let flight = [serverHello, certificateMessage, serverKeyExchange, certificateRequest, done]
        for message in flight { transcript += message.transcriptBytes }
        step = .awaitClientCertificate
        await sendNewFlight(flight.map { .handshake($0, epoch: 0) })
    }

    private static func random() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }
}

/// A plain UDP socket as a DTLS transport to one peer: the one given, or the first that sends when none is.
public actor UDPPeerTransport: DatagramTransport {
    private let socket: UDPSocket
    private var remote: (host: String, port: Int)?
    public nonisolated let incoming: AsyncStream<[UInt8]>
    private var forwarder: Task<Void, Never>?
    private var remoteWaiters: [CheckedContinuation<Void, Never>] = []

    /// `socket` must be bound with `senderPorts: true`.
    public init(socket: UDPSocket, remoteHost: String? = nil, remotePort: Int? = nil) {
        self.socket = socket
        if let remoteHost, let remotePort { remote = (remoteHost, remotePort) }
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .bufferingNewest(512))
        incoming = stream
        let datagrams = socket.datagramsWithPorts
        Task { [weak self] in
            await self?.start(datagrams: datagrams, continuation: continuation)
        }
    }

    private func start(datagrams: AsyncStream<UDPSocket.Datagram>, continuation: AsyncStream<[UInt8]>.Continuation) {
        forwarder = Task { [weak self] in
            for await datagram in datagrams {
                guard let self else { break }
                if await self.accept(from: datagram.address, port: datagram.port) { continuation.yield(Array(datagram.data)) }
            }
            continuation.finish()
        }
    }

    private func accept(from host: String, port: Int) -> Bool {
        guard let remote else {
            remote = (host, port)
            for waiter in remoteWaiters { waiter.resume() }
            remoteWaiters = []
            return true
        }
        return remote.host == host && remote.port == port
    }

    public func send(_ datagram: [UInt8]) async throws {
        if remote == nil { await withCheckedContinuation { remoteWaiters.append($0) } }
        guard let remote else { throw DTLSError.notConnected }
        try await socket.send(Data(datagram), to: remote.host, port: remote.port)
    }

    public func close() async {
        forwarder?.cancel()
        for waiter in remoteWaiters { waiter.resume() }
        remoteWaiters = []
        await socket.close()
    }
}

/// Splits what the ICE agent's selected pair receives as RFC 7983 says by the first byte: 20-63 is DTLS (to `dtls`),
/// 128-191 RTP and RTCP (to `media`); the rest (ZRTP, TURN channels) is dropped. STUN never reaches it.
public final class ICEDemultiplexer: Sendable {
    public enum Kind: Equatable, Sendable {
        case stun, dtls, media, other
    }

    public static func classify(_ firstByte: UInt8) -> Kind {
        switch firstByte {
        case 0...3: .stun
        case 20...63: .dtls
        case 128...191: .media
        default: .other
        }
    }

    /// The agent's DTLS share, for `DTLSTransport`.
    public let dtls: any DatagramTransport
    /// SRTP and SRTCP from the selected pair.
    public let media: AsyncStream<[UInt8]>
    private let task: Task<Void, Never>

    public init(agent: ICEAgent) {
        let (dtlsStream, dtlsContinuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let (mediaStream, mediaContinuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        dtls = ICEDTLSTransport(agent: agent, incoming: dtlsStream)
        media = mediaStream
        let received = agent.received
        task = Task {
            for await datagram in received {
                guard let first = datagram.first else { continue }
                switch Self.classify(first) {
                case .dtls: dtlsContinuation.yield(datagram)
                case .media: mediaContinuation.yield(datagram)
                case .stun, .other: break
                }
            }
            dtlsContinuation.finish()
            mediaContinuation.finish()
        }
    }

    deinit { task.cancel() }
}

struct ICEDTLSTransport: DatagramTransport {
    let agent: ICEAgent
    let incoming: AsyncStream<[UInt8]>

    func send(_ datagram: [UInt8]) async throws { try await agent.send(datagram) }
}
