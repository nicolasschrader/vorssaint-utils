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
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var processStarted: Date?
        let service = NotchMeetingService(stateFile: stateFile, meetingFolder: folder) { processStarted }

        // The recorder's last write to the m4a marks the stop.
        func recorded(_ name: String, stoppedAt date: Date) {
            let url = folder.appendingPathComponent(name)
            try? Data().write(to: url)
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        service.refresh(now: now)
        suite.expect(service.state == .idle, "no state file and no recorder is idle")

        try? "{}".write(to: stateFile, atomically: true, encoding: .utf8)
        service.refresh(now: now)
        suite.expect(service.state == .idle, "a state file without pid, name, audio and started is no recording")

        try? #"{"pid":42,"name":"Standup","audio":"Standup.m4a","started":"2027-01-15T08:00:00Z"}"#
            .write(to: stateFile, atomically: true, encoding: .utf8)
        service.refresh(now: now)
        suite.expect(service.state == .recording(started: ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!),
                     "the state file's start time drives the recording timer")

        recorded("Standup.m4a", stoppedAt: now)
        try? FileManager.default.removeItem(at: stateFile)
        service.refresh(now: now.addingTimeInterval(10))
        suite.expect(service.state == .transcribing, "after the stop, a recording without its .md is transcribing")
        try? Data().write(to: folder.appendingPathComponent("Standup.md"))
        service.refresh(now: now.addingTimeInterval(60))
        suite.expect(service.state == .idle, "the .md next to the recording ends transcribing")

        processStarted = now.addingTimeInterval(100)
        service.refresh(now: now.addingTimeInterval(220))
        suite.expect(service.state == .recording(started: now.addingTimeInterval(100)),
                     "a recorder process first seen two minutes in times from the process start, not from the check")
        recorded("Sync.m4a", stoppedAt: now.addingTimeInterval(300))
        processStarted = nil
        service.refresh(now: now.addingTimeInterval(301))
        suite.expect(service.state == .transcribing, "a process-only recording waits for transcription too")
        service.refresh(now: now.addingTimeInterval(300 + NotchMeetingService.transcribeTimeout + 1))
        suite.expect(service.state == .idle, "a transcript that never comes stops claiming transcribing")

        let late = NotchMeetingService(stateFile: stateFile, meetingFolder: folder) { false }
        recorded("Offline.m4a", stoppedAt: now.addingTimeInterval(10_000))
        late.refresh(now: now.addingTimeInterval(10_000 + 60))
        suite.expect(late.state == .transcribing, "a meeting recorded before the first refresh is still transcribing")
        late.refresh(now: now.addingTimeInterval(10_000 + NotchMeetingService.transcribeTimeout + 1))
        suite.expect(late.state == .idle, "the timeout runs from the recording's stop, not from the first refresh")

        let behind = NotchMeetingService(stateFile: stateFile, meetingFolder: folder) { false }
        recorded("Earlier.m4a", stoppedAt: now.addingTimeInterval(20_000))
        recorded("Later.m4a", stoppedAt: now.addingTimeInterval(20_030))
        try? Data().write(to: folder.appendingPathComponent("Later.md"))
        behind.refresh(now: now.addingTimeInterval(20_060))
        suite.expect(behind.state == .idle,
                     "an older recording without its .md does not hold transcribing once the last meeting has its .md")
    }
}
