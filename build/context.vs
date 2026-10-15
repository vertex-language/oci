package build

import "fs"

/// .dockerignore: patterns of context paths COPY and ADD don't see. A
/// later pattern wins; `!pattern` brings a path back; `**` is any number
/// of directories.
struct Ignore {
    var rules: [(bool, [string])] = []

    init(_ text: string?) {
        guard let t = text else { return }
        for line in t.split(separator: "\n") {
            var p = string(line)
            while p.hasSuffix("\r") || p.hasSuffix(" ") { p = string(p.dropLast()) }
            while p.hasPrefix(" ") { p = string(p.dropFirst()) }
            if p.isEmpty || p.hasPrefix("#") { continue }
            var keep = false
            if p.hasPrefix("!") {
                keep = true
                p = string(p.dropFirst())
            }
            while p.hasPrefix("/") || p.hasPrefix("./") { p = p.hasPrefix("/") ? string(p.dropFirst()) : string(p.dropFirst(2)) }
            while p.hasSuffix("/") { p = string(p.dropLast()) }
            rules.append((keep, p.split(separator: "/").map { string($0) }))
        }
    }

    /// Whether `path` (relative to the context) is left out. A path under
    /// an ignored directory is too.
    func Ignored(_ path: string) -> bool {
        let parts = path.split(separator: "/").map { string($0) }
        var out = false
        for (keep, pattern) in rules {
            // The path or a directory above it.
            var hit = false
            var n = parts.count
            while n >= 1 && !hit {
                hit = matchParts(pattern, Array(parts[0..<n]))
                n -= 1
            }
            if hit { out = !keep }
        }
        return out
    }
}

/// Whether path components match pattern components, `**` matching any
/// number of them.
func matchParts(_ pat: [string], _ parts: [string]) -> bool {
    if pat.isEmpty { return parts.isEmpty }
    if pat[0] == "**" {
        let rest = Array(pat.dropFirst())
        var i = 0
        while i <= parts.count {
            if matchParts(rest, Array(parts[i...])) { return true }
            i += 1
        }
        return false
    }
    if parts.isEmpty { return false }
    return Glob(pat[0], parts[0]) && matchParts(Array(pat.dropFirst()), Array(parts.dropFirst()))
}

/// A shell glob within one path component: `*`, `?`, `[abc]`.
public func Glob(_ pattern: string, _ name: string) -> bool {
    let p = Array(pattern)
    let n = Array(name)
    return globAt(p, 0, n, 0)
}

func globAt(_ p: [Character], _ pi: int, _ n: [Character], _ ni: int) -> bool {
    if pi == p.count { return ni == n.count }
    let c = p[pi]
    if c == "*" {
        var k = ni
        while k <= n.count {
            if globAt(p, pi + 1, n, k) { return true }
            k += 1
        }
        return false
    }
    if ni == n.count { return false }
    if c == "?" { return globAt(p, pi + 1, n, ni + 1) }
    if c == "[" {
        var j = pi + 1
        var ok = false
        while j < p.count && p[j] != "]" {
            if p[j] == n[ni] { ok = true }
            j += 1
        }
        return ok && j < p.count && globAt(p, j + 1, n, ni + 1)
    }
    return c == n[ni] && globAt(p, pi + 1, n, ni + 1)
}

/// The context paths a COPY source names: itself, or what its glob
/// matches, minus what .dockerignore leaves out.
func contextMatches(_ context: string, _ source: string, _ ignore: Ignore) throws -> [string] {
    var rel = source
    while rel.hasPrefix("/") || rel.hasPrefix("./") { rel = rel.hasPrefix("/") ? string(rel.dropFirst()) : string(rel.dropFirst(2)) }
    while rel.hasSuffix("/") { rel = string(rel.dropLast()) }
    if rel.isEmpty || rel == "." { return [""] }
    if rel.split(separator: "/").contains("..") { throw BuildError.notInContext(source) }
    let hasGlob = rel.contains("*") || rel.contains("?") || rel.contains("[")
    if !hasGlob {
        if ignore.Ignored(rel) || !fs.Exists(fs.Path(context) / rel) { return [] }
        return [rel]
    }
    // Expand one component at a time.
    var found: [string] = [""]
    for part in rel.split(separator: "/").map({ string($0) }) {
        var next: [string] = []
        for base in found {
            let dir = base.isEmpty ? fs.Path(context) : fs.Path(context) / base
            guard let entries = try? fs.ReadDir(dir) else { continue }
            for e in entries.sorted(by: { $0.Name < $1.Name }) where Glob(part, e.Name) {
                next.append(base.isEmpty ? e.Name : base + "/" + e.Name)
            }
        }
        found = next
    }
    return found.filter { !ignore.Ignored($0) }
}

/// Every entry under a context directory, parents first, with its data
/// (files) or target (symlinks); `rel` is "" for the whole context.
func walk(_ context: string, _ rel: string, _ ignore: Ignore,
          _ visit: (string, fs.FileMetadata, [uint8], string) throws -> Void) throws {
    let dir = rel.isEmpty ? fs.Path(context) : fs.Path(context) / rel
    for e in try fs.ReadDir(dir).sorted(by: { $0.Name < $1.Name }) {
        let path = rel.isEmpty ? e.Name : rel + "/" + e.Name
        if ignore.Ignored(path) { continue }
        let full = fs.Path(context) / path
        let meta = try fs.Stat(full, followSymlinks: false)
        if meta.IsDir() {
            try visit(path, meta, [], "")
            try walk(context, path, ignore, visit)
        } else if meta.IsSymlink() {
            try visit(path, meta, [], (try fs.ReadLink(full)).Value)
        } else {
            try visit(path, meta, try fs.ReadFile(full), "")
        }
    }
}
