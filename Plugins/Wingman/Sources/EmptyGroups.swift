import HomeswiftPlugin

// Apple Home's groups of fewer than two accessories in the bridge's home: the Home app does not show them, and an
// interrupted creation can leave one, which then takes the group's name (HMErrorDomain 13) and counts towards HomeKit's
// limit (HMErrorDomain 49). Counted from Apple Home's own list of the group's services, so a group of accessories
// Homeswift does not have is never taken for an empty one.

extension WingmanPlugin {
    /// The bridge's home's groups that hold fewer than two services; nil without a Home Link.
    func emptyGroups() async -> (home: Structure.Home, link: Link, groups: [WingmanAPI.ServiceGroup])? {
        guard let (link, _, home) = await homeLinkOwner() else { return nil }
        return (home, link, home.serviceGroups.filter { $0.services.count < 2 })
    }

    func emptyGroupsResponse() async -> PluginWebResponse {
        guard let found = await emptyGroups() else { return .error(409, "No Home Link: pair Homeswift Wingman and link the bridge to its home") }
        return PluginWebResponse([
            "home": .string(found.home.name),
            "groups": .array(found.groups.map { ["id": .string($0.id), "name": .string($0.name), "accessories": .number(Double($0.services.count))] }),
        ])
    }

    /// Removes the groups of `ids` (all of them without `ids`) that still hold fewer than two services.
    func removeEmptyGroups(_ ids: [String]?) async -> PluginWebResponse {
        guard let found = await emptyGroups() else { return .error(409, "No Home Link: pair Homeswift Wingman and link the bridge to its home") }
        let chosen = found.groups.filter { ids == nil || ids!.contains($0.id) }
        var removed: [JSONValue] = [], failed: [JSONValue] = []
        for group in chosen {
            do {
                _ = try await applyHomeChange(.deleteGroup(id: group.id))
                removed.append(["id": .string(group.id), "name": .string(group.name)])
            } catch {
                failed.append(["id": .string(group.id), "name": .string(group.name), "error": .string("\(error)")])
            }
        }
        context.logger.info("Removed Apple Home's empty groups", metadata: ["removed": "\(removed.count)", "failed": "\(failed.count)", "home": "\(found.home.name)"])
        return PluginWebResponse(["home": .string(found.home.name), "removed": .array(removed), "failed": .array(failed)])
    }
}
