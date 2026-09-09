import Foundation

/// The last line of defence before anything is removed.
///
/// Every destructive action in the app funnels through `validate` first. The
/// checks are deliberately paranoid and deliberately deny-only: resolving a
/// path can take permission away, never grant it. A literal path that is
/// refused stays refused no matter what it resolves to.
enum SafePath {

    /// Removing any of these, or anything under them, breaks the machine.
    /// Dustloft never has a legitimate reason to delete inside them, so they
    /// are refused outright rather than reasoned about per scanner.
    static let systemProtected: [String] = [
        "/System", "/bin", "/sbin", "/usr", "/etc", "/var", "/private",
        "/Library/Extensions", "/Library/Frameworks", "/Applications/Utilities",
        "/cores", "/opt/homebrew/bin", "/opt/homebrew/sbin"
    ]
    // Deliberately not listed: /Volumes. Project roots are chosen by the user
    // and a project on an external drive is a normal thing to want scanned.
    // Blocking the whole mount tree would refuse legitimate work rather than
    // protect anything the scanners would otherwise reach on their own.

    enum Refusal: Equatable {
        case notAbsolute
        case traversal
        case rootItself
        case systemLocation(String)
        case protectedLocation(String)
        case redirectedIntoProtected(String)

        var reason: String {
            switch self {
            case .notAbsolute:                  return "refused: not an absolute path"
            case .traversal:                    return "refused: path traversal"
            case .rootItself:                   return "refused: filesystem root"
            case .systemLocation(let p):        return "refused: system location (\(p))"
            case .protectedLocation(let p):     return "refused: protected location (\(p))"
            case .redirectedIntoProtected(let p): return "refused: resolves into \(p)"
            }
        }
    }

    private static func isUnder(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// Deny-list check against a literal, already-normalised path.
    private static func denied(_ path: String) -> Refusal? {
        if let hit = systemProtected.first(where: { isUnder(path, $0) }) {
            return .systemLocation(hit)
        }
        if let hit = Settings.hardExclusions.first(where: { isUnder(path, $0) }) {
            return .protectedLocation(hit)
        }
        return nil
    }

    /// Returns nil when `path` may be removed, or the reason it may not.
    ///
    /// A symlinked *ancestor* is the case that matters here. If `~/Library/Caches`
    /// is a link into Dropbox, then `~/Library/Caches/x` passes a plain string
    /// check while a delete resolves through the link and destroys synced data.
    /// So the parent is canonicalised and the deny checks run a second time on
    /// the resolved path.
    static func validate(_ path: String) -> Refusal? {
        guard path.hasPrefix("/") else { return .notAbsolute }

        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains("..") { return .traversal }

        let normalised = "/" + parts.joined(separator: "/")
        if normalised == "/" || parts.isEmpty { return .rootItself }

        if let r = denied(normalised) { return r }

        // Resolve the parent rather than the leaf: removing a symlink removes
        // the link itself, which is harmless, but a redirected ancestor is not.
        let parent = (normalised as NSString).deletingLastPathComponent
        let resolvedParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
        if resolvedParent != parent {
            let resolved = (resolvedParent as NSString)
                .appendingPathComponent((normalised as NSString).lastPathComponent)
            if let r = denied(resolved) {
                if case .systemLocation(let p) = r { return .redirectedIntoProtected(p) }
                if case .protectedLocation(let p) = r { return .redirectedIntoProtected(p) }
                return r
            }
        }
        return nil
    }

    /// True when the path itself is a symlink. Elevated deletions refuse these:
    /// under sudo the blast radius of getting it wrong is the whole machine.
    static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            == .typeSymbolicLink
    }

    /// Quote a path for POSIX `sh`.
    ///
    /// The previous form wrapped paths in single quotes without escaping the
    /// single quotes inside them, and the result was handed to
    /// `do shell script … with administrator privileges`. An apostrophe in a
    /// filename — "Kapil's backup" is enough — terminated the quoting early and
    /// the remainder of the path was interpreted as shell, as root.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
