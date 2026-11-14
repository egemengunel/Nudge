//
//  AgentsStripView.swift
//  Nudge
//

import AppKit

/// The Agents tab: one pill per agent session, scrolling sideways when there are many.
final class AgentsStripView: NSView {
    var onSelect: ((AgentSession) -> Void)?

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No agent sessions active")
    private var shown: [AgentSession] = []
    /// One pill per session, kept across refreshes: the strip refreshes every second and on
    /// every hook event, and pulling a button out from under a finger cancels the tap.
    private var pills: [String: NSButton] = [:]

    private static let font = NSFont.systemFont(ofSize: 14)
    private static let waitingBezel = NSColor(srgbRed: 0.40, green: 0.24, blue: 0.02, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ sessions: [AgentSession], now: Date = .now) {
        shown = sessions
        emptyLabel.isHidden = !sessions.isEmpty

        let ids = Set(sessions.map(\.id))
        for (id, button) in pills where !ids.contains(id) {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
            pills[id] = nil
        }
        for (index, session) in sessions.enumerated() {
            let button = pills[session.id] ?? makePill()
            pills[session.id] = button
            configure(button, for: session, now: now)
            let current = stack.arrangedSubviews
            if index < current.count, current[index] === button { continue }
            if current.contains(where: { $0 === button }) {
                stack.removeArrangedSubview(button)
            }
            stack.insertArrangedSubview(button, at: index)
        }
    }

    private func makePill() -> NSButton {
        NSButton(title: "", target: self, action: #selector(select(_:)))
    }

    /// Touches the button only where what it shows changed.
    private func configure(_ button: NSButton, for session: AgentSession, now: Date) {
        let (dotColor, status) = Self.describe(session.state)
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dotColor, .font: Self.font]))
        title.append(NSAttributedString(string: session.project, attributes: [.foregroundColor: NSColor.labelColor, .font: Self.font]))
        if session.project != session.agentName {
            title.append(NSAttributedString(string: " " + session.agentName, attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: Self.font]))
        }
        title.append(NSAttributedString(string: "  " + status, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: Self.font]))
        if session.state.isWorking {
            let elapsed = Self.elapsed(since: session.turnStartedAt, now: now)
            title.append(NSAttributedString(string: "  " + elapsed, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: Self.font]))
        }

        if button.attributedTitle != title {
            button.attributedTitle = title
        }
        let bezel = session.state == .waiting ? Self.waitingBezel : nil
        if button.bezelColor != bezel {
            button.bezelColor = bezel
        }
        button.identifier = NSUserInterfaceItemIdentifier(session.id)
    }

    @objc private func select(_ sender: NSButton) {
        guard let session = shown.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        onSelect?(session)
    }

    private static func describe(_ state: AgentSession.State) -> (NSColor, String) {
        switch state {
        case .waiting: (.systemOrange, "needs you")
        case .thinking: (.systemBlue, "thinking")
        case let .tool(name, detail): (.systemBlue, detail.map { "\(name) · \(shorten($0))" } ?? name)
        case .done: (.systemGreen, "done")
        case .idle: (.secondaryLabelColor, "idle")
        }
    }

    /// File paths become their file name; anything else is cut to fit a pill.
    private static func shorten(_ detail: String) -> String {
        let text = detail.hasPrefix("/") ? URL(fileURLWithPath: detail).lastPathComponent : detail
        let firstLine = text.prefix { $0 != "\n" }
        return firstLine.count > 26 ? firstLine.prefix(25) + "…" : String(firstLine)
    }

    private static func elapsed(since start: TimeInterval, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - start))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
