// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum NotchMeetingTests {
    static func run(_ suite: TestSuite) {
        suite.expect(NotchMeetingService.isRecording(arguments: ["/usr/local/bin/meeting-rec", "--out", "a.m4a"]),
                     "a meeting-rec run without watch is a recording")
        suite.expect(!NotchMeetingService.isRecording(arguments: ["meeting-rec", "watch"]),
                     "the permanent meeting-rec watcher is no recording")
        suite.expect(!NotchMeetingService.isRecording(arguments: ["/bin/zsh", "meeting-rec"]),
                     "another program naming meeting-rec is no recording")
        var procArgs: [UInt8] = [2, 0, 0, 0]
        procArgs += Array("/opt/meeting-rec".utf8) + [0, 0, 0]
        procArgs += Array("meeting-rec".utf8) + [0] + Array("watch".utf8) + [0]
        procArgs += Array("HOME=/x".utf8) + [0]
        suite.expect(NotchMeetingService.arguments(procArgs: procArgs) == ["meeting-rec", "watch"],
                     "KERN_PROCARGS2 yields argv without the exec path or environment")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorssaint-meeting-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Voz Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateFile = root.appendingPathComponent("recording.json")
        var processRunning = false
        let service = NotchMeetingService(stateFile: stateFile, meetingFolder: folder) { processRunning }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        service.refresh(now: now)
        suite.expect(service.state == .idle, "no state file and no recorder is idle")

        try? #"{"pid":42,"name":"Standup","audio":"Standup.m4a","started":"2027-01-15T08:00:00Z"}"#
            .write(to: stateFile, atomically: true, encoding: .utf8)
        service.refresh(now: now)
        suite.expect(service.state == .recording(started: ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!),
                     "the state file's start time drives the recording timer")

        try? FileManager.default.removeItem(at: stateFile)
        service.refresh(now: now)
        suite.expect(service.state == .transcribing, "after the stop, a recording without its .md is transcribing")
        try? Data().write(to: folder.appendingPathComponent("Standup.md"))
        service.refresh(now: now.addingTimeInterval(60))
        suite.expect(service.state == .idle, "the .md next to the recording ends transcribing")

        processRunning = true
        service.refresh(now: now)
        suite.expect(service.state == .recording(started: now), "a recorder process alone starts a recording now")
        processRunning = false
        service.refresh(now: now.addingTimeInterval(1))
        suite.expect(service.state == .transcribing, "a process-only recording waits for transcription too")
        service.refresh(now: now.addingTimeInterval(1 + NotchMeetingService.transcribeTimeout + 1))
        suite.expect(service.state == .idle, "a transcript that never comes stops claiming transcribing")
    }
}
