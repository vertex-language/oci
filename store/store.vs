// Package store keeps images on disk as an OCI image layout
// (image-spec, image-layout.md): content-addressed blobs, and an index
// naming the images that are kept.
//
//     <root>/oci-layout              {"imageLayoutVersion": "1.0.0"}
//     <root>/index.json              one descriptor per name
//     <root>/blobs/sha256/<hex>      manifests, configs, layers, files
//     <root>/ingest/                 blobs being written
//
// Any tool that reads an image layout -- skopeo, crane, containerd's
// import -- reads this directory as it is. A name is kept as the
// `org.opencontainers.image.ref.name` annotation, spelled in full
// ("docker.io/library/alpine:3.20").
package store

import (
    "crypto/sha256"
    "encoding/json"
    "fs"
    "oci/digest"
    "oci/spec"
    "oci/reference"
    "os/env"
    "os/user"
)

public enum StoreError: Error, CustomStringConvertible {
    case notFound(string)
    case corrupt(string)
    case sizeMismatch(digest: string, expected: int64, got: int64)
    case noPlatform(name: string, platform: string)

    public var description: string {
        switch self {
        case .notFound(let s): return "not in the store: \(s)"
        case .corrupt(let s): return "store is corrupt: \(s)"
        case .sizeMismatch(let d, let e, let g): return "\(d) is \(g) bytes, expected \(e)"
        case .noPlatform(let n, let p): return "\(n) has no image for \(p)"
        }
    }
}

/// The annotation an image layout names its images by.
public let RefNameAnnotation = "org.opencontainers.image.ref.name"

/// A name the store keeps, and what it names.
public struct Record {
    public var Name: string
    public var Descriptor: spec.Descriptor
}

/// An image read out of the store: its manifest, its config, and the
/// digest it was found under.
public struct Image {
    public var Name: string
    public var ManifestDigest: digest.Digest
    public var Manifest: spec.Manifest
    public var Config: spec.Config
    /// The total compressed size of the layers.
    public var Size: int64 {
        var n: int64 = 0
        for l in Manifest.Layers { n += l.Size }
        return n
    }
}

/// Where images are kept unless a root is given: $VERTEX_OCI_ROOT, else
/// "vertex/oci" under the user's data directory (~/Library/Application
/// Support on macOS, ~/.local/share on Linux, %APPDATA% on Windows).
public func DefaultRoot() -> string {
    if let r = env.Get("VERTEX_OCI_ROOT"), !r.isEmpty {
        return r
    }
    let base = user.DataDir() ?? (user.Home() ?? ".")
    return base + "/vertex/oci"
}

/// An image layout on disk.
public final class Store {
    public let Root: fs.Path
    var records: [Record] = []

    /// Opens the layout at `root` (DefaultRoot when nil), making it if
    /// it isn't there.
    public init(root: string? = nil) throws {
        Root = fs.Path(root ?? DefaultRoot())
        try fs.CreateDir(Root / "blobs" / "sha256", all: true)
        try fs.CreateDir(Root / "ingest", all: true)
        let layout = Root / "oci-layout"
        if !fs.Exists(layout) {
            try fs.WriteText(layout, "{\"imageLayoutVersion\":\"1.0.0\"}", atomic: true)
        }
        let index = Root / "index.json"
        if fs.Exists(index) {
            let idx = try spec.Index.Parse(try fs.ReadFile(index))
            for d in idx.Manifests {
                records.append(Record(Name: d.Annotations[RefNameAnnotation] ?? "", Descriptor: d))
            }
        } else {
            try save()
        }
    }

    func save() throws {
        var ds: [spec.Descriptor] = []
        for r in records {
            var d = r.Descriptor
            if !r.Name.isEmpty { d.Annotations[RefNameAnnotation] = r.Name }
            ds.append(d)
        }
        try fs.WriteFile(Root / "index.json", spec.Index(manifests: ds).Encode(), atomic: true)
    }

    // MARK: Blobs

    /// Where a blob is, whether or not it is there.
    public func BlobPath(d: digest.Digest) -> fs.Path {
        Root / "blobs" / d.Algorithm / d.Hex
    }

    public func HasBlob(d: digest.Digest) -> bool {
        fs.Exists(BlobPath(d))
    }

    /// A blob's bytes, checked against its digest.
    public func ReadBlob(d: digest.Digest) throws -> [uint8] {
        let p = BlobPath(d)
        if !fs.Exists(p) { throw StoreError.notFound(d.description) }
        let bytes = try fs.ReadFile(p)
        try d.Verify(bytes)
        return bytes
    }

    /// Stores `bytes`, returning their digest.
    @discardableResult
    public func WriteBlob(bytes: [uint8]) throws -> digest.Digest {
        let d = digest.Digest.Of(bytes)
        if !HasBlob(d) {
            let tmp = Root / "ingest" / (d.Hex + ".tmp")
            try fs.WriteFile(tmp, bytes)
            try fs.Rename(tmp, BlobPath(d))
        }
        return d
    }

    /// Starts writing a blob too big to hold: see Ingest.
    public func BeginIngest(name: string) throws -> Ingest {
        let path = Root / "ingest" / name
        return Ingest(store: self, path: path, file: try fs.Create(path))
    }

    /// Size of a stored blob.
    public func BlobSize(d: digest.Digest) throws -> int64 {
        try fs.Stat(BlobPath(d)).Size
    }

    // MARK: Names

    /// Every name kept, in the order they were added.
    public var Records: [Record] { records.filter { !$0.Name.isEmpty } }

    /// Names `d` as `name`, replacing what the name meant before.
    public func Tag(name: string, d: spec.Descriptor) throws {
        let full = Store.canonical(name)
        records = records.filter { $0.Name != full }
        records.append(Record(Name: full, Descriptor: d))
        try save()
    }

    /// Forgets a name. The blobs stay until Prune.
    public func Untag(name: string) throws {
        let full = Store.canonical(name)
        let before = records.count
        records = records.filter { $0.Name != full }
        if records.count == before { throw StoreError.notFound(name) }
        try save()
    }

    /// The descriptor a name stands for. "alpine", "alpine:3.20" and
    /// "docker.io/library/alpine:3.20" are one name; a digest prefix of
    /// at least 6 hex digits finds an image by its manifest.
    public func Resolve(name: string) -> Record? {
        let full = Store.canonical(name)
        for r in records where r.Name == full {
            return r
        }
        let hex = name.hasPrefix("sha256:") ? string(name.dropFirst(7)) : name
        if hex.count >= 6 {
            for r in records where r.Descriptor.Digest.hasPrefix("sha256:" + hex) {
                return r
            }
        }
        return nil
    }

    static func canonical(name: string) -> string {
        (try? reference.Reference.Parse(name))?.description ?? name
    }

    /// The image a name stands for, for `platform`: through an index to
    /// the platform's manifest, then its config.
    public func Image(name: string, platform: spec.Platform = spec.Platform.Default) throws -> Image {
        guard let r = Resolve(name) else { throw StoreError.notFound(name) }
        var d = try digest.Digest.Parse(r.Descriptor.Digest)
        var bytes = try ReadBlob(d)
        if spec.MediaType.IsIndex(r.Descriptor.MediaType) || isIndex(bytes) {
            let idx = try spec.Index.Parse(bytes)
            guard let m = idx.Select(platform) else {
                throw StoreError.noPlatform(name: r.Name, platform: platform.description)
            }
            d = try digest.Digest.Parse(m.Digest)
            bytes = try ReadBlob(d)
        }
        let manifest = try spec.Manifest.Parse(bytes)
        let config = try spec.Config.Parse(try ReadBlob(try digest.Digest.Parse(manifest.Config.Digest)))
        return store.Image(Name: r.Name, ManifestDigest: d, Manifest: manifest, Config: config)
    }

    func isIndex(bytes: [uint8]) -> bool {
        guard let v = try? json.Parse(bytes: bytes) else { return false }
        return v["manifests"] != nil
    }

    /// Removes every blob no name reaches, and anything left in ingest.
    /// Returns how many bytes were freed.
    @discardableResult
    public func Prune() throws -> int64 {
        var keep = Set<string>()
        for r in records {
            try reach(r.Descriptor.Digest, &keep)
        }
        var freed: int64 = 0
        for e in try fs.ReadDir(Root / "blobs" / "sha256") {
            if !keep.contains(e.Name) {
                freed += (try? fs.Stat(e.Path).Size) ?? 0
                try fs.Remove(e.Path)
            }
        }
        for e in try fs.ReadDir(Root / "ingest") {
            try fs.RemoveAll(e.Path)
        }
        return freed
    }

    /// Adds a blob and everything it refers to.
    func reach(d: string, keep: inout Set<string>) throws {
        guard let dg = try? digest.Digest.Parse(d), HasBlob(dg) else { return }
        if keep.contains(dg.Hex) { return }
        keep.insert(dg.Hex)
        // Only JSON documents refer to others; layers are skipped by size.
        if try BlobSize(dg) > 4 * 1024 * 1024 { return }
        let bytes = try fs.ReadFile(BlobPath(dg))
        guard let v = try? json.Parse(bytes: bytes) else { return }
        for m in v["manifests"]?.Array ?? [] {
            if let s = m["digest"]?.String { try reach(s, &keep) }
        }
        if let c = v["config"]?["digest"]?.String { try reach(c, &keep) }
        for l in v["layers"]?.Array ?? [] {
            if let s = l["digest"]?.String { try reach(s, &keep) }
        }
    }
}

/// A blob being written a piece at a time -- a layer as it downloads --
/// hashed as it goes. Commit checks it is what was asked for and moves
/// it into place; until then nothing in the store has changed.
public final class Ingest {
    let store: Store
    let path: fs.Path
    var file: fs.File?
    var hash: sha256.Digest
    public private(set) var Written: int64 = 0

    init(store: Store, path: fs.Path, file: fs.File) {
        self.store = store
        self.path = path
        self.file = file
        hash = sha256.New()
    }

    public func Write(bytes: [uint8]) throws {
        guard let f = file else { throw StoreError.corrupt("write after commit") }
        try f.Write(bytes)
        hash.Write(bytes)
        Written += int64(bytes.count)
    }

    /// The digest of what has been written.
    public var Digest: digest.Digest {
        digest.Digest(algorithm: "sha256", hex: sha256.ToHex(hash.Checksum()))
    }

    /// Checks the blob against `expected` (and `size`, when not -1) and
    /// stores it.
    @discardableResult
    public func Commit(expected: digest.Digest? = nil, size: int64 = -1) throws -> digest.Digest {
        if let f = file { try f.Close() }
        file = nil
        let got = Digest
        if let e = expected, e != got {
            try? fs.Remove(path)
            throw digest.DigestError.mismatch(expected: e.description, got: got.description)
        }
        if size >= 0 && size != Written {
            try? fs.Remove(path)
            throw StoreError.sizeMismatch(digest: got.description, expected: size, got: Written)
        }
        try fs.Rename(path, store.BlobPath(got))
        return got
    }

    /// Gives up, removing what was written.
    public func Abort() {
        if let f = file { try? f.Close() }
        file = nil
        try? fs.Remove(path)
    }
}
