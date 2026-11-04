import HomeswiftAI
import HomeswiftPlugin
import Testing

@Suite struct AccessoryEntriesTests {
    /// An exclude list moves what it names, keeps what names nothing (and what is not text), and an entry's own value wins.
    @Test func anExcludeListMovesWhatItNames() throws {
        var fields = try #require(try JSONValue(any: [
            "exclude": ["Lamp", "Gone", 3], "_accessories": ["lamp-1": ["excluded": false, "room": "Hall"]],
        ] as [String: Any]).objectValue)
        var entries = AccessoryEntries(fields)
        entries.excludeList("exclude", in: &fields) { $0 == "Lamp" ? ["lamp-1", "lamp-2"] : [] }
        entries.setIfAbsent("room", "Office", on: "lamp-1")
        entries.write(into: &fields)
        #expect(JSONValue.object(fields) == (try JSONValue(any: [
            "exclude": ["Gone", 3], "_accessories": ["lamp-1": ["excluded": false, "room": "Hall"], "lamp-2": ["excluded": true]],
        ] as [String: Any])))
        // A list all of whose values move goes, and no entries leave no `_accessories`.
        var moved: [String: JSONValue] = ["exclude": ["Lamp"]]
        var others = AccessoryEntries([:])
        others.excludeList("exclude", in: &moved) { _ in ["lamp-1"] }
        others.write(into: &moved)
        #expect(moved == ["_accessories": ["lamp-1": ["excluded": true]]])
        var empty: [String: JSONValue] = ["name": "x"]
        AccessoryEntries(empty).write(into: &empty)
        #expect(empty == ["name": "x"])
    }
}
