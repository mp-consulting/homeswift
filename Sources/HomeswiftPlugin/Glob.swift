/// Shell-style patterns over a whole text, for plugins' include and exclude lists: `*` matches any run of characters,
/// `?` any one; case is ignored. Home Assistant's entity ids and Kasa's MAC addresses use it.
public enum Glob {
    public static func matches(any patterns: [String], _ text: String) -> Bool { patterns.contains { matches($0, text) } }

    /// The classic two-pointer match, backtracking to the last `*`.
    public static func matches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
