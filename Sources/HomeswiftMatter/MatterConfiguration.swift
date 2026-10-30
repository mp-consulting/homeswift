import Foundation
import HomeswiftAI

/// The `HomeswiftMatter` platform block: the Matter bridge's port and which accessories it bridges.
///
/// ```json
/// { "platform": "HomeswiftMatter", "port": 5540, "include": ["PhilipsHue"], "exclude": ["Garage*"] }
/// ```
///
/// The passcode and discriminator are made on first start and kept with the bridge's fabrics, never in config.json.
public struct MatterConfiguration: Sendable, Equatable {
    public static let platform = "HomeswiftMatter"
    /// Matter's default port (Core §2.5.7).
    public static let defaultPort = 5540

    public var port = Self.defaultPort
    /// Accessories bridged: matched by plugin platform, plugin instance name, accessory id or accessory name, `*` for
    /// any run of characters. Empty bridges every accessory.
    public var include: [String] = []
    /// Accessories left out, matched as `include` is; it wins over `include`.
    public var exclude: [String] = []
    /// Locks, and what a plugin marks as a security control, are left out unless this is on: a Matter controller
    /// writes them without the confirmation the MCP server and the web UI ask for.
    public var exposeSecurity = false
    /// Also listens for TCP on the port, for controllers that send large messages over it (Core §4.15).
    public var tcp = false
    /// Whether the bridge runs: off, only the `devices` are on Matter.
    public var bridge = true
    /// Accessory ids that are Matter devices of their own rather than bridged: each its own node, port and pairing
    /// code, which a controller adds as the device itself.
    public var devices: [String] = []

    public init() {}

    public init(block: JSONValue) throws {
        if let port = block["port"], !port.isNull {
            guard let value = port.intValue, (1...65535).contains(value) else { throw MatterConfigurationError.invalid(key: "port", expected: "a port number") }
            self.port = value
        }
        include = try Self.patterns(block, "include")
        exclude = try Self.patterns(block, "exclude")
        if let expose = block["exposeSecurity"], !expose.isNull {
            guard let value = expose.boolValue else { throw MatterConfigurationError.invalid(key: "exposeSecurity", expected: "true or false") }
            exposeSecurity = value
        }
        if let tcp = block["tcp"], !tcp.isNull {
            guard let value = tcp.boolValue else { throw MatterConfigurationError.invalid(key: "tcp", expected: "true or false") }
            self.tcp = value
        }
        if let bridge = block["bridge"], !bridge.isNull {
            guard let value = bridge.boolValue else { throw MatterConfigurationError.invalid(key: "bridge", expected: "true or false") }
            self.bridge = value
        }
        devices = try Self.patterns(block, "devices")
    }

    private static func patterns(_ block: JSONValue, _ key: String) throws -> [String] {
        guard let value = block[key], !value.isNull else { return [] }
        guard let list = value.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
            throw MatterConfigurationError.invalid(key: key, expected: "a list of names")
        }
        return list.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether an accessory with these names is bridged.
    public func bridges(_ names: [String]) -> Bool {
        func matches(_ patterns: [String]) -> Bool { patterns.contains { pattern in names.contains { Self.glob(pattern, matches: $0) } } }
        return (include.isEmpty || matches(include)) && !matches(exclude)
    }

    /// `*` matches any run of characters; the rest compares without case.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let parts = pattern.lowercased().split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var rest = Substring(text.lowercased())
        guard parts.count > 1 else { return rest == pattern.lowercased() }
        guard rest.hasPrefix(parts[0]) else { return false }
        rest = rest.dropFirst(parts[0].count)
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        return rest.hasSuffix(parts[parts.count - 1])
    }

    /// The block's settings form, in the shape of a plugin's config.schema.json: the web UI's Settings uses it.
    public static let schemaJSON = #"""
        {
          "pluginAlias": "HomeswiftMatter",
          "schema": {
            "type": "object",
            "properties": {
              "port": { "title": "Port", "type": "integer", "default": 5540, "minimum": 1, "maximum": 65535, "description": "The UDP port Matter controllers reach the bridge on. 5540 is Matter's own." },
              "include": { "title": "Only these", "type": "array", "items": { "title": "Plugin or accessory", "type": "string" }, "description": "Bridge only the accessories of these plugins, or with these ids or names; * matches anything. Empty: every accessory." },
              "exclude": { "title": "Leave out", "type": "array", "items": { "title": "Plugin or accessory", "type": "string" }, "description": "Accessories never bridged, named as above. It wins over Only these." },
              "exposeSecurity": { "title": "Bridge locks", "type": "boolean", "default": false, "description": "Locks, and switches a plugin marks as opening something, are left out unless this is on: a Matter controller changes them without the confirmation the web UI and the MCP server ask for." },
              "tcp": { "title": "TCP", "type": "boolean", "default": false, "description": "Also accept Matter over TCP on the same port, for controllers that send large messages. UDP is always on." },
              "bridge": { "title": "Bridge", "type": "boolean", "default": true, "description": "Run the Matter bridge. Off, only the accessories turned into Matter devices of their own are on Matter." },
              "devices": { "title": "Matter devices of their own", "type": "array", "items": { "title": "Accessory id", "type": "string" }, "description": "Accessories that are Matter devices by themselves, each with its own pairing code, rather than bridged. The Accessories page's Matter switch fills this in." }
            }
          },
          "i18n": {
            "fr": {
              "Port": "Port",
              "The UDP port Matter controllers reach the bridge on. 5540 is Matter's own.": "Le port UDP sur lequel les contrôleurs Matter joignent le pont. 5540 est celui de Matter.",
              "Only these": "Seulement ceux-ci",
              "Plugin or accessory": "Plugin ou accessoire",
              "Bridge only the accessories of these plugins, or with these ids or names; * matches anything. Empty: every accessory.": "Relier seulement les accessoires de ces plugins, ou avec ces identifiants ou noms ; * remplace n'importe quoi. Vide : tous les accessoires.",
              "Leave out": "Laisser de côté",
              "Accessories never bridged, named as above. It wins over Only these.": "Les accessoires jamais reliés, nommés comme ci-dessus. Prime sur Seulement ceux-ci.",
              "Bridge locks": "Relier les serrures",
              "Locks, and switches a plugin marks as opening something, are left out unless this is on: a Matter controller changes them without the confirmation the web UI and the MCP server ask for.": "Les serrures, et les interrupteurs qu'un plugin marque comme ouvrant quelque chose, sont laissés de côté sauf si cette option est activée : un contrôleur Matter les change sans la confirmation que demandent l'interface web et le serveur MCP.",
              "TCP": "TCP",
              "Also accept Matter over TCP on the same port, for controllers that send large messages. UDP is always on.": "Accepter aussi Matter en TCP sur le même port, pour les contrôleurs qui envoient de gros messages. L'UDP reste toujours actif.",
              "Bridge": "Pont",
              "Run the Matter bridge. Off, only the accessories turned into Matter devices of their own are on Matter.": "Faire tourner le pont Matter. Désactivé, seuls les accessoires transformés en appareils Matter à part entière sont sur Matter.",
              "Matter devices of their own": "Appareils Matter à part entière",
              "Accessory id": "Identifiant d'accessoire",
              "Accessories that are Matter devices by themselves, each with its own pairing code, rather than bridged. The Accessories page's Matter switch fills this in.": "Les accessoires qui sont des appareils Matter à eux seuls, chacun avec son propre code d'appairage, plutôt que reliés au pont. L'interrupteur Matter de la page Accessoires remplit cette liste."
            },
            "es": {
              "Port": "Puerto",
              "The UDP port Matter controllers reach the bridge on. 5540 is Matter's own.": "El puerto UDP por el que los controladores Matter llegan al puente. 5540 es el de Matter.",
              "Only these": "Solo estos",
              "Plugin or accessory": "Plugin o accesorio",
              "Bridge only the accessories of these plugins, or with these ids or names; * matches anything. Empty: every accessory.": "Puentear solo los accesorios de estos plugins, o con estos identificadores o nombres; * coincide con cualquier cosa. Vacío: todos los accesorios.",
              "Leave out": "Dejar fuera",
              "Accessories never bridged, named as above. It wins over Only these.": "Accesorios que nunca se puentean, nombrados como arriba. Prevalece sobre Solo estos.",
              "Bridge locks": "Puentear cerraduras",
              "Locks, and switches a plugin marks as opening something, are left out unless this is on: a Matter controller changes them without the confirmation the web UI and the MCP server ask for.": "Las cerraduras, y los interruptores que un plugin marca como que abren algo, quedan fuera salvo que esto esté activado: un controlador Matter los cambia sin la confirmación que piden la interfaz web y el servidor MCP.",
              "TCP": "TCP",
              "Also accept Matter over TCP on the same port, for controllers that send large messages. UDP is always on.": "Aceptar también Matter por TCP en el mismo puerto, para los controladores que envían mensajes grandes. UDP siempre está activo.",
              "Bridge": "Puente",
              "Run the Matter bridge. Off, only the accessories turned into Matter devices of their own are on Matter.": "Ejecutar el puente Matter. Desactivado, solo están en Matter los accesorios convertidos en dispositivos Matter propios.",
              "Matter devices of their own": "Dispositivos Matter propios",
              "Accessory id": "Identificador del accesorio",
              "Accessories that are Matter devices by themselves, each with its own pairing code, rather than bridged. The Accessories page's Matter switch fills this in.": "Accesorios que son dispositivos Matter por sí mismos, cada uno con su propio código de vinculación, en lugar de puenteados. El interruptor Matter de la página Accesorios rellena esta lista."
            },
            "pt": {
              "Port": "Porta",
              "The UDP port Matter controllers reach the bridge on. 5540 is Matter's own.": "A porta UDP pela qual os controladores Matter alcançam a ponte. 5540 é a do Matter.",
              "Only these": "Apenas estes",
              "Plugin or accessory": "Plugin ou acessório",
              "Bridge only the accessories of these plugins, or with these ids or names; * matches anything. Empty: every accessory.": "Ligar apenas os acessórios destes plugins, ou com estes identificadores ou nomes; * corresponde a qualquer coisa. Vazio: todos os acessórios.",
              "Leave out": "Deixar de fora",
              "Accessories never bridged, named as above. It wins over Only these.": "Acessórios nunca ligados, nomeados como acima. Prevalece sobre Apenas estes.",
              "Bridge locks": "Ligar fechaduras",
              "Locks, and switches a plugin marks as opening something, are left out unless this is on: a Matter controller changes them without the confirmation the web UI and the MCP server ask for.": "As fechaduras, e os interruptores que um plugin marca como abrindo algo, ficam de fora a menos que isto esteja ativado: um controlador Matter altera-os sem a confirmação que a interface web e o servidor MCP pedem.",
              "TCP": "TCP",
              "Also accept Matter over TCP on the same port, for controllers that send large messages. UDP is always on.": "Aceitar também Matter por TCP na mesma porta, para os controladores que enviam mensagens grandes. O UDP está sempre ativo.",
              "Bridge": "Ponte",
              "Run the Matter bridge. Off, only the accessories turned into Matter devices of their own are on Matter.": "Executar a ponte Matter. Desativada, apenas os acessórios transformados em dispositivos Matter próprios estão no Matter.",
              "Matter devices of their own": "Dispositivos Matter próprios",
              "Accessory id": "Identificador do acessório",
              "Accessories that are Matter devices by themselves, each with its own pairing code, rather than bridged. The Accessories page's Matter switch fills this in.": "Acessórios que são dispositivos Matter por si só, cada um com o seu próprio código de emparelhamento, em vez de ligados à ponte. O interruptor Matter da página Acessórios preenche esta lista."
            }
          }
        }
        """#
}

public enum MatterConfigurationError: Error, CustomStringConvertible, Equatable {
    case invalid(key: String, expected: String)

    public var description: String {
        switch self {
        case .invalid(let key, let expected): "HomeswiftMatter: \(key) should be \(expected)"
        }
    }
}
