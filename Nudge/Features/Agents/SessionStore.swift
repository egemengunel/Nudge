//
//  SessionStore.swift
//  Nudge
//

import Foundation

/// Watches the hook's output folder and keeps the current sessions in memory.
final class SessionStore {
    static let directory = URL.applicationSupportDirectory.appending(path: "Nudge/sessions", directoryHint: .isDirectory)

    /// How long a finished session stays on the Touch Bar.
    private static let doneLinger: TimeInterval = 60
    /// A "thinking" session with no sign of life for this long was probably killed without a SessionEnd.
    private static let staleAfter: TimeInterval = 30 * 60
    /// A tool that started and hasn't returned (a long build, a test run) fires no events and
    /// writes nothing while it runs, so it keeps its pill far longer.
    private static let toolStaleAfter: TimeInterval = 3 * 60 * 60
    private static let deleteAfter: TimeInterval = 24 * 60 * 60
    /// A backstop for missed folder events, and for a folder that was deleted and recreated.
    private static let rescanInterval: TimeInterval = 30

    var onChange: (() -> Void)?
    private(set) var sessions: [AgentSession] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var rescan: Timer?
    private var transcripts: [String: TranscriptState] = [:]

    func start() {
        watch()
        rescan = Timer.scheduledTimer(withTimeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The watched folder was removed (the hook makes a new one): watch the new one.
                if !FileManager.default.fileExists(atPath: Self.directory.path) || self.watcher == nil {
                    self.watch()
                } else {
                    self.reload()
                }
            }
        }
        if let rescan { RunLoop.main.add(rescan, forMode: .common) }
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        // The hook writes via rename, which always touches the directory itself.
        let descriptor = open(Self.directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                MainActor.assumeIsolated {
                    guard let self, let source else { return }
                    if source.data.contains(.delete) || source.data.contains(.rename) {
                        self.watch()
                    } else {
                        self.reload()
                    }
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        }
        reload()
    }

    func reload() {
        let now = Date.now.timeIntervalSince1970
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []

        sessions = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder().decode(AgentSession.self, from: data)
            else { return nil }

            if now - session.updatedAt > Self.deleteAfter {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return session
        }
        let paths = Set(sessions.compactMap(\.transcript))
        transcripts = transcripts.filter { paths.contains($0.key) }
        onChange?()
    }

    /// Sessions worth showing: waiting on you, working, or finished within the last minute.
    /// Waiting sessions come first, then oldest turn first.
    func visible(at now: Date = .now) -> [AgentSession] {
        let now = now.timeIntervalSince1970
        return sessions
            .filter { !NudgeSettings.isHidden($0.agent ?? "claude") }
            .filter { session in
                switch session.state {
                case .waiting: true
                case .thinking: isWorking(session, now: now, staleAfter: Self.staleAfter)
                case .tool: isWorking(session, now: now, staleAfter: Self.toolStaleAfter)
                case .done: now - session.updatedAt < Self.doneLinger
                case .idle: false
                }
            }
            .sorted { lhs, rhs in
                (lhs.state == .waiting ? 0 : 1, lhs.turnStartedAt) < (rhs.state == .waiting ? 0 : 1, rhs.turnStartedAt)
            }
    }

    /// A working session is still working unless the transcript says the turn was interrupted
    /// (Claude Code fires no Stop when you press Esc) or nothing has happened for too long.
    private func isWorking(_ session: AgentSession, now: TimeInterval, staleAfter: TimeInterval) -> Bool {
        // Hook events land a moment before the transcript catches up; nothing to check yet.
        guard now - session.updatedAt > 2, let transcript = transcript(of: session) else {
            return now - session.updatedAt < staleAfter
        }
        if let interruptedAt = transcript.interruptedAt, interruptedAt >= session.updatedAt - 1 {
            return false
        }
        return now - max(session.updatedAt, transcript.modified) < staleAfter
    }

    // MARK: - Transcripts

    private struct TranscriptState {
        let modified: TimeInterval
        /// When the transcript's last turn entry is Claude Code's interrupt marker.
        let interruptedAt: TimeInterval?
    }

    /// The transcript's state, re-read only when the file changed.
    private func transcript(of session: AgentSession) -> TranscriptState? {
        guard let path = session.transcript,
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        if let cached = transcripts[path], cached.modified == modified.timeIntervalSince1970 {
            return cached
        }
        let state = TranscriptState(
            modified: modified.timeIntervalSince1970,
            interruptedAt: session.usesBridge ? Self.interruptedAt(path) : nil
        )
        transcripts[path] = state
        return state
    }

    private static let interruptMarker = "[Request interrupted by user"
    /// Transcript timestamps look like `2026-11-14T17:56:00.870Z`.
    private static let stampFormat: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    /// Reads the end of a Claude Code transcript (JSON lines) and, if its last user or assistant
    /// entry is the interrupt marker, returns that entry's time.
    private static func interruptedAt(_ path: String) -> TimeInterval? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant"
            else { continue }
            guard type == "user",
                  let message = entry["message"] as? [String: Any],
                  texts(in: message["content"]).contains(where: { $0.hasPrefix(interruptMarker) })
            else { return nil }
            let stamp = (entry["timestamp"] as? String).flatMap { stampFormat.date(from: $0) }
            return stamp?.timeIntervalSince1970 ?? Date.now.timeIntervalSince1970
        }
        return nil
    }

    /// The text of a message's content: a string, or text and tool-result blocks.
    private static func texts(in content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.flatMap { block -> [String] in
            if let text = block["text"] as? String { return [text] }
            if block["type"] as? String == "tool_result" { return texts(in: block["content"]) }
            return []
        }
    }
}
