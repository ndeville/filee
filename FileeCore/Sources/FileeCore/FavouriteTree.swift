import Foundation

/// 1 row of the sidebar's Favourites tree: a favourite, or a folder that holds 2 or more favourites.
public struct FavouriteNode: Equatable, Sendable {
    public var name: String
    public var path: String
    public var isFavourite: Bool
    public var children: [FavouriteNode]

    public init(name: String, path: String, isFavourite: Bool, children: [FavouriteNode] = []) {
        self.name = name
        self.path = path
        self.isFavourite = isFavourite
        self.children = children
    }

    /// "Home(Dropbox(Family Work(Clients)))", for tests and QA.
    public var outline: String {
        let mark = isFavourite ? "" : "+"
        return children.isEmpty ? mark + name : mark + name + "(" + children.map(\.outline).joined(separator: " ") + ")"
    }
}

/// Favourites as a tree from the root (SPEC 6): each favourite sits under the closest favourite that contains it.
/// A folder that isn't a favourite but holds 2 or more of them becomes a branch ("Dropbox"); a chain of such folders
/// with 1 branch inside shows as 1 row ("Dropbox/Work", or "…/T/filee-qa" past 2 folders). Siblings sort by path.
public enum FavouriteTree {
    public static func build(_ favourites: [(name: String, path: String)], home: String) -> [FavouriteNode] {
        var seen = Set<String>()
        let favs = favourites.compactMap { f -> Fav? in
            let p = standard(f.path)
            guard seen.insert(p).inserted else { return nil }
            return Fav(name: f.name, path: p)
        }
        var kids: [String: [Fav]] = [:]
        var top: [Fav] = []
        for f in favs {
            let parent = favs.filter { $0.path != f.path && contains($0.path, f.path) }.max { $0.path.count < $1.path.count }
            if let parent { kids[parent.path, default: []].append(f) } else { top.append(f) }
        }
        let homeDir = standard(home)
        let entries = top.map { f -> Entry in
            // Without a Home favourite, folders in the home folder group from there, not from /Users.
            let base = contains(homeDir, f.path) ? homeDir : "/"
            return Entry(fav: f, rel: components(of: f.path, under: base), base: base)
        }
        return group(entries, kids: kids)
    }

    struct Fav {
        let name: String
        let path: String
    }

    struct Entry {
        let fav: Fav
        let rel: [String]
        let base: String
    }

    private static func node(_ f: Fav, kids: [String: [Fav]]) -> FavouriteNode {
        let entries = (kids[f.path] ?? []).map { Entry(fav: $0, rel: components(of: $0.path, under: f.path), base: f.path) }
        return FavouriteNode(name: f.name, path: f.path, isFavourite: true, children: group(entries, kids: kids))
    }

    private static func group(_ entries: [Entry], kids: [String: [Fav]]) -> [FavouriteNode] {
        var order: [String] = []
        var buckets: [String: [Entry]] = [:]
        for e in entries {
            guard let first = e.rel.first else { continue }
            let key = (e.base as NSString).appendingPathComponent(first)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(e)
        }
        var out: [FavouriteNode] = []
        for key in order {
            let members = buckets[key]!
            if members.count == 1 {
                out.append(node(members[0].fav, kids: kids))
                continue
            }
            let inner = members.map { Entry(fav: $0.fav, rel: Array($0.rel.dropFirst()), base: key) }
            var branch = FavouriteNode(name: (key as NSString).lastPathComponent, path: key, isFavourite: false, children: group(inner, kids: kids))
            while branch.children.count == 1, !branch.children[0].isFavourite {
                let only = branch.children[0]
                branch = FavouriteNode(name: only.name, path: only.path, isFavourite: false, children: only.children)
            }
            // The chain from `key` down: "Dropbox/Work". A long chain keeps its last 2 folders: "…/T/filee-qa".
            let parts = components(of: branch.path, under: (key as NSString).deletingLastPathComponent)
            branch.name = parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : parts.joined(separator: "/")
            out.append(branch)
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// True when `inner` is inside `outer` (not the same folder).
    public static func contains(_ outer: String, _ inner: String) -> Bool {
        outer == "/" ? inner != "/" : inner.hasPrefix(outer + "/")
    }

    static func components(of path: String, under base: String) -> [String] {
        let rest = base == "/" ? String(path.dropFirst()) : String(path.dropFirst(base.count + 1))
        return rest.split(separator: "/").map(String.init)
    }

    static func standard(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
