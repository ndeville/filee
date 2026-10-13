import Foundation

/// Fuzzy matching for file names and palette entries: subsequence match with bonuses for word starts,
/// runs and an early start. Smart case: an upper-case letter in the query makes the match case sensitive.
public enum Fuzzy {
    /// The score of `candidate` for `query`, or nil when it doesn't match. Higher is better.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.utf8).filter { $0 != 32 }
        if q.isEmpty { return 0 }
        let sensitive = query.contains { $0.isUppercase }
        let c = Array(candidate.utf8)
        guard q.count <= c.count else { return nil }
        return score(prepared: sensitive ? q : q.map(lower), sensitive ? c : c.map(lower))
    }

    /// The query folded like NaturalOrder keys (case and accents), spaces removed.
    public static func prepare(_ query: String) -> [UInt8] {
        NaturalOrder.key(query).filter { $0 != 32 }
    }

    /// Score on prepared bytes: the query from `prepare`, the candidate a NaturalOrder key. No allocation.
    public static func score(prepared qq: [UInt8], _ cc: [UInt8]) -> Int? {
        guard !qq.isEmpty else { return 0 }
        guard qq.count <= cc.count else { return nil }

        // Best of: greedy from each position where the first query byte matches (up to 8 starts).
        var best: Int?
        var starts = 0
        var i = 0
        while i < cc.count, starts < 8 {
            if cc[i] == qq[0] {
                starts += 1
                if let s = greedy(qq, cc, from: i) { best = max(best ?? Int.min, s) }
            }
            i += 1
        }
        guard var s = best else { return nil }
        // A contiguous hit anywhere wins over a scattered one.
        if contains(cc, qq) { s += 20 + qq.count * 2 }
        if cc.starts(with: qq) { s += 25 }
        return s - cc.count / 8
    }

    private static func greedy(_ q: [UInt8], _ c: [UInt8], from: Int) -> Int? {
        var score = 0
        var qi = 0
        var last = -2
        var i = from
        while i < c.count, qi < q.count {
            if c[i] == q[qi] {
                var bonus = 1
                if i == last + 1 { bonus += 5 }
                if i == 0 || isSeparator(c[i - 1]) { bonus += 8 }
                if last >= 0 { score -= min(3, i - last - 1) }
                score += bonus
                last = i
                qi += 1
            }
            i += 1
        }
        guard qi == q.count else { return nil }
        // Letters scattered across a long name aren't a match: the hit must sit in a short span.
        if last - from + 1 > q.count * 3 + 6 { return nil }
        return score - from / 4
    }

    private static func contains(_ c: [UInt8], _ q: [UInt8]) -> Bool {
        guard q.count <= c.count else { return false }
        var i = 0
        while i + q.count <= c.count {
            if c[i] == q[0], Array(c[i..<(i + q.count)]) == q { return true }
            i += 1
        }
        return false
    }

    @inline(__always) private static func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }

    @inline(__always) private static func isSeparator(_ b: UInt8) -> Bool {
        b == 47 || b == 45 || b == 95 || b == 32 || b == 46 // / - _ space .
    }

    /// Like `matches`, over prepared keys (NaturalOrder). Smart case falls back to the string path.
    public static func matches(keys: [[UInt8]], names: [String], query: String) -> (indices: [Int], best: Int?) {
        if query.contains(where: { $0.isUppercase }) { return matches(names, query: query) { $0 } }
        let q = prepare(query)
        if q.isEmpty { return (Array(keys.indices), nil) }
        var out: [Int] = []
        var best: (Int, Int)?
        for i in keys.indices {
            guard let s = score(prepared: q, keys[i]) else { continue }
            out.append(i)
            if best == nil || s > best!.1 { best = (i, s) }
        }
        return (out, best?.0)
    }

    /// Indices of `items` that match, in their original order, and the index of the best match.
    /// The folder filter uses it: the list keeps its sort order and the cursor goes to the best hit.
    public static func matches<T>(_ items: [T], query: String, key: (T) -> String) -> (indices: [Int], best: Int?) {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return (Array(items.indices), nil) }
        var out: [Int] = []
        var best: (Int, Int)?
        for (i, item) in items.enumerated() {
            guard let s = score(query, key(item)) else { continue }
            out.append(i)
            if best == nil || s > best!.1 { best = (i, s) }
        }
        return (out, best?.0)
    }

    /// Indices of `items` that match, best first. Ties keep the original order.
    public static func filter<T>(_ items: [T], query: String, key: (T) -> String) -> [Int] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return Array(items.indices) }
        var scored: [(Int, Int)] = []
        scored.reserveCapacity(items.count / 4)
        for (i, item) in items.enumerated() {
            if let s = score(query, key(item)) { scored.append((i, s)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return scored.map(\.0)
    }
}
