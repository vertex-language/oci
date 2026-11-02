package rootfs

import (
    "archive/cpio"
    "fs"
)

/// Writes the tree as a newc cpio archive -- a Linux initramfs -- with
/// every owner, mode, device node and hard link as the image has them.
public final class CpioSink: Sink {
    var w: cpio.Writer<fs.File>
    var file: fs.File
    var inodes: [string: uint32] = [:]
    let links: [string: int]
    var next: uint32 = 1
    /// Entries written.
    public private(set) var Count: int = 0

    /// Writes to `path`. `plan` says which files have hard links, which
    /// the kernel needs to know at the first of them.
    public init(path: fs.Path, plan: Plan) throws {
        file = try fs.Create(path)
        w = cpio.Writer(file)
        links = plan.LinkCounts
    }

    func typeBits(k: Kind) -> uint32 {
        switch k {
        case .file, .hardlink: return cpio.ModeType.regular
        case .directory: return cpio.ModeType.directory
        case .symlink: return cpio.ModeType.symlink
        case .charDevice: return cpio.ModeType.charDevice
        case .blockDevice: return cpio.ModeType.blockDevice
        case .fifo: return cpio.ModeType.fifo
        }
    }

    public func Add(e: Entry, data: [uint8]) throws {
        var body = data
        var ino: uint32 = 0
        var nlink: uint32 = e.Kind == Kind.directory ? 2 : 1
        switch e.Kind {
        case .symlink:
            body = [uint8](e.Linkname.utf8)
        case .file:
            if let n = links[e.Path] {
                ino = next
                next += 1
                inodes[e.Path] = ino
                nlink = uint32(n)
            }
        case .hardlink:
            // The kernel links an entry to the earlier one of the same
            // inode; its own data is empty.
            guard let target = inodes[e.Linkname] else { return }
            ino = target
            nlink = uint32(links[e.Linkname] ?? 2)
            body = []
        default:
            break
        }
        if ino == 0 {
            ino = next
            next += 1
        }
        var h = cpio.Header(name: e.Path, mode: typeBits(e.Kind) | (e.Mode & 0o7777), uid: e.Uid, gid: e.Gid,
                            nlink: nlink, modTime: e.ModTime, size: int64(body.count), inode: ino,
                            rdevMajor: e.DevMajor, rdevMinor: e.DevMinor)
        if e.Kind == Kind.hardlink {
            h.Mode = cpio.ModeType.regular | (e.Mode & 0o7777)
        }
        try w.WriteHeader(h)
        if !body.isEmpty {
            try w.Write(body)
        }
        Count += 1
    }

    /// Adds a file the image doesn't have -- an /init, a module -- owned
    /// by root.
    public func AddFile(path: string, data: [uint8], mode: uint32 = 0o755) throws {
        try Add(Entry(Path: path, Kind: Kind.file, Mode: mode, Uid: 0, Gid: 0, ModTime: 0,
                      Size: int64(data.count), Linkname: "", DevMajor: 0, DevMinor: 0, Layer: -1), data)
    }

    /// Adds a directory, a symlink or a device node the image doesn't have.
    public func AddEntry(e: Entry) throws {
        try Add(e, [])
    }

    public func Finish() throws {
        try w.Close()
        try file.Close()
    }
}

/// Writes the tree into a directory on this machine, as far as it can:
/// owners are not set and device nodes are skipped (they need root), and
/// on a case-insensitive filesystem the later of two names that differ
/// only by case wins.
public final class DirSink: Sink {
    public let Root: fs.Path
    var dirModes: [(fs.Path, uint32, int64)] = []
    /// Device nodes and fifos not made.
    public private(set) var Skipped: int = 0
    public private(set) var Count: int = 0

    public init(root: fs.Path) throws {
        Root = root
        try fs.CreateDir(root, all: true)
    }

    public func Add(e: Entry, data: [uint8]) throws {
        let p = Root / e.Path
        switch e.Kind {
        case .directory:
            try fs.CreateDir(p, all: true)
            // Applied at the end: a read-only directory would refuse
            // what goes in it.
            dirModes.append((p, e.Mode, e.ModTime))
        case .file:
            if fs.Exists(p) { try? fs.Remove(p) }
            try fs.WriteFile(p, data)
            try fs.SetPermissions(p, e.Mode & 0o7777)
            try? fs.SetModTime(p, seconds: e.ModTime)
        case .symlink:
            if fs.Exists(p) { try? fs.Remove(p) }
            try fs.Symlink(fs.Path(e.Linkname), at: p)
        case .hardlink:
            if fs.Exists(p) { try? fs.Remove(p) }
            try fs.HardLink(Root / e.Linkname, at: p)
        default:
            Skipped += 1
            return
        }
        Count += 1
    }

    public func Finish() throws {
        // Deepest first, so a parent's mode doesn't stop its child's.
        for (p, mode, mtime) in dirModes.reversed() {
            try? fs.SetPermissions(p, (mode & 0o7777) | 0o700)
            try? fs.SetModTime(p, seconds: mtime)
        }
    }
}
