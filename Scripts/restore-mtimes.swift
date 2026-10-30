// Sets each tracked file's modification time to the time of the last commit that changed it, so a build restored
// from CI's cache sees the files it was built from as unchanged: a fresh checkout dates every file now, which
// rebuilds all of the package's own code. Needs the whole history (`fetch-depth: 0`).
//
// A pull request builds its merge commit over the cache of its base, which may have been built after the branch's own
// commits: a file the branch changed would then look older than its cached object, and the stale object be linked. On a
// merge commit, every file that differs from the first parent (the base) is dated now instead.
//
//   swift Scripts/restore-mtimes.swift

import Foundation

/// Runs git; its standard output, or nil when it fails.
func run(_ arguments: [String]) -> Data? {
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    git.arguments = ["git"] + arguments
    let pipe = Pipe()
    git.standardOutput = pipe
    git.standardError = FileHandle.nullDevice
    guard (try? git.run()) != nil else { return nil }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    git.waitUntilExit()
    return git.terminationStatus == 0 ? output : nil
}

guard let output = run(["log", "--format=%x00%ct", "--name-only", "--no-renames", "HEAD"]) else {
    FileHandle.standardError.write(Data("git log failed\n".utf8))
    exit(1)
}

// Newest commit first: a file's first appearance is its last change.
var times: [String: Date] = [:]
var current: Date?
for line in String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
    if line.first == "\0" {
        current = TimeInterval(line.dropFirst()).map(Date.init(timeIntervalSince1970:))
    } else if let current, times[String(line)] == nil {
        times[String(line)] = current
    }
}

// A merge commit (a pull request's): what it changes against its base is new to the base's cache.
if run(["rev-parse", "--verify", "--quiet", "HEAD^2"]) != nil, let changed = run(["diff", "--name-only", "--no-renames", "HEAD^1", "HEAD"]) {
    let now = Date()
    for path in String(decoding: changed, as: UTF8.self).split(separator: "\n") { times[String(path)] = now }
}

var set = 0
for (path, date) in times where FileManager.default.fileExists(atPath: path) {
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    set += 1
}
print("Dated \(set) files by their last commit.")
