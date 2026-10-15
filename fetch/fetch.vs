// Package fetch brings large files into the store from a URL pinned to
// its SHA-256: a kernel, firmware, a disk image. Whatever needs such a
// file names it, and fetch downloads it once and checks it, rather than
// a repository carrying the bytes.
//
// A fetched file is kept as an OCI 1.1 artifact -- a manifest whose one
// layer is the file -- named "vertex.local/files/<name>:<version>", so
// the store lists, keeps and prunes it as it does an image, and any
// tool that reads an image layout sees what it is.
package fetch

import (
    "fs"
    "net/http"
    "net/url"
    "oci/digest"
    "oci/spec"
    "oci/store"
)

public enum FetchError: Error, CustomStringConvertible {
    case status(code: int32, url: string)
    case tooManyRedirects(string)
    case notAFile(string)
    case unknown(string)

    public var description: string {
        switch self {
        case .status(let c, let u): return "\(u) answered \(c)"
        case .tooManyRedirects(let u): return "too many redirects fetching \(u)"
        case .notAFile(let n): return "\(n) is not a fetched file"
        case .unknown(let n): return "no file called \(n) in the catalog"
        }
    }
}

/// The artifact type a fetched file's manifest has.
public let ArtifactType = "application/vnd.vertex.file.v1"
/// The annotation a file's own name is kept in.
public let TitleAnnotation = "org.opencontainers.image.title"
/// Where a file came from.
public let SourceAnnotation = "org.opencontainers.image.source"

/// A file pinned by URL and digest.
public struct File {
    /// What it's called in the store, and the name it is found by.
    public var Name: string
    public var Version: string
    public var URL: string
    /// "sha256:…"
    public var Digest: string
    public var Size: int64
    /// What the file is, for whoever reads the store.
    public var MediaType: string

    public init(name: string, version: string, url: string, digest: string, size: int64,
                mediaType: string = spec.MediaType.file) {
        Name = name
        Version = version
        URL = url
        Digest = digest
        Size = size
        MediaType = mediaType
    }

    /// Its name in the store: "vertex.local/files/<name>:<version>".
    public var Reference: string { "vertex.local/files/\(Name):\(Version)" }
}

/// Where a fetched file is on disk, if the store has it.
public func Path(_ f: File, in st: store.Store) -> fs.Path? {
    guard let d = try? digest.Digest.Parse(f.Digest), st.HasBlob(d) else { return nil }
    return st.BlobPath(d)
}

/// Makes sure the store has `f`, downloading and checking it if not, and
/// returns where it is.
@discardableResult
public func Fetch(_ f: File, into st: store.Store, progress: (int64, int64) -> Void = { _, _ in }) async throws -> fs.Path {
    let d = try digest.Digest.Parse(f.Digest)
    if !st.HasBlob(d) {
        try await download(f.URL, d, f.Size, st, progress)
    }
    // The artifact that names it: an empty config, the file as its layer.
    let config = st.WriteBlob([uint8]("{}".utf8))
    var layer = spec.Descriptor(mediaType: f.MediaType, digest: d.description, size: f.Size)
    layer.Annotations[TitleAnnotation] = f.Name
    var m = spec.Manifest(config: spec.Descriptor(mediaType: "application/vnd.oci.empty.v1+json",
                                                    digest: config.description, size: 2),
                           layers: [layer], artifactType: ArtifactType)
    m.Annotations[SourceAnnotation] = f.URL
    let bytes = m.Encode()
    let md = st.WriteBlob(bytes)
    if st.Resolve(f.Reference)?.Descriptor.Digest != md.description {
        var desc = spec.Descriptor(mediaType: spec.MediaType.manifest, digest: md.description,
                                    size: int64(bytes.count), artifactType: ArtifactType)
        desc.Annotations[TitleAnnotation] = f.Name
        try st.Tag(f.Reference, desc)
    }
    return st.BlobPath(d)
}

/// Streams `address` into the store, following redirects, and checks it.
func download(_ address: string, _ d: digest.Digest, _ size: int64, _ st: store.Store,
              _ progress: (int64, int64) -> Void) async throws {
    var cfg = http.ClientConfig(enabledVersions: [http.HttpVersion.http1_1], timeoutMs: 30000)
    cfg.ReadTimeoutMs = 60000
    let client = http.Client(config: cfg)
    var target = try url.Parse(address)
    var hops = 0
    while true {
        var req = http.Request(method: "GET", url: target.RequestURI)
        req.Headers.Set("User-Agent", "vertex-oci/0.1")
        var s = try await client.Open(req, url: target)
        let code = s.Response.StatusCode
        if code == 301 || code == 302 || code == 303 || code == 307 || code == 308 {
            let loc = s.Response.Headers.Get("Location")
            s.Close()
            hops += 1
            guard let l = loc, hops <= 10 else { throw FetchError.tooManyRedirects(address) }
            target = try target.Resolve(l)
            continue
        }
        if code != 200 {
            s.Close()
            throw FetchError.status(code: code, url: address)
        }
        let ingest = try st.BeginIngest(d.Hex + ".partial")
        var buf = [uint8](repeating: 0, count: 256 * 1024)
        var last: int64 = 0
        do {
            while true {
                let n = try await s.Read(into: &buf)
                if n == 0 { break }
                try ingest.Write(n == buf.count ? buf : Array(buf[0..<n]))
                if ingest.Written - last >= 1024 * 1024 {
                    last = ingest.Written
                    progress(ingest.Written, size)
                }
            }
            s.Close()
            try ingest.Commit(expected: d, size: size)
        } catch {
            s.Close()
            ingest.Abort()
            throw error
        }
        progress(size, size)
        return
    }
}

/// Files vm needs, pinned. A name here is what `oci fetch <name>` takes.
public enum Catalog {
    static let alpine = "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/netboot-3.20.10/"

    /// Alpine 3.20's linux-virt 6.6 kernel for arm64, as an EFI zboot
    /// image: what vm boots a container image's tree with.
    public static let alpineKernel = File(
        name: "alpine-vmlinuz-virt-aarch64", version: "3.20.10", url: alpine + "vmlinuz-virt",
        digest: "sha256:573d0eb4713fc7b631e7242a95fa9d048c60365993658b24d5106a69d0a0e7f2",
        size: 9212416, mediaType: "application/vnd.vertex.linux.kernel")

    /// Its initramfs: busybox, musl and the kernel's virtio modules.
    public static let alpineInitramfs = File(
        name: "alpine-initramfs-virt-aarch64", version: "3.20.10", url: alpine + "initramfs-virt",
        digest: "sha256:90f5159c2cbf81b5d6ad7b14a314815589a7077d0e8fa4e8aa0403c3fef458ae",
        size: 8791628, mediaType: "application/vnd.vertex.linux.initramfs")

    /// The kernel's full module set, as a squashfs.
    public static let alpineModloop = File(
        name: "alpine-modloop-virt-aarch64", version: "3.20.10", url: alpine + "modloop-virt",
        digest: "sha256:3bd7260becc8629d2692261c374256c5478d1667feec7897fe4318152c4ca62b",
        size: 15863808, mediaType: "application/vnd.vertex.linux.modloop")

    /// Alpine's statically linked busybox (an .apk: gzipped tars one
    /// after another), which runs in any image whatever its libc: what
    /// vm's init for a container image is written in.
    public static let alpineBusybox = File(
        name: "alpine-busybox-static-aarch64", version: "1.36.1-r31",
        url: "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/busybox-static-1.36.1-r31.apk",
        digest: "sha256:1d8e7a7fc2ed69bdb8eb7be9d962489c21a0f75b72d8a325437c8a09d4cfac70",
        size: 659224, mediaType: "application/vnd.alpine.apk")

    public static var All: [File] { [alpineKernel, alpineInitramfs, alpineModloop, alpineBusybox] }

    public static func Named(_ name: string) -> File? {
        for f in All where f.Name == name { return f }
        return nil
    }
}
