import Foundation

struct GuideTopic: Identifiable {
    let id: Int
    let title: String
    let summary: String
    let groups: [GuideGroup]

    var symbol: String {
        switch title {
        case "Quick start": return "sparkles"
        case "Client profiles": return "person.2"
        case "Colors & start pages": return "paintpalette"
        case "Run setup": return "play.circle"
        case "Dock apps": return "square.grid.2x2"
        case "Login items": return "checklist"
        case "Permissions & privacy": return "hand.raised"
        case "Troubleshooting": return "wrench.and.screwdriver"
        case "Command-line setup": return "terminal"
        default: return "doc.text"
        }
    }
}

struct GuideGroup: Identifiable {
    let id: Int
    let title: String?
    var blocks: [GuideBlock]
}

enum GuideBlock {
    case paragraph(String)
    case bullet(String)
    case step(String, String)
    case callout(String)
    case code(String, String)
}

// Handles the deliberately small Markdown vocabulary used by GUIDE.md.
enum GuideDocument {
    static func parse(_ markdown: String) -> [GuideTopic] {
        var topics: [GuideTopic] = []
        var title: String?
        var groupTitle: String?
        var groups: [GuideGroup] = []
        var blocks: [GuideBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var codeLanguage: String?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }

        func flushGroup() {
            flushParagraph()
            if !blocks.isEmpty {
                groups.append(GuideGroup(id: groups.count, title: groupTitle, blocks: blocks))
            }
            blocks.removeAll()
            groupTitle = nil
        }

        func flushTopic() {
            flushGroup()
            if let title {
                var summary = ""
                if let firstGroup = groups.first,
                   firstGroup.title == nil,
                   case .paragraph(let text) = firstGroup.blocks.first {
                    summary = text
                    groups[0].blocks.removeFirst()
                    if groups[0].blocks.isEmpty { groups.removeFirst() }
                }
                topics.append(GuideTopic(id: topics.count, title: title, summary: summary, groups: groups))
            }
            groups.removeAll()
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                if let language = codeLanguage {
                    blocks.append(.code(language, code.joined(separator: "\n")))
                    code.removeAll()
                    codeLanguage = nil
                } else {
                    codeLanguage = String(trimmed.dropFirst(3))
                }
            } else if codeLanguage != nil {
                code.append(line)
            } else if trimmed.hasPrefix("## ") {
                flushTopic()
                title = String(trimmed.dropFirst(3))
            } else if trimmed.hasPrefix("### ") {
                flushGroup()
                groupTitle = String(trimmed.dropFirst(4))
            } else if trimmed.hasPrefix("# ") {
                continue
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                let text = String(trimmed.dropFirst(2))
                if case .callout(let previous) = blocks.last {
                    blocks[blocks.count - 1] = .callout(previous + " " + text)
                } else {
                    blocks.append(.callout(text))
                }
            } else if trimmed.hasPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else if let prefix = trimmed.range(of: #"^\d+\. "#, options: .regularExpression) {
                flushParagraph()
                let number = String(trimmed[prefix].dropLast(2))
                blocks.append(.step(number, String(trimmed[prefix.upperBound...])))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let language = codeLanguage { blocks.append(.code(language, code.joined(separator: "\n"))) }
        flushTopic()
        return topics
    }
}
