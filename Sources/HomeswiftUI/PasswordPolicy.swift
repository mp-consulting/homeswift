import Foundation

/// The web UI's password rules, after the ANSSI's *Recommandations relatives à l'authentification multifacteur
/// et aux mots de passe* (PG-078, 2021): a minimum length (R21), no low maximum (R22), a large character set
/// rather than imposed character kinds (R23), and an automatic check when a password is created or changed,
/// against common passwords too (R27). The account administers the bridge, so the bar is the guide's
/// "moyen à fort" level of table 3: 12 characters and about 85 bits (above the CNIL's 80-bit floor of
/// deliberation 2022-100, written with the ANSSI).
///
/// The estimate is the guide's: length × log₂(size of the character set used). As the guide warns, that only
/// holds for characters drawn at random, so what people tend to type earns nothing: a character repeating the
/// two before it, one continuing a run (abc, 321), and every character after the first of a common word or of
/// the username. `Web/app.js` (`passwordStrength`) mirrors this, for the gauge; the server's check is this one.
public enum PasswordPolicy {
    public static let minimumLength = 12
    /// Bytes: long enough for any passphrase (R22), short enough that hashing it costs nothing (the guide's caution).
    public static let maximumBytes = 1024
    public static let minimumBits = 85.0

    /// The guide's table 3 bands, by estimated bits: below 65, to 85, to 100, then 100 and more.
    public enum Level: String, Sendable {
        case veryWeak, lowToMedium, mediumToStrong, strongToVeryStrong
    }

    public struct Strength: Sendable, Equatable {
        public var bits: Double
        public var length: Int
        public var level: Level
        /// What keeps the password from the bar, in words; empty when it passes.
        public var problems: [String]
        public var isAcceptable: Bool { problems.isEmpty }
    }

    /// Words people put in passwords, in English and French, and this bridge's names. Lower case.
    static let commonWords = [
        "password", "passw0rd", "motdepasse", "secret", "admin", "administrator", "root", "user", "login", "welcome",
        "letmein", "iloveyou", "monkey", "dragon", "master", "sunshine", "princess", "football", "baseball", "shadow",
        "azerty", "qwerty", "qwertz", "asdf", "zxcv", "abc123", "123456", "654321", "111111", "000000", "121212",
        "bonjour", "soleil", "chouchou", "doudou", "loulou", "marseille", "paris", "france", "amour", "jetaime",
        "homeswift", "homebridge", "homekit", "apple", "iphone", "changeme", "default", "test",
    ]

    public static func evaluate(_ password: String, username: String? = nil) -> Strength {
        let scalars = Array(password.unicodeScalars)
        var pool = 0
        if scalars.contains(where: { ("a"..."z").contains($0) }) { pool += 26 }
        if scalars.contains(where: { ("A"..."Z").contains($0) }) { pool += 26 }
        if scalars.contains(where: { ("0"..."9").contains($0) }) { pool += 10 }
        if scalars.contains(where: { $0.isASCII && !$0.properties.isAlphabetic && !("0"..."9").contains($0) }) { pool += 33 }
        if scalars.contains(where: { !$0.isASCII }) { pool += 64 }

        // What counts: each character, but not a repeat of the two before it, nor a step of a run of three.
        var counts = [Bool](repeating: true, count: scalars.count)
        var patterned = false
        for i in scalars.indices where i >= 2 {
            let (a, b, c) = (Int(scalars[i - 2].value), Int(scalars[i - 1].value), Int(scalars[i].value))
            if (a == b && b == c) || (b - a == c - b && abs(c - b) == 1) {
                counts[i] = false
                patterned = true
            }
        }
        // A common word or the username counts as one character, wherever it appears (letter case aside).
        let lowered: [Unicode.Scalar] = scalars.map { scalar in
            let mapped = scalar.properties.lowercaseMapping.unicodeScalars
            return mapped.count == 1 ? mapped.first! : scalar
        }
        var problems: [String] = []
        var words = commonWords
        let name = username?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if name.unicodeScalars.count >= 3 { words.append(name) }
        var foundCommon = false, foundName = false
        for word in words {
            let target = Array(word.unicodeScalars)
            var i = 0
            while i + target.count <= lowered.count {
                guard lowered[i..<(i + target.count)].elementsEqual(target) else { i += 1; continue }
                for j in (i + 1)..<(i + target.count) { counts[j] = false }
                if word == name { foundName = true } else { foundCommon = true }
                i += target.count
            }
        }
        let effective = counts.filter { $0 }.count
        let bits = pool > 0 ? Double(effective) * log2(Double(pool)) : 0

        if scalars.count < minimumLength { problems.append("use at least \(minimumLength) characters") }
        if password.utf8.count > maximumBytes { problems.append("use at most \(maximumBytes) bytes") }
        if bits < minimumBits {
            var hint = "make it stronger: \(Int(bits.rounded())) of \(Int(minimumBits)) bits"
            if foundName { hint += "; your username adds nothing" } else if foundCommon { hint += "; common words add little" } else if patterned { hint += "; repeated or sequential characters add nothing" }
            problems.append(hint)
        }
        let level: Level = bits >= 100 ? .strongToVeryStrong : bits >= 85 ? .mediumToStrong : bits >= 65 ? .lowToMedium : .veryWeak
        return Strength(bits: bits, length: scalars.count, level: level, problems: problems)
    }

    /// Throws `AuthError.weakPassword` with what to change when the password does not pass.
    static func check(_ password: String, username: String?) throws {
        let strength = evaluate(password, username: username)
        guard strength.isAcceptable else { throw AuthError.weakPassword(strength.problems.joined(separator: "; ")) }
    }
}
