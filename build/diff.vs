package build

import (
    "archive/tar"
    "fs"
    "io"
    "oci/rootfs"
)

/// Paths a RUN's tree has that are the runner's, not the image's: the
/// mounts, what vm adds under /.vertex, and the files Docker bind-mounts
/// over (so a RUN's changes to them aren't kept either).
let ignoredTrees = ["proc", "sys", "dev", "run", ".vertex"]
let ignoredFiles: Set<string> = ["etc/resolv.conf", "etc/hosts", "etc/hostname"]

func ignored(path: string) -> bool {
    if ignoredFiles.contains(path) { return true }
    for t in ignoredTrees where path == t || path.hasPrefix(t + "/") {
        return true
    }
    return false
}

func kindOf(t: tar.FileType) -> rootfs.Kind? {
    switch t {
    case .regular, .contiguous: return rootfs.Kind.file
    case .directory: return rootfs.Kind.directory
    case .symlink: return rootfs.Kind.symlink
    case .link: return rootfs.Kind.hardlink
    case .characterDevice: return rootfs.Kind.charDevice
    case .blockDevice: return rootfs.Kind.blockDevice
    case .fifo: return rootfs.Kind.fifo
    default: return nil
    }
}

/// Whether `h` says something other than what the parent tree has at its
/// path: a directory by its owner and mode (its mtime moves whenever
/// something in it does), anything else by those and its size, mtime and
/// target.
func differs(h: tar.Header, kind: rootfs.Kind, old: rootfs.Entry) -> bool {
    if old.Kind != kind { return true }
    if old.Mode != (uint32(truncatingIfNeeded: h.Mode) & 0o7777) { return true }
    if old.Uid != uint32(truncatingIfNeeded: h.Uid) || old.Gid != uint32(truncatingIfNeeded: h.Gid) { return true }
    if kind == rootfs.Kind.directory { return false }
    if kind == rootfs.Kind.file && old.Size != h.Size { return true }
    if old.ModTime != h.ModTime { return true }
    if kind == rootfs.Kind.symlink && old.Linkname != h.Linkname { return true }
    if kind == rootfs.Kind.hardlink {
        return old.Linkname != ((try? rootfs.Clean(h.Linkname)) ?? h.Linkname)
    }
    return false
}

/// A layer, as an uncompressed tar, of what `tree` -- a tar of a whole
/// filesystem, as a RUN left it -- changes from `parent`: what is new or
/// different, with the directories it is in, and whiteouts for what is
/// gone.
public func Diff(parent: rootfs.Plan, tree: fs.Path) throws -> [uint8] {
    // Pass 1: what the tree has.
    var seen = Set<string>()
    var changed = Set<string>()
    var dirs: [string: tar.Header] = [:]
    do {
        var r = tar.Reader(try fs.Open(tree))
        while let h = try r.Next() {
            guard let path = try? rootfs.Clean(h.Name), !path.isEmpty, !ignored(path),
                  let kind = kindOf(h.Typeflag) else { continue }
            seen.insert(path)
            if kind == rootfs.Kind.directory {
                dirs[path] = h
            }
            if let old = parent.Lookup(path) {
                if differs(h, kind, old) { changed.insert(path) }
            } else {
                changed.insert(path)
            }
        }
        r.Inner.Close()
    }

    // What is gone: the topmost of each removed subtree.
    var gone: [string] = []
    for e in parent.Entries where !seen.contains(e.Path) && !ignored(e.Path) {
        var under = false
        for g in gone where e.Path.hasPrefix(g + "/") {
            under = true
            break
        }
        if !under { gone.append(e.Path) }
    }

    // Every directory that holds a change, so the layer unpacks in order.
    var needDirs = Set<string>()
    func addParents(path: string) {
        var p = path
        while let slash = p.lastIndex(of: "/") {
            p = string(p[..<slash])
            if needDirs.contains(p) { break }
            needDirs.insert(p)
        }
    }
    for p in changed { addParents(p) }
    for g in gone { addParents(g) }
    for p in changed where dirs[p] != nil { needDirs.insert(p) }

    var w = tar.Writer(io.Cursor())
    for d in needDirs.sorted() {
        guard var h = dirs[d] else { continue }
        h.Name = d + "/"
        h.Prefix = ""
        h.Size = 0
        try w.WriteHeader(h)
    }

    // Pass 2: the changed entries that aren't directories, with their data.
    do {
        var r = tar.Reader(try fs.Open(tree))
        while let h = try r.Next() {
            guard let path = try? rootfs.Clean(h.Name), changed.contains(path),
                  h.Typeflag != tar.FileType.directory, kindOf(h.Typeflag) != nil else { continue }
            var out = h
            out.Name = path
            out.Prefix = ""
            if h.Typeflag == tar.FileType.link {
                out.Linkname = (try? rootfs.Clean(h.Linkname)) ?? h.Linkname
            }
            try w.WriteHeader(out)
            if h.Typeflag == tar.FileType.regular || h.Typeflag == tar.FileType.contiguous {
                var buf = [uint8](repeating: 0, count: 65536)
                while true {
                    let n = try r.Read(into: &buf)
                    if n == 0 { break }
                    try w.Write(n == buf.count ? buf : Array(buf[0..<n]))
                }
            }
        }
        r.Inner.Close()
    }

    for g in gone {
        let slash = g.lastIndex(of: "/")
        let dir = slash == nil ? "" : string(g[..<slash!]) + "/"
        let base = slash == nil ? g : string(g[g.index(after: slash!)...])
        try w.WriteHeader(tar.Header(name: dir + ".wh." + base, size: 0, mode: 0o644))
    }
    try w.Close()
    return w.Inner.Bytes
}
