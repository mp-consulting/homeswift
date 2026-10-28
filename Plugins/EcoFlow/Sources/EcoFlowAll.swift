import Foundation

/// The devices of every API the plugin has settings for, read as one list. The APIs are read at the same time; a
/// device that more than one reports is taken from the first (the developer API), unless its model was checked on a
/// real device on another route only, so each device keeps a single source. An API that fails does not hide the
/// others' devices: its failure is logged once, and the error is thrown only when no API returns a device.
///
/// Each API is read at its own pace: the plugin reads the list every few seconds, for the app's stream, and an API with
/// an interval (the developer API, a request per device) answers from its last read until the interval has passed.
/// Each API is told what the others reported last, so the developer API does not ask for a device the app's route
/// reads and was checked on (a RIVER 3): its answer would be dropped here.
struct EcoFlowAll: EcoFlowAPI {
    let apis: [any EcoFlowAPI]
    /// Each API's interval between reads, by index; an API without one is read every time.
    var intervals: [Int: Duration] = [:]
    let notices = EcoFlowNotices()
    private let last = LastReads()

    /// Each API's last read, and when it was made.
    actor LastReads {
        var reads: [Int: (at: ContinuousClock.Instant, result: Result<[EcoFlowDevice], Error>)] = [:]

        func fresh(_ index: Int, within interval: Duration?) -> Result<[EcoFlowDevice], Error>? {
            guard let interval, let read = reads[index], ContinuousClock.now < read.at + interval else { return nil }
            return read.result
        }

        func keep(_ index: Int, _ result: Result<[EcoFlowDevice], Error>) {
            reads[index] = (ContinuousClock.now, result)
        }

        /// The devices the other APIs reported at their last read.
        func others(than index: Int) -> [EcoFlowDevice] {
            reads.filter { $0.key != index }.values.flatMap { (try? $0.result.get()) ?? [] }
        }
    }

    var name: String { "EcoFlow APIs" }

    func devices() async throws -> [EcoFlowDevice] {
        let results = await withTaskGroup(of: (Int, Result<[EcoFlowDevice], Error>).self) { group in
            for (index, api) in apis.enumerated() {
                group.addTask { [last, intervals] in
                    if let kept = await last.fresh(index, within: intervals[index]) { return (index, kept) }
                    // What the others reported last: an API need not ask for a device another route reads.
                    let elsewhere = api.readsElsewhere ? await last.others(than: index) : []
                    let result: Result<[EcoFlowDevice], Error>
                    do { result = .success(try await api.devices(besides: elsewhere)) } catch { result = .failure(error) }
                    await last.keep(index, result)
                    return (index, result)
                }
            }
            var results: [Int: Result<[EcoFlowDevice], Error>] = [:]
            for await (index, result) in group { results[index] = result }
            return results
        }
        var all: [EcoFlowDevice] = []
        var failure: Error?
        for (index, api) in apis.enumerated() {
            switch results[index] {
            case .success(let devices)?:
                await notices.report(api.name, nil, recovered: "The \(api.name) answers again")
                for device in devices {
                    guard let earlier = all.firstIndex(where: { $0.id == device.id }) else {
                        all.append(device)
                        continue
                    }
                    // A model checked on one route only (a RIVER 3 on the app's) is read from that route.
                    if device.tested, !all[earlier].tested { all[earlier] = device }
                }
            case .failure(let error)?:
                failure = failure ?? error
                await notices.report(api.name, "The \(api.name) could not be read: \(error)", recovered: "")
            case nil:
                continue
            }
        }
        if all.isEmpty, let failure { throw failure }
        return all
    }

    func schemaChanges() async -> [String] {
        var changes = await notices.drain()
        for api in apis { changes += await api.schemaChanges() }
        return changes
    }

    func stop() async {
        for api in apis { await api.stop() }
    }
}
