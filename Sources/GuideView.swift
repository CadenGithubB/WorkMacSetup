import AppKit
import SwiftUI

// Help uses embedded text; it needs no guide file reads or external app.
struct GuideView: View {
    static let initialContentHeight: CGFloat = 660

    private let topics = GuideDocument.parse(EmbeddedGuide.markdown)
    @State private var selection = 0

    private var selectedTopic: GuideTopic? {
        topics.first { $0.id == selection } ?? topics.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if let topic = selectedTopic {
                detail(topic)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(GuideWindowSizing())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Setup guide", systemImage: "book.closed")
                    .font(.headline)
                Text("CONTENTS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)

            List(selection: Binding<Int?>(
                get: { selection },
                set: { if let topic = $0 { selection = topic } }
            )) {
                ForEach(topics) { topic in
                    Label(topic.title, systemImage: topic.symbol)
                        .font(.callout)
                        .padding(.vertical, 5)
                        .tag(topic.id)
                        .accessibilityLabel("Show \(topic.title)")
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Guide table of contents")

            Text("Pick a topic to jump straight to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(18)
        }
        .frame(width: 210)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func detail(_ topic: GuideTopic) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    topicHeader(topic)
                    ForEach(topic.groups) { group in
                        GuideCard(group: group, collapsible: topic.title == "Troubleshooting")
                    }
                }
                .textSelection(.enabled)
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A new topic starts at the top while sidebar focus is preserved.
            .id(topic.id)
            .accessibilityLabel("\(topic.title) guide content")

            Divider()
            HStack {
                Button {
                    selection = topic.id - 1
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .disabled(topic.id == 0)

                Spacer()
                Text("\(topic.id + 1) of \(topics.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()

                Button {
                    selection = topic.id + 1
                } label: {
                    HStack(spacing: 5) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                }
                .disabled(topic.id == topics.count - 1)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func topicHeader(_ topic: GuideTopic) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: topic.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 46, height: 46)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                Spacer()
                Text("WORK MAC SETUP")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
            Text(topic.title)
                .font(.system(size: 28, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            if !topic.summary.isEmpty {
                Text(guideMarkdown(topic.summary))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// Restored frames can override the scene's defaultSize. Give Quick start enough
// room on opening, without changing the width or preventing later resizing.
private struct GuideWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ nsView: SizingView, context: Context) {}

    final class SizingView: NSView {
        private var hasSizedWindow = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !hasSizedWindow else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, !self.hasSizedWindow else { return }
                self.hasSizedWindow = true

                let current = window.frame
                let preferred = window.frameRect(forContentRect: NSRect(
                    origin: .zero,
                    size: NSSize(width: current.width, height: GuideView.initialContentHeight)
                ))
                var frame = current
                frame.size.height = max(current.height, preferred.height)
                frame.origin.y = current.maxY - frame.height

                if let screen = window.screen ?? NSScreen.main {
                    let available = screen.visibleFrame
                    frame.size.width = min(frame.width, available.width)
                    frame.size.height = min(frame.height, available.height)
                    frame.origin.x = max(available.minX, min(current.minX, available.maxX - frame.width))
                    frame.origin.y = max(available.minY, min(current.maxY - frame.height, available.maxY - frame.height))
                }
                window.setFrame(frame, display: true)
            }
        }
    }
}

private struct GuideCard: View {
    let group: GuideGroup
    var collapsible = false
    @State private var isExpanded = false

    var body: some View {
        Group {
            if collapsible, let title = group.title {
                DisclosureGroup(isExpanded: $isExpanded) {
                    blocks.padding(.top, 12)
                } label: {
                    Text(title)
                        .font(.headline)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if let title = group.title {
                        Text(title)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                    blocks
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(group.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    bodyText(text)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                            .accessibilityHidden(true)
                        bodyText(text)
                    }
                case .step(let number, let text):
                    HStack(alignment: .top, spacing: 12) {
                        Text(number)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.blue)
                            .frame(minWidth: 25, minHeight: 25)
                            .background(.blue.opacity(0.10), in: Circle())
                        bodyText(text)
                            .padding(.top, 3)
                    }
                case .callout(let text):
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                        bodyText(text)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                case .code(let language, let text):
                    GuideExample(language: language, text: text, title: group.title ?? "Example")
                }
            }
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(guideMarkdown(text))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GuideExample: View {
    let language: String
    let text: String
    let title: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(language == "sh" ? "TERMINAL" : "EXAMPLE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .help("Copy example to clipboard")
                .accessibilityLabel("Copy \(title) example")
                .accessibilityValue(copied ? "Copied to clipboard" : "")
            }
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .task(id: copied) {
            if copied {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { copied = false }
            }
        }
    }
}

private func guideMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
}
