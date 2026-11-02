// Package registry pulls images from a registry that speaks the OCI
// distribution API (Docker Hub, ghcr.io, quay.io, a local registry:2).
//
//     GET /v2/<repo>/manifests/<tag or digest>   an index or a manifest
//     GET /v2/<repo>/blobs/<digest>              a config or a layer
//
// A registry that wants a token answers 401 with a challenge
// (`WWW-Authenticate: Bearer realm=…,service=…,scope=…`); the token is
// fetched from the realm -- anonymously, or with credentials from
// ~/.docker/config.json -- and the request is made again with it.
// Blobs are usually a redirect away, to a CDN; credentials stay behind.
package registry

import (
    "encoding/base64"
    "encoding/json"
    "fs"
    "net/http"
    "net/url"
    "oci/digest"
    "oci/spec"
    "oci/reference"
    "oci/store"
    "os/env"
    "os/user"
)

public enum RegistryError: Error, CustomStringConvertible {
    case status(code: int32, what: string, body: string)
    case auth(string)
    case tooManyRedirects(string)
    case malformed(string)

    public var description: string {
        switch self {
        case .status(let c, let w, let b):
            return "registry answered \(c) for \(w)" + (b.isEmpty ? "" : ": \(b)")
        case .auth(let s): return "registry authentication failed: \(s)"
        case .tooManyRedirects(let s): return "too many redirects fetching \(s)"
        case .malformed(let s): return "registry sent something malformed: \(s)"
        }
    }
}

/// A user name and password (or token) for a registry.
public struct Credentials {
    public var Username: string
    public var Password: string

    public init(username: string, password: string) {
        Username = username
        Password = password
    }

    /// What `docker login` saved for `registry`, from
    /// $DOCKER_CONFIG/config.json or ~/.docker/config.json -- its "auth"
    /// entries; credential helpers aren't run.
    public static func FromDockerConfig(registry: string) -> Credentials? {
        var dir = env.Get("DOCKER_CONFIG") ?? ""
        if dir.isEmpty {
            guard let home = user.Home() else { return nil }
            dir = home + "/.docker"
        }
        guard let bytes = try? fs.ReadFile(fs.Path(dir + "/config.json")),
              let v = try? json.Parse(bytes: bytes),
              let auths = v["auths"]?.Object else { return nil }
        let names = registry == "docker.io"
            ? ["https://index.docker.io/v1/", "index.docker.io", "docker.io", "registry-1.docker.io"]
            : [registry, "https://" + registry]
        for name in names {
            guard let a = auths[name]?["auth"]?.String,
                  let raw = try? base64.StdEncoding.DecodeString(a) else { continue }
            let text = string(decoding: raw, as: UTF8.self)
            guard let colon = text.firstIndex(of: ":") else { continue }
            return Credentials(username: string(text[..<colon]),
                               password: string(text[text.index(after: colon)...]))
        }
        return nil
    }
}

func dockerCredentials(registry: string) -> Credentials? {
    Credentials.FromDockerConfig(registry)
}

/// What a fetch is doing, for a progress display.
public struct Progress {
    /// "manifest", "config", or a layer's short digest.
    public var What: string
    public var Done: int64
    public var Total: int64
}

/// A manifest or index as the registry sent it.
public struct Fetched {
    public var Bytes: [uint8]
    public var MediaType: string
    public var Digest: digest.Digest
}

/// One registry, reached at its API host.
public final class Client {
    /// The host the API is at: "registry-1.docker.io", "localhost:5000".
    public let Host: string
    /// The registry as images name it, for credentials: "docker.io".
    public let Registry: string
    /// Plain HTTP, for a registry on this machine.
    public let Insecure: bool
    public var Credentials: Credentials?
    var tokens: [string: string] = [:]
    var client: http.Client

    public init(registry: string, host: string, insecure: bool = false, credentials: Credentials? = nil) {
        Registry = registry
        Host = host
        Insecure = insecure
        Credentials = credentials ?? dockerCredentials(registry)
        var cfg = http.ClientConfig(enabledVersions: [http.HttpVersion.http1_1, http.HttpVersion.http2],
                                    timeoutMs: 30000)
        cfg.MaxRedirects = 10
        cfg.ReadTimeoutMs = 60000
        client = http.Client(config: cfg)
    }

    /// The client for where `ref` lives. A registry on localhost or
    /// 127.0.0.1 is spoken to over plain HTTP, as Docker does.
    public static func For(ref: reference.Reference) -> Client {
        let local = ref.Registry.hasPrefix("localhost") || ref.Registry.hasPrefix("127.0.0.1")
        return Client(registry: ref.Registry, host: ref.ApiHost, insecure: local)
    }

    func endpoint(path: string) throws -> url.URL {
        try url.Parse((Insecure ? "http://" : "https://") + Host + path)
    }

    /// The Authorization header for `repo`, if one is known.
    func authorization(repo: string) -> string? {
        if let t = tokens[repo] { return "Bearer " + t }
        return nil
    }

    /// Answers a 401's challenge, so the request can be made again.
    func authenticate(challenge: string, repo: string) async throws {
        let (scheme, params) = parseChallenge(challenge)
        if scheme.lowercased() == "basic" {
            guard let c = Credentials else { throw RegistryError.auth("\(Registry) wants a login") }
            tokens[repo] = nil
            basic[repo] = basicHeader(c)
            return
        }
        guard scheme.lowercased() == "bearer", let realm = params["realm"] else {
            throw RegistryError.auth("unsupported challenge: \(challenge)")
        }
        var q = url.Values()
        if let s = params["service"] { q.Set("service", s) }
        q.Set("scope", params["scope"] ?? "repository:\(repo):pull,push")
        var target = try url.Parse(realm)
        target.Query = q.Encode()
        var req = http.Request(method: "GET", url: target.RequestURI)
        if let c = Credentials {
            req.Headers.Set("Authorization", basicHeader(c))
        }
        let res = try await client.DoUrl(req, url: target)
        if res.StatusCode != 200 {
            throw RegistryError.auth("token endpoint \(realm) answered \(res.StatusCode): \(res.BodyText())")
        }
        let v = try json.Parse(bytes: res.Body)
        guard let t = v["token"]?.String ?? v["access_token"]?.String else {
            throw RegistryError.auth("no token from \(realm)")
        }
        tokens[repo] = t
    }

    var basic: [string: string] = [:]

    func basicHeader(c: Credentials) -> string {
        "Basic " + base64.StdEncoding.EncodeToString([uint8]((c.Username + ":" + c.Password).utf8))
    }

    func prepare(req: inout http.Request, repo: string) {
        if let a = authorization(repo) ?? basic[repo] {
            req.Headers.Set("Authorization", a)
        }
        req.Headers.Set("User-Agent", "vertex-oci/0.1")
    }

    /// A small GET whose body is read whole: a manifest, an index.
    func get(path: string, repo: string, accept: string) async throws -> http.Response {
        let target = try endpoint(path)
        var tried = false
        while true {
            var req = http.Request(method: "GET", url: target.RequestURI)
            req.Headers.Set("Accept", accept)
            prepare(&req, repo: repo)
            let res = try await client.DoUrl(req, url: target)
            if res.StatusCode == 401 && !tried, let ch = res.Headers.Get("WWW-Authenticate") {
                try await authenticate(ch, repo: repo)
                tried = true
                continue
            }
            if res.StatusCode != 200 {
                throw RegistryError.status(code: res.StatusCode, what: path, body: errorText(res.Body))
            }
            return res
        }
    }

    /// The manifest or index `ref` names -- tag or digest -- as the
    /// registry has it; a digest is checked.
    public func Manifest(repo: string, ref: string) async throws -> Fetched {
        let accept = [spec.MediaType.index, spec.MediaType.manifest,
                      spec.MediaType.dockerList, spec.MediaType.dockerManifest].joined(separator: ", ")
        let res = try await get("/v2/\(repo)/manifests/\(ref)", repo: repo, accept: accept)
        let d = digest.Digest.Of(res.Body)
        if ref.hasPrefix("sha256:") {
            try (try digest.Digest.Parse(ref)).Verify(res.Body)
        }
        var mt = res.Headers.Get("Content-Type") ?? ""
        if let semi = mt.firstIndex(of: ";") { mt = string(mt[..<semi]) }
        if mt.isEmpty || mt == "application/json" {
            mt = (try? json.Parse(bytes: res.Body))?["mediaType"]?.String ?? ""
        }
        return Fetched(Bytes: res.Body, MediaType: mt, Digest: d)
    }

    /// A request with a body, made again once if the registry wants a
    /// (new) token. `path` may be a Location the registry sent: absolute
    /// or not, it is taken against this host.
    func send(method: string, path: string, repo: string, body: [uint8] = [],
              headers: [(string, string)] = []) async throws -> http.Response {
        var target = try endpoint("/").Resolve(path)
        var tried = false
        var hops = 0
        while true {
            var req = http.Request(method: method, url: target.RequestURI)
            for (k, v) in headers { req.Headers.Set(k, v) }
            if !body.isEmpty { req.Body = body }
            prepare(&req, repo: repo)
            let res = try await client.DoUrl(req, url: target)
            if res.StatusCode == 401 && !tried, let ch = res.Headers.Get("WWW-Authenticate") {
                try await authenticate(ch, repo: repo)
                tried = true
                continue
            }
            if (res.StatusCode == 307 || res.StatusCode == 308), let loc = res.Headers.Get("Location"), hops < 10 {
                hops += 1
                target = try target.Resolve(loc)
                continue
            }
            return res
        }
    }

    /// Whether the registry has the blob already.
    public func HasBlob(repo: string, d: digest.Digest) async throws -> bool {
        let res = try await send("HEAD", "/v2/\(repo)/blobs/\(d)", repo: repo)
        return res.StatusCode == 200
    }

    /// Uploads a blob unless the registry has it: an upload session, the
    /// bytes in chunks, and the closing PUT that names the digest.
    public func PushBlob(repo: string, d: digest.Digest, bytes: [uint8]) async throws {
        if try await HasBlob(repo, d) { return }
        var res = try await send("POST", "/v2/\(repo)/blobs/uploads/", repo: repo,
                                 headers: [("Content-Length", "0")])
        guard res.StatusCode == 202, var location = res.Headers.Get("Location") else {
            throw RegistryError.status(code: res.StatusCode, what: "starting an upload to \(repo)", body: errorText(res.Body))
        }
        let chunk = 16 * 1024 * 1024
        var at = 0
        while at < bytes.count {
            let end = min(at + chunk, bytes.count)
            res = try await send("PATCH", location, repo: repo, body: Array(bytes[at..<end]),
                                 headers: [("Content-Type", "application/octet-stream"),
                                           ("Content-Range", "\(at)-\(end - 1)")])
            guard res.StatusCode == 202, let next = res.Headers.Get("Location") else {
                throw RegistryError.status(code: res.StatusCode, what: "uploading \(d.Short)", body: errorText(res.Body))
            }
            location = next
            at = end
        }
        var target = try endpoint("/").Resolve(location)
        var q = target.QueryValues
        q.Set("digest", d.description)
        target.Query = q.Encode()
        res = try await send("PUT", target.RequestURI, repo: repo,
                             headers: [("Content-Type", "application/octet-stream"), ("Content-Length", "0")])
        if res.StatusCode != 201 {
            throw RegistryError.status(code: res.StatusCode, what: "finishing \(d.Short)", body: errorText(res.Body))
        }
    }

    /// Puts a manifest or index under a tag or digest.
    public func PushManifest(repo: string, ref: string, bytes: [uint8], mediaType: string) async throws {
        let res = try await send("PUT", "/v2/\(repo)/manifests/\(ref)", repo: repo, body: bytes,
                                 headers: [("Content-Type", mediaType)])
        if res.StatusCode != 201 && res.StatusCode != 200 {
            throw RegistryError.status(code: res.StatusCode, what: "manifest \(ref)", body: errorText(res.Body))
        }
    }

    /// Opens a blob for reading, following its redirect to wherever it is
    /// kept. The caller reads the stream and closes it.
    public func OpenBlob(repo: string, d: digest.Digest) async throws -> http.ResponseStream {
        var target = try endpoint("/v2/\(repo)/blobs/\(d)")
        var origin = true
        var tried = false
        var hops = 0
        while true {
            var req = http.Request(method: "GET", url: target.RequestURI)
            if origin {
                prepare(&req, repo: repo)
            } else {
                req.Headers.Set("User-Agent", "vertex-oci/0.1")
            }
            var s = try await client.Open(req, url: target)
            let code = s.Response.StatusCode
            if code == 200 {
                return s
            }
            let location = s.Response.Headers.Get("Location")
            let challenge = s.Response.Headers.Get("WWW-Authenticate")
            var body: [uint8] = []
            if code >= 400 {
                var buf = [uint8](repeating: 0, count: 4096)
                let n = (try? await s.Read(into: &buf)) ?? 0
                body = Array(buf[0..<n])
            }
            s.Close()
            if code == 401 && origin && !tried, let ch = challenge {
                try await authenticate(ch, repo: repo)
                tried = true
                continue
            }
            if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308), let loc = location {
                hops += 1
                if hops > 10 { throw RegistryError.tooManyRedirects(d.description) }
                let next = try target.Resolve(loc)
                // A CDN's signed URL carries its own authority.
                if next.Host != target.Host || next.Scheme != target.Scheme {
                    origin = false
                }
                target = next
                continue
            }
            throw RegistryError.status(code: code, what: "blob \(d)", body: errorText(body))
        }
    }

    /// Fetches a blob into `st` unless it is there already, checking its
    /// digest and size as it lands.
    public func FetchBlob(repo: string, desc: spec.Descriptor, into st: store.Store,
                          progress: (Progress) -> Void = { _ in }) async throws {
        let d = try digest.Digest.Parse(desc.Digest)
        if st.HasBlob(d) {
            progress(Progress(What: d.Short, Done: desc.Size, Total: desc.Size))
            return
        }
        var s = try await OpenBlob(repo, d)
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
                    progress(Progress(What: d.Short, Done: ingest.Written, Total: desc.Size))
                }
            }
            s.Close()
            try ingest.Commit(expected: d, size: desc.Size)
        } catch {
            s.Close()
            ingest.Abort()
            throw error
        }
        progress(Progress(What: d.Short, Done: desc.Size, Total: desc.Size))
    }
}

/// Pulls `name` for `platform` into `st` and names it there: the index
/// (if the name is multi-platform), the platform's manifest, its config
/// and layers. Blobs already in the store aren't fetched again.
@discardableResult
public func Pull(name: string, into st: store.Store, platform: spec.Platform = spec.Platform.Default,
                 progress: (Progress) -> Void = { _ in }) async throws -> store.Image {
    let ref = try reference.Reference.Parse(name)
    let c = Client.For(ref)
    let repo = ref.Repository
    var top = try await c.Manifest(repo, ref.Target)
    progress(Progress(What: "manifest", Done: int64(top.Bytes.count), Total: int64(top.Bytes.count)))
    var manifestBytes = top.Bytes
    var manifestDigest = top.Digest
    var manifestType = top.MediaType
    if spec.MediaType.IsIndex(top.MediaType) {
        let idx = try spec.Index.Parse(top.Bytes)
        guard let m = idx.Select(platform) else {
            let have = idx.Manifests.compactMap { $0.Platform?.description }.joined(separator: ", ")
            throw store.StoreError.noPlatform(name: ref.Familiar, platform: "\(platform) (it has \(have))")
        }
        st.WriteBlob(top.Bytes)
        let one = try await c.Manifest(repo, m.Digest)
        manifestBytes = one.Bytes
        manifestDigest = one.Digest
        manifestType = one.MediaType.isEmpty ? m.MediaType : one.MediaType
    }
    let manifest = try spec.Manifest.Parse(manifestBytes)
    try await c.FetchBlob(repo, manifest.Config, into: st, progress: progress)
    for l in manifest.Layers {
        try await c.FetchBlob(repo, l, into: st, progress: progress)
    }
    st.WriteBlob(manifestBytes)
    var desc = spec.Descriptor(mediaType: manifestType.isEmpty ? spec.MediaType.manifest : manifestType,
                                digest: manifestDigest.description, size: int64(manifestBytes.count),
                                platform: platform)
    desc.Annotations["org.opencontainers.image.base.name"] = ref.description
    try st.Tag(ref.description, desc)
    return try st.Image(ref.description, platform: platform)
}

/// Pushes the image `name` for `platform` from `st` to the registry its
/// name says: config and layers, then the manifest under the tag (or
/// digest). Blobs the registry has aren't sent again. `as` pushes it
/// under another name.
public func Push(name: string, from st: store.Store, platform: spec.Platform = spec.Platform.Default,
                 as target: string? = nil, progress: (Progress) -> Void = { _ in }) async throws {
    let img = try st.Image(name, platform: platform)
    let ref = try reference.Reference.Parse(target ?? name)
    let c = Client.For(ref)
    let repo = ref.Repository
    var blobs = [img.Manifest.Config]
    blobs.append(contentsOf: img.Manifest.Layers)
    for b in blobs {
        let d = try digest.Digest.Parse(b.Digest)
        try await c.PushBlob(repo, d, try st.ReadBlob(d))
        progress(Progress(What: d.Short, Done: b.Size, Total: b.Size))
    }
    let bytes = try st.ReadBlob(img.ManifestDigest)
    let mt = img.Manifest.MediaType.isEmpty ? spec.MediaType.manifest : img.Manifest.MediaType
    try await c.PushManifest(repo, ref.Target, bytes, mediaType: mt)
    progress(Progress(What: "manifest", Done: int64(bytes.count), Total: int64(bytes.count)))
}

/// "Bearer realm="…",service="…"" as its scheme and parameters.
public func parseChallenge(header: string) -> (string, [string: string]) {
    let trimmed = trim(header)
    guard let space = trimmed.firstIndex(of: " ") else { return (trimmed, [:]) }
    let scheme = string(trimmed[..<space])
    var params: [string: string] = [:]
    let rest = [uint8](string(trimmed[trimmed.index(after: space)...]).utf8)
    var i = 0
    while i < rest.count {
        while i < rest.count && (rest[i] == 0x20 || rest[i] == 0x2C) { i += 1 }
        let ks = i
        while i < rest.count && rest[i] != 0x3D { i += 1 }
        let key = string(decoding: Array(rest[ks..<i]), as: UTF8.self).lowercased()
        i += 1
        var value: [uint8] = []
        if i < rest.count && rest[i] == 0x22 {
            i += 1
            while i < rest.count && rest[i] != 0x22 {
                if rest[i] == 0x5C && i + 1 < rest.count { i += 1 }
                value.append(rest[i])
                i += 1
            }
            i += 1
        } else {
            while i < rest.count && rest[i] != 0x2C {
                value.append(rest[i])
                i += 1
            }
        }
        if !key.isEmpty { params[key] = string(decoding: value, as: UTF8.self) }
    }
    return (scheme, params)
}

/// A registry's error body ({"errors":[{"code":…,"message":…}]}) as text.
func errorText(body: [uint8]) -> string {
    if let v = try? json.Parse(bytes: body), let errs = v["errors"]?.Array {
        return errs.map { "\($0["code"]?.String ?? "") \($0["message"]?.String ?? "")" }.joined(separator: "; ")
    }
    return string(decoding: Array(body.prefix(200)), as: UTF8.self)
}

func trim(s: string) -> string {
    var b = [uint8](s.utf8)
    while let f = b.first, f == 0x20 || f == 0x09 { b.removeFirst() }
    while let l = b.last, l == 0x20 || l == 0x09 || l == 0x0D || l == 0x0A { b.removeLast() }
    return string(decoding: b, as: UTF8.self)
}
