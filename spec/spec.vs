// Package spec is the OCI image format (image-spec v1.1): descriptors,
// manifests, indexes and image configs, read from and written to JSON.
// Docker's v2 schema 2 media types are the same shapes and are read too.
//
//     index ──► manifest (per platform) ──► config   (env, cmd, rootfs.diff_ids)
//                                      └──► layers   (tar, usually gzipped)
package spec

import "encoding/json"

public enum MediaType {
    public static let index = "application/vnd.oci.image.index.v1+json"
    public static let manifest = "application/vnd.oci.image.manifest.v1+json"
    public static let config = "application/vnd.oci.image.config.v1+json"
    public static let layerTar = "application/vnd.oci.image.layer.v1.tar"
    public static let layerGzip = "application/vnd.oci.image.layer.v1.tar+gzip"
    public static let layerZstd = "application/vnd.oci.image.layer.v1.tar+zstd"
    public static let dockerList = "application/vnd.docker.distribution.manifest.list.v2+json"
    public static let dockerManifest = "application/vnd.docker.distribution.manifest.v2+json"
    public static let dockerConfig = "application/vnd.docker.container.image.v1+json"
    public static let dockerLayerGzip = "application/vnd.docker.image.rootfs.diff.tar.gzip"
    /// What a fetched file is stored as: see oci/fetch.
    public static let file = "application/octet-stream"

    public static func IsIndex(_ t: string) -> bool { t == index || t == dockerList }
    public static func IsManifest(_ t: string) -> bool { t == manifest || t == dockerManifest }
    public static func IsGzipLayer(_ t: string) -> bool { t == layerGzip || t == dockerLayerGzip }
    public static func IsZstdLayer(_ t: string) -> bool { t == layerZstd }
}

public enum ImageError: Error, CustomStringConvertible {
    case malformed(string)

    public var description: string {
        switch self {
        case .malformed(let s): return "malformed image JSON: \(s)"
        }
    }
}

/// An OS and CPU an image is for.
public struct Platform: Equatable, CustomStringConvertible {
    public var OS: string
    public var Architecture: string
    public var Variant: string

    public init(os: string, architecture: string, variant: string = "") {
        OS = os
        Architecture = architecture
        Variant = variant
    }

    /// What a VM on this machine runs: Linux on the host's CPU.
    public static var Default: Platform {
        Platform(os: "linux", architecture: "arm64", variant: "v8")
    }

    /// "linux/arm64/v8" or "linux/amd64".
    public static func Parse(_ text: string) -> Platform {
        let p = text.split(separator: "/").map { string($0) }
        return Platform(os: p.count > 0 ? p[0] : "linux", architecture: p.count > 1 ? p[1] : "arm64",
                        variant: p.count > 2 ? p[2] : "")
    }

    /// Whether an image for `other` runs here: OS and CPU agree, and the
    /// variant does where both name one.
    public func Matches(_ other: Platform) -> bool {
        if OS != other.OS || Architecture != other.Architecture { return false }
        return Variant.isEmpty || other.Variant.isEmpty || Variant == other.Variant
    }

    public var description: string {
        Variant.isEmpty ? "\(OS)/\(Architecture)" : "\(OS)/\(Architecture)/\(Variant)"
    }
}

/// A pointer to content: its type, digest and size.
public struct Descriptor: Equatable {
    public var MediaType: string
    public var Digest: string
    public var Size: int64
    public var Platform: Platform?
    public var Annotations: [string: string]
    public var ArtifactType: string

    public init(mediaType: string, digest: string, size: int64, platform: Platform? = nil,
                annotations: [string: string] = [:], artifactType: string = "") {
        MediaType = mediaType
        Digest = digest
        Size = size
        Platform = platform
        Annotations = annotations
        ArtifactType = artifactType
    }

    public static func FromJson(_ v: json.Value) throws -> Descriptor {
        guard let d = v["digest"]?.String, let size = v["size"]?.Int else {
            throw ImageError.malformed("a descriptor needs digest and size")
        }
        var platform: Platform? = nil
        if let p = v["platform"] {
            platform = spec.Platform(os: p["os"]?.String ?? "", architecture: p["architecture"]?.String ?? "",
                                variant: p["variant"]?.String ?? "")
        }
        return Descriptor(mediaType: v["mediaType"]?.String ?? "", digest: d, size: size,
                          platform: platform, annotations: stringMap(v["annotations"]),
                          artifactType: v["artifactType"]?.String ?? "")
    }

    public func ToJson() -> json.Value {
        var o = json.Object()
        o["mediaType"] = .string(MediaType)
        o["digest"] = .string(Digest)
        o["size"] = .number("\(Size)")
        if !ArtifactType.isEmpty { o["artifactType"] = .string(ArtifactType) }
        if let p = Platform {
            var po = json.Object()
            po["architecture"] = .string(p.Architecture)
            po["os"] = .string(p.OS)
            if !p.Variant.isEmpty { po["variant"] = .string(p.Variant) }
            o["platform"] = .object(po)
        }
        if !Annotations.isEmpty { o["annotations"] = mapValue(Annotations) }
        return .object(o)
    }
}

/// An image for one platform: its config and its layers, bottom first.
public struct Manifest {
    public var MediaType: string
    public var Config: Descriptor
    public var Layers: [Descriptor]
    public var Annotations: [string: string]
    public var ArtifactType: string

    public init(config: Descriptor, layers: [Descriptor], mediaType: string = spec.MediaType.manifest,
                annotations: [string: string] = [:], artifactType: string = "") {
        MediaType = mediaType
        Config = config
        Layers = layers
        Annotations = annotations
        ArtifactType = artifactType
    }

    public static func Parse(_ bytes: [uint8]) throws -> Manifest {
        let v = try json.Parse(bytes: bytes)
        guard let c = v["config"] else { throw ImageError.malformed("a manifest needs a config") }
        var layers: [Descriptor] = []
        for l in v["layers"]?.Array ?? [] {
            layers.append(try Descriptor.FromJson(l))
        }
        return Manifest(config: try Descriptor.FromJson(c), layers: layers,
                        mediaType: v["mediaType"]?.String ?? spec.MediaType.manifest,
                        annotations: stringMap(v["annotations"]),
                        artifactType: v["artifactType"]?.String ?? "")
    }

    public func Encode() -> [uint8] {
        var o = json.Object()
        o["schemaVersion"] = .number("2")
        o["mediaType"] = .string(MediaType)
        if !ArtifactType.isEmpty { o["artifactType"] = .string(ArtifactType) }
        o["config"] = Config.ToJson()
        o["layers"] = .array(Layers.map { $0.ToJson() })
        if !Annotations.isEmpty { o["annotations"] = mapValue(Annotations) }
        return [uint8](json.Encode(.object(o)).utf8)
    }
}

/// Manifests for several platforms (a "manifest list" in Docker's words),
/// or, in an image layout, the images a store holds.
public struct Index {
    public var MediaType: string
    public var Manifests: [Descriptor]

    public init(manifests: [Descriptor], mediaType: string = spec.MediaType.index) {
        MediaType = mediaType
        Manifests = manifests
    }

    public static func Parse(_ bytes: [uint8]) throws -> Index {
        let v = try json.Parse(bytes: bytes)
        var ms: [Descriptor] = []
        for m in v["manifests"]?.Array ?? [] {
            ms.append(try Descriptor.FromJson(m))
        }
        return Index(manifests: ms, mediaType: v["mediaType"]?.String ?? spec.MediaType.index)
    }

    public func Encode() -> [uint8] {
        var o = json.Object()
        o["schemaVersion"] = .number("2")
        o["mediaType"] = .string(MediaType)
        o["manifests"] = .array(Manifests.map { $0.ToJson() })
        return [uint8](json.Encode(.object(o), indent: "  ").utf8)
    }

    /// The manifest for `platform`, preferring an exact variant match.
    public func Select(_ platform: Platform) -> Descriptor? {
        var fallback: Descriptor? = nil
        for m in Manifests {
            guard let p = m.Platform, p.Matches(platform) else { continue }
            if p.Variant == platform.Variant { return m }
            if fallback == nil { fallback = m }
        }
        return fallback
    }
}

/// How to run an image, and the layers' uncompressed digests. Fields this
/// package doesn't model (history, healthcheck, …) are kept as they were.
public struct Config {
    var raw: json.Object
    public var Architecture: string
    public var OS: string
    public var Env: [string]
    public var Entrypoint: [string]
    public var Cmd: [string]
    public var WorkingDir: string
    public var User: string
    public var ExposedPorts: [string]
    public var Labels: [string: string]
    /// Mount points VOLUME declared.
    public var Volumes: [string]
    public var StopSignal: string
    /// Instructions to run when an image is a build's FROM (ONBUILD).
    public var OnBuild: [string]
    /// HEALTHCHECK as the config holds it: Test (["CMD-SHELL", …], ["CMD", …]
    /// or ["NONE"]) and Interval, Timeout, StartPeriod in nanoseconds.
    public var Healthcheck: json.Value?
    /// The digest of each layer uncompressed, bottom first.
    public var DiffIds: [string]

    public init(platform: Platform = .Default) {
        raw = json.Object()
        Architecture = platform.Architecture
        OS = platform.OS
        Env = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
        Entrypoint = []
        Cmd = []
        WorkingDir = ""
        User = ""
        ExposedPorts = []
        Labels = [:]
        Volumes = []
        StopSignal = ""
        OnBuild = []
        Healthcheck = nil
        DiffIds = []
    }

    public static func Parse(_ bytes: [uint8]) throws -> Config {
        let v = try json.Parse(bytes: bytes)
        guard let o = v.Object else { throw ImageError.malformed("a config is an object") }
        var c = Config()
        c.raw = o
        c.Architecture = v["architecture"]?.String ?? ""
        c.OS = v["os"]?.String ?? ""
        let run = v["config"]
        c.Env = strings(run?["Env"])
        c.Entrypoint = strings(run?["Entrypoint"])
        c.Cmd = strings(run?["Cmd"])
        c.WorkingDir = run?["WorkingDir"]?.String ?? ""
        c.User = run?["User"]?.String ?? ""
        c.ExposedPorts = run?["ExposedPorts"]?.Object?.Keys ?? []
        c.Labels = stringMap(run?["Labels"])
        c.Volumes = run?["Volumes"]?.Object?.Keys ?? []
        c.StopSignal = run?["StopSignal"]?.String ?? ""
        c.OnBuild = strings(run?["OnBuild"])
        if let h = run?["Healthcheck"], h.Object != nil { c.Healthcheck = h }
        c.DiffIds = strings(v["rootfs"]?["diff_ids"])
        return c
    }

    public func Encode() -> [uint8] {
        var o = raw
        o["architecture"] = .string(Architecture)
        o["os"] = .string(OS)
        var run = o["config"]?.Object ?? json.Object()
        run["Env"] = .array(Env.map { .string($0) })
        run["Entrypoint"] = Entrypoint.isEmpty ? .null : .array(Entrypoint.map { .string($0) })
        run["Cmd"] = Cmd.isEmpty ? .null : .array(Cmd.map { .string($0) })
        run["WorkingDir"] = .string(WorkingDir)
        run["User"] = .string(User)
        var ports = json.Object()
        for p in ExposedPorts { ports[p] = .object(json.Object()) }
        run["ExposedPorts"] = .object(ports)
        run["Labels"] = mapValue(Labels)
        if Volumes.isEmpty {
            run["Volumes"] = nil
        } else {
            var vols = json.Object()
            for v in Volumes { vols[v] = .object(json.Object()) }
            run["Volumes"] = .object(vols)
        }
        run["StopSignal"] = StopSignal.isEmpty ? nil : .string(StopSignal)
        run["OnBuild"] = OnBuild.isEmpty ? nil : .array(OnBuild.map { .string($0) })
        run["Healthcheck"] = Healthcheck
        o["config"] = .object(run)
        var rootfs = json.Object()
        rootfs["type"] = .string("layers")
        rootfs["diff_ids"] = .array(DiffIds.map { .string($0) })
        o["rootfs"] = .object(rootfs)
        return [uint8](json.Encode(.object(o)).utf8)
    }

    /// An environment variable's value, or nil.
    public func Getenv(_ name: string) -> string? {
        for e in Env where e.hasPrefix(name + "=") {
            return string(e.dropFirst(name.count + 1))
        }
        return nil
    }

    /// Sets an environment variable, replacing an earlier value.
    public mutating func Setenv(_ name: string, _ value: string) {
        Env = Env.filter { !$0.hasPrefix(name + "=") }
        Env.append(name + "=" + value)
    }

    /// The command a container runs: entrypoint, then cmd.
    public var Command: [string] { Entrypoint + Cmd }
}

func strings(_ v: json.Value?) -> [string] {
    var out: [string] = []
    for e in v?.Array ?? [] {
        if let s = e.String { out.append(s) }
    }
    return out
}

func stringMap(_ v: json.Value?) -> [string: string] {
    var out: [string: string] = [:]
    for (k, e) in v?.Object?.Members ?? [] {
        if let s = e.String { out[k] = s }
    }
    return out
}

func mapValue(_ m: [string: string]) -> json.Value {
    var o = json.Object()
    for k in m.keys.sorted() { o[k] = .string(m[k]!) }
    return .object(o)
}
