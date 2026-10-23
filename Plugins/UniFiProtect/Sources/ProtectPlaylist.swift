import Crypto
import Foundation
import HomeswiftPlugin
import NIOCore
import NIOHTTP1
import NIOPosix

/// The M3U playlist of the controller's cameras (`Nvr.Service.Playlist`), for apps such as Channels DVR:
/// one entry per camera with RTSP turned on (and per package camera), highest quality stream, guide data.
enum ProtectPlaylist {
    /// A name for an `#EXTINF` attribute (no quotes or line breaks) or title (no commas either).
    static func sanitize(_ name: String, isTitle: Bool = false) -> String {
        let removed: Set<Character> = isTitle ? ["\"", "\r", "\n", ","] : ["\"", "\r", "\n"]
        return String(name.filter { !removed.contains($0) }).trimmingCharacters(in: .whitespaces)
    }

    static func generate(_ bootstrap: JSONValue?) -> String {
        var lines = ["#EXTM3U"]
        guard let bootstrap else { return lines.joined(separator: "\n") + "\n" }
        let host = bootstrap.string("nvr.host") ?? ""
        let port = bootstrap.at("nvr.ports.rtsp").map { $0.doubleValue.map { String(Int($0)) } ?? $0.stringValue ?? "" } ?? "undefined"
        let logo = ProtectSettings.playlistLogoURL
        let cameras = bootstrap.array("cameras").map(ProtectDeviceConfig.init)
            .filter { $0.videoCodec != "av1" && $0.channels.contains(where: \.isRtspEnabled) }
            .enumerated().sorted { lhs, rhs in
                let order = (lhs.element.name ?? "").localizedCompare(rhs.element.name ?? "")
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }.map(\.element)
        for camera in cameras {
            let marketName = sanitize(camera.marketName ?? "")
            func entry(name: String, description: String, alias: String) {
                let attribute = sanitize(name)
                lines.append("#EXTINF:0 channel-id=\"\(attribute)\" tvc-stream-vcodec=\"h264\" tvc-stream-acodec=\"opus\" tvg-logo=\"\(logo)\" "
                    + "tvc-guide-title=\"\(attribute) Livestream\" tvc-guide-description=\"UniFi Protect \(marketName) \(description) livestream.\" "
                    + "tvc-guide-art=\"\(logo)\" tvc-guide-tags=\"HD, Live, New, UniFi Protect\", \(sanitize(name, isTitle: true))")
                lines.append("rtsp://\(host):\(port)/\(alias)".filter { $0 != "\r" && $0 != "\n" })
            }
            entry(name: camera.name ?? camera.marketName ?? "", description: "camera", alias: camera.channels.first?.rtspAlias ?? "undefined")
            if camera.feature("hasPackageCamera"), let package = camera.channels.first(where: { $0.isRtspEnabled && $0.name == "Package Camera" }) {
                entry(name: (camera.name ?? camera.marketName ?? "") + " " + package.name, description: "package camera", alias: package.rtspAlias)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether a request's `token` matches the configured one; everything passes without one. Compared as
    /// digests, in constant time.
    static func isAuthorized(path: String, token: String?) -> Bool {
        guard let token, !token.isEmpty else { return true }
        guard let components = URLComponents(string: "http://localhost" + (path.hasPrefix("/") ? path : "/" + path)),
              let supplied = components.queryItems?.first(where: { $0.name == "token" })?.value else { return false }
        let a = Array(SHA256.hash(data: Data(supplied.utf8))), b = Array(SHA256.hash(data: Data(token.utf8)))
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Serves the playlist over HTTP on the configured address and port (`ProtectPlaylistServer`).
actor ProtectPlaylistServer {
    private let api: ProtectAPI
    private let log: ProtectLog
    let address: String?
    let port: Int
    let token: String?
    private var channel: (any Channel)?
    private var retryTask: Task<Void, Never>?

    init(api: ProtectAPI, log: ProtectLog, address: String?, port: Int?, token: String?) {
        self.api = api
        self.log = log
        self.address = address?.trimmingCharacters(in: .whitespaces).nonEmpty
        self.port = port ?? ProtectSettings.m3uPlaylistPort
        self.token = token?.trimmingCharacters(in: .whitespaces).nonEmpty
    }

    /// The port it listens on, once it does.
    var listeningPort: Int? { channel?.localAddress?.port }

    func start() async {
        let api = api, token = token
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(PlaylistHandler(api: api, token: token))
                }
            }
        do {
            channel = try await bootstrap.bind(host: address ?? "0.0.0.0", port: port).get()
            log.info("Publishing an M3U playlist of Protect camera livestream URLs on \(address ?? "all interfaces,") port \(listeningPort ?? port).")
            if token == nil {
                log.warning("The M3U playlist is available to anyone who can reach this Homeswift server\(address == nil ? " on your network" : ""), exposing camera livestream URLs. "
                    + "Configure a playlist access token (and optionally a bind address) in the controller settings to restrict access.")
            }
        } catch let error as IOError where error.errnoCode == EADDRINUSE {
            log.error("The address and port we are attempting to use is already in use by something else. Will retry again shortly.")
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.start()
            }
        } catch {
            log.error("M3U playlist publisher error: \(error)")
        }
    }

    func close() async {
        retryTask?.cancel()
        try? await channel?.close()
        channel = nil
    }
}

private final class PlaylistHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let api: ProtectAPI
    private let token: String?
    private var path = "/"

    init(api: ProtectAPI, token: String?) {
        self.api = api
        self.token = token
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): path = head.uri
        case .body: break
        case .end:
            let authorized = ProtectPlaylist.isAuthorized(path: path, token: token)
            let api = api
            let loop = context.eventLoop
            let box = NIOLoopBound(context, eventLoop: loop)
            Task {
                let body = authorized ? ProtectPlaylist.generate(await api.bootstrap) : "Unauthorized.\n"
                loop.execute {
                    let context = box.value
                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Type", value: authorized ? "application/x-mpegURL" : "text/plain")
                    headers.add(name: "Content-Length", value: String(body.utf8.count))
                    headers.add(name: "Connection", value: "close")
                    context.write(self.wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: authorized ? .ok : .unauthorized, headers: headers))), promise: nil)
                    var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in box.value.close(promise: nil) }
                }
            }
        }
    }
}
