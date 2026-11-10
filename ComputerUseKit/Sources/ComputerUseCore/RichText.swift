import Foundation

/// Rich text as Markdown, with a map back to the plain text it came from.
public enum RichText {
    public typealias Run = (text: String, style: [String: Any])
    // Markers are our choice of Markdown. Measured trees pin **bold** around a
    // whole run. Inline order is innermost first (and is not dictionary order).
    public static let inline = [("strikethrough", "~~", "~~"), ("underline", "<u>", "</u>"),
                                ("superscript", "<sup>", "</sup>"), ("subscript", "<sub>", "</sub>"),
                                ("italic", "*", "*"), ("bold", "**", "**")]
    public static let paragraphs = ["Title": 1, "Heading": 2, "Subheading": 3]
    public static let lists = ["todo": "- [ ] ", "done": "- [x] "]
    public static let collapsed = "</summary>(collapsed, its content is not shown)</details>"
    public static let fence = "```"
    public static let docsHost = "(?i)(?:^|\\.)docs\\.google\\.[a-z.]+$"
    public static func isDocsHost(_ host: String) -> Bool {
        // ICU's $ accepts more Unicode line endings than Python's, and its
        // case-insensitive [a-z] differs for dotted/dotless I. Spell out Python's
        // IGNORECASE alphabet and its optional final LF, with an absolute anchor.
        let pattern = "(?:^|\\.)[dD][oO][cC][sSſ]\\.[gG][oO][oO][gG][lL][eE]\\.[a-zA-Z.İıſK]+(?:\\n)?\\z"
        return host.range(of: pattern, options: .regularExpression) != nil
    }

    private enum StyleError: Error { case invalidInteger }
    private static func integer(_ value: Any?) throws -> Int {
        guard ReadString.truth(value) else { return 0 }
        if let n = value as? NSNumber {
            guard n.doubleValue.isFinite, n.doubleValue >= Double(Int.min), n.doubleValue < Double(Int.max) else { throw StyleError.invalidInteger }
            return n.intValue
        }
        if let s = value as? String {
            let stripped = ReadString.strip(s)
            guard stripped.range(of: "^[+-]?\\d+(?:_\\d+)*$", options: .regularExpression) != nil else { throw StyleError.invalidInteger }
            var digits = ""
            for scalar in stripped.unicodeScalars where scalar != "_" {
                if scalar == "+" || scalar == "-" { digits.unicodeScalars.append(scalar) }
                else if CharacterSet.decimalDigits.contains(scalar), let digit = Character(String(scalar)).wholeNumberValue { digits += String(digit) }
                else { throw StyleError.invalidInteger }
            }
            if let n = Int(digits) { return n }
        }
        throw StyleError.invalidInteger
    }
    public static func linePrefix(_ style: [String: Any]) throws -> String {
        let hasHeading = ReadString.truth(style["heading"])
        let level = hasHeading ? try integer(style["heading"]) : paragraphs[style["paragraph"] as? String ?? ""] ?? 0
        let quote = try integer(style["quote"])
        let bullet = ReadString.truth(style["list"]) ? lists[style["list"] as? String ?? ""] ?? "- " : ""
        return String(repeating: "> ", count: max(0, quote)) + (hasHeading || level != 0 ? String(repeating: "#", count: max(0, level)) + " " : "") + bullet
    }
    public static func merged(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for (text, style) in runs {
            if let last = out.last, NSDictionary(dictionary: last.style).isEqual(to: style) {
                out[out.count - 1].text += text
            } else if !text.isEmpty { out.append((text, style)) }
        }
        return out
    }
    /// For each printed Unicode scalar, its offset in the source. The last entry
    /// is the source length (including when the output is empty).
    public static func markdown(_ attributed: [Run]) throws -> (String, [Int]) {
        var out: [String] = [], offsets: [Int] = [], source = 0
        func plain(_ text: String) {
            if !text.isEmpty {
                out.append(text)
                let n = ReadString.count(text)
                offsets += Array(source..<(source + n)); source += n
            }
        }
        func mark(_ text: String) {
            if !text.isEmpty { out.append(text); offsets += Array(repeating: source, count: ReadString.count(text)) }
        }
        for (text, style) in merged(attributed) {
            let code = ReadString.truth(style["code"]) || style["paragraph"] as? String == "Fixed width"
            var opening = inline.filter { ReadString.truth(style[$0.0]) }.map { $0.1 }
            var closing = inline.reversed().filter { ReadString.truth(style[$0.0]) }.map { $0.2 }
            if ReadString.truth(style["link"]) { opening = ["["] + opening; closing += ["](\(Tree.text(style["link"], cap: false)))"] }
            if ReadString.truth(style["collapsed"]) { opening = ["<details><summary>"] + opening; closing += [collapsed] }
            if code { opening = [fence + "\n"]; closing = ["\n" + fence] }
            // Markers hug words: whitespace at either end stays outside.
            var body = code || opening.isEmpty ? text : ReadString.strip(text)
            if body.isEmpty { opening = []; closing = []; body = text }
            let start = text.range(of: body, options: .literal).map { text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: $0.lowerBound) } ?? 0
            let prefix = try linePrefix(style)
            plain(ReadString.slice(text, 0, start))
            for (number, line) in body.components(separatedBy: "\n").enumerated() {
                if number != 0 { plain("\n") }
                if !line.isEmpty && (out.isEmpty || out.last!.hasSuffix("\n")) { mark(prefix) }
                if number == 0 { mark(opening.joined()) }
                plain(line)
            }
            mark(closing.joined())
            plain(ReadString.slice(text, start + ReadString.count(body)))
        }
        return (out.joined(), offsets + [source])
    }
    /// The printed text must contain prefix + target + suffix exactly once. An
    /// overlapping second hit is still ambiguous. Returned offsets are scalars.
    public static func find(_ text: String, _ offsets: [Int]?, _ target: String, prefix: String = "", suffix: String = "") -> (Int, Int)? {
        let hay = Array(text.unicodeScalars), needle = Array((prefix + target + suffix).unicodeScalars)
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        var hits: [Int] = []
        for at in 0...(hay.count - needle.count) where hay[at..<(at + needle.count)].elementsEqual(needle) {
            hits.append(at); if hits.count > 1 { return nil }
        }
        guard let first = hits.first else { return nil }
        let start = first + ReadString.count(prefix), end = start + ReadString.count(target)
        guard let offsets else { return (start, end) }
        return (offsets[start], target.isEmpty ? offsets[start] : offsets[end - 1] + 1)
    }
}
