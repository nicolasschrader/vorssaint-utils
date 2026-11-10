// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Darwin
import Foundation

enum NotchMeetingState: Equatable {
    case idle
    case recording(started: Date)
    case transcribing
}

/// Whether Voz's meeting extension is recording or transcribing, read only from
/// outside: its state file, its recorder process and the meeting folder.
final class NotchMeetingService: ObservableObject {
    static let shared = NotchMeetingService()

    /// Voz writes no "transcribed" marker, so a missing .md is the only sign
    /// transcription is still running. A crash or a disabled transcriber would
    /// leave it missing for good; past this the island stops claiming it.
    static let transcribeTimeout: TimeInterval = 30 * 60

    @Published private(set) var state: NotchMeetingState = .idle

    private let stateFile: URL
    private let meetingFolder: URL
    private let recorderRunning: () -> Bool
    private var started: Date?
    private var audio: URL?
    private var timer: Timer?

    // shortcut: Voz's extension data folder is assumed, not read from Voz; upgrade if Voz documents it.
    static let defaultStateFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Voz/extensions/voz-meeting/recording.json")
    static let defaultMeetingFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Voz Meetings", isDirectory: true)

    init(stateFile: URL = NotchMeetingService.defaultStateFile,
         meetingFolder: URL = NotchMeetingService.defaultMeetingFolder,
         recorderRunning: @escaping () -> Bool = NotchMeetingService.isRecorderRunning) {
        self.stateFile = stateFile
        self.meetingFolder = meetingFolder
        self.recorderRunning = recorderRunning
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(now: Date = Date()) {
        let record = readRecording()
        if record != nil || recorderRunning() {
            if started == nil { audio = nil }
            let begin = record?.started ?? started ?? now
            started = begin
            audio = record?.audio ?? audio
            state = .recording(started: begin)
            return
        }
        started = nil
        if isTranscribing(now: now) {
            state = .transcribing
        } else {
            audio = nil
            state = .idle
        }
    }

    /// The recorder writes the m4a until it stops, so its modification time is the stop time,
    /// even for a meeting recorded while Vorssaint was not running. Without a known recording,
    /// any recent m4a still missing its .md counts, not just the newest one.
    private func isTranscribing(now: Date) -> Bool {
        (audio.map { [$0] } ?? folderAudio()).contains { file in
            guard !FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("md").path),
                  let stopped = Self.modified(file) else { return false }
            return now.timeIntervalSince(stopped) <= Self.transcribeTimeout
        }
    }

    private func readRecording() -> (started: Date, audio: URL)? {
        guard let data = try? Data(contentsOf: stateFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["pid"] is NSNumber, json["name"] is String,
              let path = json["audio"] as? String else { return nil }
        let date: Date?
        switch json["started"] {
        case let seconds as Double: date = Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        case let text as String:
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        default: date = nil
        }
        guard let date else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return (date, URL(fileURLWithPath: expanded, relativeTo: meetingFolder).absoluteURL)
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func folderAudio() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: meetingFolder,
                                                                  includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "m4a" }
    }

    /// The permanent `meeting-rec watch` listener runs between meetings too and is no recording.
    static func isRecording(arguments: [String]) -> Bool {
        guard let program = arguments.first, (program as NSString).lastPathComponent == "meeting-rec" else { return false }
        return !arguments.dropFirst().contains { $0 == "watch" || $0 == "--watch" }
    }

    /// The argv of a KERN_PROCARGS2 buffer: argc, the exec path, padding, then argv.
    static func arguments(procArgs: [UInt8]) -> [String] {
        guard procArgs.count > 4 else { return [] }
        let argc = procArgs.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        return procArgs[4...].split(separator: 0).dropFirst().prefix(max(0, argc))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func isRecorderRunning() -> Bool {
        let estimated = max(1, Int(proc_listallpids(nil, 0)))
        var pids = [pid_t](repeating: 0, count: estimated + 32)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return false }
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            // shortcut: matches a native meeting-rec binary only; a script under node/python would show its interpreter's name.
            guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "meeting-rec" else { continue }
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { continue }
            if isRecording(arguments: arguments(procArgs: Array(buffer.prefix(size)))) { return true }
        }
        return false
    }
}
