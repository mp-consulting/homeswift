// Sets each tracked file's modification time to the time of the last commit that changed it, so a build restored
// from CI's cache sees the files it was built from as unchanged: a fresh checkout dates every file now, which
// rebuilds all of the package's own code. Needs the whole history (`fetch-depth: 0`).
//
//   swift Scripts/restore-mtimes.swift

import Foundation

let git = Process()
git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
git.arguments = ["git", "log", "--format=%x00%ct", "--name-only", "--no-renames", "HEAD"]
let pipe = Pipe()
git.standardOutput = pipe
try git.run()
let output = pipe.fileHandleForReading.readDataToEndOfFile()
git.waitUntilExit()
guard git.terminationStatus == 0 else {
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

var set = 0
for (path, date) in times where FileManager.default.fileExists(atPath: path) {
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    set += 1
}
print("Dated \(set) files by their last commit.")
