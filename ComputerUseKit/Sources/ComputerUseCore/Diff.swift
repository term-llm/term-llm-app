import Foundation

public struct Change {
    /// none, update, insert, remove.
    public var kind: String
    /// Node position in its own list (old list for removes).
    public var at: Int
    /// The node, or its whole subtree for inserts/removes.
    public var lines: [Line]
    public var old: Line?
    public init(_ kind: String, _ at: Int, _ lines: [Line], _ old: Line? = nil) {
        self.kind = kind; self.at = at; self.lines = lines; self.old = old
    }
}

/// One pairing serves twice: by element to retain numbers, by number to tell the
/// model what changed. Parents must pair before their children can pair.
public enum Diff {
    public static let header = "What changed in window \"{}\" since the last read: a line that starts with ~ changed, a line that starts with + is new. Elements that went away are listed by ID."
    public static let noChange = "Nothing changed in window \"{}\" since the last read."
    public static let removed = "IDs of elements that went away: "
    public static let marks = ["update": "~", "insert": "+"]
    public static func line(_ node: Line) -> String { String(repeating: "\t", count: max(0, node.depth)) + Render.numbered(node, true) }
    public static func ranges<S: Sequence>(_ ids: S) -> String where S.Element == Int {
        var runs: [(Int, Int)] = []
        for n in Set(ids).sorted() {
            if let last = runs.last, n == last.1 + 1 { runs[runs.count - 1].1 = n }
            else { runs.append((n, n)) }
        }
        return runs.map { $0.0 == $0.1 ? String($0.0) : "\($0.0)-\($0.1)" }.joined(separator: ", ")
    }
    public static func children(_ lines: [Line]) -> [Int: [Int]] {
        var children = [-1: [Int]()], open: [Int] = []
        for (at, node) in lines.enumerated() {
            while let last = open.last, lines[last].depth >= node.depth { open.removeLast() }
            children[open.last ?? -1, default: []].append(at)
            children[at] = []; open.append(at)
        }
        return children
    }
    public static func subtree(_ lines: [Line], _ at: Int) -> [Line] {
        var end = at + 1
        while end < lines.count && lines[end].depth > lines[at].depth { end += 1 }
        return Array(lines[at..<end])
    }
    /// Positions of one longest strictly increasing run (bisect_left tie-breaking).
    public static func increasing(_ values: [Int]) -> Set<Int> {
        var ends: [Int] = [], last: [Int] = [], before: [Int?] = []
        for (at, value) in values.enumerated() {
            var lo = 0, hi = ends.count
            while lo < hi { let mid = (lo + hi) / 2; if ends[mid] < value { lo = mid + 1 } else { hi = mid } }
            before.append(lo == 0 ? nil : last[lo - 1])
            if lo == ends.count { ends.append(value); last.append(at) }
            else { ends[lo] = value; last[lo] = at }
        }
        var kept: Set<Int> = [], at = last.last
        while let i = at { kept.insert(i); at = before[i] }
        return kept
    }
    public static func pair<Key: Equatable>(_ old: [Line], _ new: [Line], key: (Line) -> Key) -> [Change] {
        func equal(_ a: Key, _ b: Key) -> Bool {
            // Swift's String equality normalizes Unicode; Python's does not.
            if let a = a as? String, let b = b as? String { return ReadString.equal(a, b) }
            if let a = a as? [String], let b = b as? [String] { return ReadString.equal(a, b) }
            return a == b
        }
        let oc = children(old), nc = children(new)
        var changes: [Change] = [], queue = [(-1, -1)], cursor = 0
        while cursor < queue.count {
            let (op, np) = queue[cursor]; cursor += 1
            let olds = oc[op]!, news = nc[np]!
            var same = 0
            while same < min(olds.count, news.count) && equal(key(old[olds[same]]), key(new[news[same]])) { same += 1 }
            // An ordered dictionary in Python. Linear lookup also handles AX
            // equality without relying on a pointer hash (hashes may collide).
            var rest: [(Key, Int)] = []
            for at in olds.dropFirst(same) where !rest.contains(where: { equal($0.0, key(old[at])) }) { rest.append((key(old[at]), at)) }
            var found: [(Int, Int)] = []
            for at in news.dropFirst(same) {
                if let i = rest.firstIndex(where: { equal($0.0, key(new[at])) }) { found.append((at, rest.remove(at: i).1)) }
            }
            let order = increasing(found.map { $0.1 })
            var paired: [Int: Int] = [:]
            for i in 0..<same { paired[news[i]] = olds[i] }
            for i in order { paired[found[i].0] = found[i].1 }
            for at in news {
                guard let was = paired[at] else { changes.append(Change("insert", at, subtree(new, at))); continue }
                if !oc[was]!.isEmpty || !nc[at]!.isEmpty { queue.append((was, at)) }
                changes.append(Change(ReadString.equal(old[was].text, new[at].text) ? "none" : "update", at, [new[at]], old[was]))
            }
            // Out-of-order siblings are inserts; their old nodes are dropped
            // without a remove. Only keys left in rest produce removes.
            for (_, at) in rest { changes.append(Change("remove", at, subtree(old, at))) }
        }
        return changes
    }
    /// A changed line costs 1, added subtree costs one per node, removed IDs cost
    /// one line. Count cost before writing anything; nil means show a full tree.
    public static func text(_ changes: [Change], _ title: String, _ footer: String, _ budget: Int) -> String? {
        let shown = changes.enumerated().filter { marks[$0.element.kind] != nil }.sorted {
            $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at
        }.map { $0.element }
        let goneLines = changes.filter { $0.kind == "remove" }.flatMap { $0.lines }
        let cost = shown.reduce(0) { $0 + $1.lines.count } + (goneLines.isEmpty ? 0 : 1)
        if cost > budget { return nil }
        // Like Python, count the removed summary before requiring numbered IDs.
        // Rendering a diff is only valid after numbering (Revisions does that).
        let gone = goneLines.compactMap { $0.id }
        precondition(gone.count == goneLines.count, "Number removed lines before rendering a diff")
        var parts = [(cost == 0 ? noChange : header).replacingOccurrences(of: "{}", with: title)]
        if cost != 0 {
            if !gone.isEmpty { parts.append(removed + ranges(gone)) }
            parts += shown.flatMap { c in c.lines.map { marks[c.kind]! + line($0) } }
        }
        if !footer.isEmpty { parts.append(footer) }
        return parts.joined(separator: "\n")
    }
}
