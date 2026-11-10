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
    private var stoppedAt: Date?
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
            if stoppedAt != nil { started = nil; audio = nil; stoppedAt = nil }
            let begin = record?.started ?? started ?? now
            started = begin
            audio = record?.audio ?? audio
            state = .recording(started: begin)
            return
        }
        guard let begin = started else { state = .idle; return }
        let stop = stoppedAt ?? now
        stoppedAt = stop
        audio = audio ?? newestAudio(since: begin)
        let transcribed = audio.map {
            FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("md").path)
        } ?? false
        if transcribed || now.timeIntervalSince(stop) > Self.transcribeTimeout {
            started = nil; audio = nil; stoppedAt = nil
            state = .idle
        } else {
            state = .transcribing
        }
    }

    private func readRecording() -> (started: Date?, audio: URL?)? {
        guard let data = try? Data(contentsOf: stateFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let date: Date?
        switch json["started"] {
        case let seconds as Double: date = Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        case let text as String:
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        default: date = nil
        }
        let path = (json["audio"] as? String).map { ($0 as NSString).expandingTildeInPath }
        return (date, path.map { URL(fileURLWithPath: $0, relativeTo: meetingFolder).absoluteURL })
    }

    private func newestAudio(since begin: Date) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: meetingFolder,
                                                                  includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .compactMap { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    .map { (url, $0) }
            }
            .filter { $0.1 >= begin.addingTimeInterval(-5) }
            .max { $0.1 < $1.1 }?.0
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
