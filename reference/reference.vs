// Package reference parses image names the way Docker does:
//
//     alpine                      docker.io/library/alpine:latest
//     alpine:3.20                 docker.io/library/alpine:3.20
//     user/app                    docker.io/user/app:latest
//     ghcr.io/owner/app:v1        ghcr.io/owner/app:v1
//     localhost:5000/app@sha256:… a digest instead of a tag
package reference

public enum ReferenceError: Error, CustomStringConvertible {
    case invalid(string)

    public var description: string {
        switch self {
        case .invalid(let s): return "not an image reference: \(s)"
        }
    }
}

public struct Reference: Equatable, Hashable, CustomStringConvertible {
    /// The registry as named: "docker.io", "ghcr.io", "localhost:5000".
    public let Registry: string
    /// "library/alpine", "owner/app".
    public let Repository: string
    /// The tag, or "" when the reference names a digest only.
    public let Tag: string
    /// "sha256:…", or "".
    public let Digest: string

    public init(registry: string, repository: string, tag: string, digest: string = "") {
        Registry = registry
        Repository = repository
        Tag = tag
        Digest = digest
    }

    /// Parses `text`, filling in Docker's defaults.
    public static func Parse(_ text: string) throws -> Reference {
        if text.isEmpty || text.contains(" ") { throw ReferenceError.invalid(text) }
        var rest = text
        var digest = ""
        if let at = rest.firstIndex(of: "@") {
            digest = string(rest[rest.index(after: at)...])
            rest = string(rest[..<at])
            if !digest.hasPrefix("sha256:") { throw ReferenceError.invalid(text) }
        }
        // The tag is after the last ':' that comes after the last '/'.
        var tag = ""
        let slash = rest.lastIndex(of: "/")
        if let colon = rest.lastIndex(of: ":"), slash == nil || colon > slash! {
            tag = string(rest[rest.index(after: colon)...])
            rest = string(rest[..<colon])
        }
        // The first component is a registry if it looks like a host.
        var registry = "docker.io"
        var repo = rest
        if let first = rest.firstIndex(of: "/") {
            let head = string(rest[..<first])
            if head.contains(".") || head.contains(":") || head == "localhost" {
                registry = head
                repo = string(rest[rest.index(after: first)...])
            }
        }
        if repo.isEmpty || tag.contains("/") { throw ReferenceError.invalid(text) }
        for c in repo.utf8 {
            let ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2e || c == 0x5f || c == 0x2d || c == 0x2f
            if !ok { throw ReferenceError.invalid(text) }
        }
        if registry == "docker.io" && !repo.contains("/") {
            repo = "library/" + repo
        }
        if tag.isEmpty && digest.isEmpty {
            tag = "latest"
        }
        return Reference(registry: registry, repository: repo, tag: tag, digest: digest)
    }

    /// Where the registry's API is: Docker Hub's isn't at docker.io.
    public var ApiHost: string {
        Registry == "docker.io" ? "registry-1.docker.io" : Registry
    }

    /// The tag or digest to ask the registry for.
    public var Target: string { Digest.isEmpty ? Tag : Digest }

    /// The full name: "docker.io/library/alpine:3.20".
    public var description: string {
        var s = Registry + "/" + Repository
        if !Tag.isEmpty { s += ":" + Tag }
        if !Digest.isEmpty { s += "@" + Digest }
        return s
    }

    /// The short name Docker shows: "alpine:3.20", "ghcr.io/owner/app:v1".
    public var Familiar: string {
        var repo = Registry + "/" + Repository
        if Registry == "docker.io" {
            repo = Repository.hasPrefix("library/") ? string(Repository.dropFirst(8)) : Repository
        }
        return Tag.isEmpty ? repo + "@" + Digest : repo + ":" + Tag
    }
}
