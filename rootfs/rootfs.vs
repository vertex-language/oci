// Package rootfs makes an image's layers into one filesystem tree.
//
// Layers are tars applied bottom first; a layer removes what is below it
// with whiteouts (`.wh.<name>` deletes <name>, `.wh..wh..opq` empties
// its directory of what lower layers put there). Merge reads the layers'
// headers and works out the tree that results -- which entry, from which
// layer, is at each path -- without writing anything. Emit then streams
// the layers once more and hands each surviving entry to a Sink:
//
//   - CpioSink writes a newc archive: the tree exactly, owners, modes and
//     device nodes included -- what a VM boots as its initramfs.
//   - DirSink writes the tree into a host directory, as far as the host
//     allows: owners and device nodes need root, and a case-insensitive
//     filesystem can't hold names that differ only by case.
//
// A Sink is given directories first, then links and special files, then
// the files' contents a layer at a time, and hard links last -- so a
// parent is always there before what is in it.
package rootfs

import (
    "archive/tar"
    "compress/gzip"
    "compress/zstd"
    "fs"
    "io"
    "oci/digest"
    "oci/spec"
    "oci/store"
)

public enum RootfsError: Error, CustomStringConvertible {
    case unsafePath(string)
    case unsupportedLayer(string)

    public var description: string {
        switch self {
        case .unsafePath(let p): return "a layer names a path outside the root: \(p)"
        case .unsupportedLayer(let t): return "unsupported layer media type: \(t)"
        }
    }
}

public enum Kind: Equatable, CustomStringConvertible {
    case file
    case directory
    case symlink
    case hardlink
    case charDevice
    case blockDevice
    case fifo

    public var description: string {
        switch self {
        case .file: return "file"
        case .directory: return "directory"
        case .symlink: return "symlink"
        case .hardlink: return "hardlink"
        case .charDevice: return "char device"
        case .blockDevice: return "block device"
        case .fifo: return "fifo"
        }
    }
}

/// One path of the merged tree.
public struct Entry {
    /// Relative to the root, no leading "/": "usr/bin/env".
    public var Path: string
    public var Kind: Kind
    /// Permission bits, setuid/setgid/sticky included (no type bits).
    public var Mode: uint32
    public var Uid: uint32
    public var Gid: uint32
    public var ModTime: int64
    public var Size: int64
    /// A symlink's target, or the path a hard link shares a file with.
    public var Linkname: string
    public var DevMajor: uint32
    public var DevMinor: uint32
    /// Which layer it came from, bottom 0.
    public var Layer: int
}

/// What receives the merged tree.
public protocol Sink: AnyObject {
    /// One entry. `data` is a file's contents; empty for anything else.
    func Add(e: Entry, data: [uint8]) throws
    /// Called once every entry has been added.
    func Finish() throws
}

/// A layer as a stream of tar bytes, decompressed if it is gzipped.
public struct LayerStream: io.Reader {
    var file: fs.File?
    var gz: gzip.Reader<fs.File>?
    var zs: zstd.Reader<fs.File>?

    public init(path: fs.Path, mediaType: string) throws {
        let f = try fs.Open(path)
        if spec.MediaType.IsGzipLayer(mediaType) || isGzip(f) {
            gz = gzip.Reader(f)
        } else if spec.MediaType.IsZstdLayer(mediaType) || isZstd(f) {
            zs = zstd.Reader(f)
        } else if mediaType.hasSuffix("+zstd") {
            throw RootfsError.unsupportedLayer(mediaType)
        } else {
            file = f
        }
    }

    public mutating func Read(into buffer: inout [uint8]) throws -> int {
        if gz != nil {
            return try gz!.Read(into: &buffer)
        }
        if zs != nil {
            return try zs!.Read(into: &buffer)
        }
        return try file!.Read(into: &buffer)
    }

    public func Close() {
        if let f = file { try? f.Close() }
        if let g = gz { try? g.Inner.Close() }
        if let z = zs { try? z.Inner.Close() }
    }
}

/// Whether a file starts with gzip's magic; it is left at its start.
func isGzip(f: fs.File) -> bool {
    var b = [uint8](repeating: 0, count: 2)
    let n = (try? f.Read(into: &b, at: 0)) ?? 0
    return n == 2 && b[0] == 0x1F && b[1] == 0x8B
}

/// Whether a file starts with zstd's magic.
func isZstd(f: fs.File) -> bool {
    var b = [uint8](repeating: 0, count: 4)
    let n = (try? f.Read(into: &b, at: 0)) ?? 0
    return n == 4 && b[0] == 0x28 && b[1] == 0xB5 && b[2] == 0x2F && b[3] == 0xFD
}

/// A layer's blob and type.
public struct Layer {
    public var Path: fs.Path
    public var MediaType: string

    public init(path: fs.Path, mediaType: string) {
        Path = path
        MediaType = mediaType
    }
}

/// The layers of an image in a store, bottom first.
public func Layers(of img: store.Image, in st: store.Store) throws -> [Layer] {
    var out: [Layer] = []
    for l in img.Manifest.Layers {
        out.append(Layer(path: st.BlobPath(try digest.Digest.Parse(l.Digest)), mediaType: l.MediaType))
    }
    return out
}

/// A path from a tar as a path in the tree: no "./", no leading or
/// trailing "/", and nothing that climbs out. "" is the root itself.
public func Clean(name: string) throws -> string {
    var parts: [string] = []
    for p in name.split(separator: "/") {
        let s = string(p)
        if s == "." || s.isEmpty { continue }
        if s == ".." { throw RootfsError.unsafePath(name) }
        parts.append(s)
    }
    return parts.joined(separator: "/")
}

func kindOf(t: tar.FileType) -> Kind? {
    switch t {
    case .regular, .contiguous: return Kind.file
    case .directory: return Kind.directory
    case .symlink: return Kind.symlink
    case .link: return Kind.hardlink
    case .characterDevice: return Kind.charDevice
    case .blockDevice: return Kind.blockDevice
    case .fifo: return Kind.fifo
    default: return nil
    }
}

/// The tree a stack of layers makes.
public final class Plan {
    public let Layers: [Layer]
    var entries: [string: Entry] = [:]
    /// Whiteouts applied, for a summary.
    public private(set) var Whiteouts: int = 0

    init(layers: [Layer]) {
        Layers = layers
    }

    /// Every entry, parents before children.
    public var Entries: [Entry] {
        entries.keys.sorted().map { entries[$0]! }
    }

    public var Count: int { entries.count }

    /// The entry at a path, if the tree has one.
    public func Lookup(path: string) -> Entry? {
        entries[(try? Clean(path)) ?? path]
    }

    /// Bytes of file contents in the tree.
    /// How many hard links the tree has to each file that has any.
    public var LinkCounts: [string: int] {
        var n: [string: int] = [:]
        for (_, e) in entries where e.Kind == Kind.hardlink {
            if let t = entries[e.Linkname], t.Kind == Kind.file {
                n[e.Linkname] = (n[e.Linkname] ?? 1) + 1
            }
        }
        return n
    }

    public var FileBytes: int64 {
        var n: int64 = 0
        for (_, e) in entries where e.Kind == Kind.file { n += e.Size }
        return n
    }

    /// Removes `path` and everything under it that came from below `layer`.
    func remove(path: string, below layer: int, keepSelf: bool) {
        let prefix = path.isEmpty ? "" : path + "/"
        var doomed: [string] = []
        for (k, e) in entries where e.Layer < layer {
            if (!keepSelf && k == path) || (k.hasPrefix(prefix) && k != path) {
                doomed.append(k)
            }
        }
        for k in doomed { entries[k] = nil }
    }

    func apply(h: tar.Header, layer: int) throws {
        let path = try Clean(h.Name)
        if path.isEmpty { return }
        let slash = path.lastIndex(of: "/")
        let dir = slash == nil ? "" : string(path[..<slash!])
        let base = slash == nil ? path : string(path[path.index(after: slash!)...])
        if base == ".wh..wh..opq" {
            remove(dir, below: layer, keepSelf: true)
            Whiteouts += 1
            return
        }
        if base.hasPrefix(".wh.") {
            let target = (dir.isEmpty ? "" : dir + "/") + string(base.dropFirst(4))
            remove(target, below: layer + 1, keepSelf: false)
            Whiteouts += 1
            return
        }
        guard let kind = kindOf(h.Typeflag) else { return }
        // What this replaces goes, and if it was a directory and this
        // isn't, so does what was in it.
        if let old = entries[path], old.Kind == Kind.directory && kind != Kind.directory {
            remove(path, below: layer + 1, keepSelf: false)
        }
        var link = h.Linkname
        if kind == Kind.hardlink {
            link = try Clean(link)
        }
        entries[path] = Entry(Path: path, Kind: kind, Mode: uint32(truncatingIfNeeded: h.Mode) & 0o7777,
                              Uid: uint32(truncatingIfNeeded: h.Uid), Gid: uint32(truncatingIfNeeded: h.Gid),
                              ModTime: h.ModTime, Size: kind == Kind.file ? h.Size : 0, Linkname: link,
                              DevMajor: uint32(truncatingIfNeeded: h.Devmajor),
                              DevMinor: uint32(truncatingIfNeeded: h.Devminor), Layer: layer)
    }

    /// Hands the tree to `sink`: directories, then symlinks and special
    /// files, then each layer's files as it is read, then hard links.
    public func Emit(to sink: Sink) throws {
        let all = Entries
        for e in all where e.Kind == Kind.directory {
            try sink.Add(e, [])
        }
        for e in all where e.Kind != Kind.directory && e.Kind != Kind.file && e.Kind != Kind.hardlink {
            try sink.Add(e, [])
        }
        for (i, layer) in Layers.enumerated() {
            var r = tar.Reader(try LayerStream(path: layer.Path, mediaType: layer.MediaType))
            while let h = try r.Next() {
                guard h.Typeflag == tar.FileType.regular || h.Typeflag == tar.FileType.contiguous,
                      let path = try? Clean(h.Name),
                      let e = entries[path], e.Layer == i, e.Kind == Kind.file else { continue }
                let data = try r.ReadAll()
                try sink.Add(e, data)
            }
            r.Inner.Close()
        }
        // A hard link to something the tree no longer has is dropped.
        for e in all where e.Kind == Kind.hardlink {
            if let target = entries[e.Linkname], target.Kind == Kind.file {
                try sink.Add(e, [])
            }
        }
        try sink.Finish()
    }
}

/// Reads the layers' headers and works out the tree they make.
public func Merge(layers: [Layer]) throws -> Plan {
    let plan = Plan(layers: layers)
    for (i, layer) in layers.enumerated() {
        var r = tar.Reader(try LayerStream(path: layer.Path, mediaType: layer.MediaType))
        while let h = try r.Next() {
            try plan.apply(h, layer: i)
        }
        r.Inner.Close()
    }
    return plan
}

/// Merge for an image in a store.
public func Merge(img: store.Image, in st: store.Store) throws -> Plan {
    try Merge(try Layers(of: img, in: st))
}
