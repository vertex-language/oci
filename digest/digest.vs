// Package digest names content by its hash, as OCI does everywhere:
// "sha256:" and 64 hex digits. A blob is trusted once its bytes hash to
// the digest it was asked for.
package digest

import "crypto/sha256"

public enum DigestError: Error, CustomStringConvertible {
    case malformed(string)
    case unsupported(string)
    case mismatch(expected: string, got: string)

    public var description: string {
        switch self {
        case .malformed(let s): return "not a digest: \(s)"
        case .unsupported(let s): return "unsupported digest algorithm: \(s)"
        case .mismatch(let e, let g): return "content is \(g), expected \(e)"
        }
    }
}

/// "sha256:<64 hex digits>".
public struct Digest: Equatable, Hashable, CustomStringConvertible {
    public let Algorithm: string
    public let Hex: string

    public init(algorithm: string, hex: string) {
        Algorithm = algorithm
        Hex = hex
    }

    /// Parses and checks "algorithm:hex".
    public static func Parse(text: string) throws -> Digest {
        let parts = text.split(separator: ":", maxSplits: 1)
        if parts.count != 2 { throw DigestError.malformed(text) }
        let alg = string(parts[0])
        let hex = string(parts[1])
        if alg != "sha256" { throw DigestError.unsupported(alg) }
        if hex.utf8.count != 64 { throw DigestError.malformed(text) }
        for c in hex.utf8 {
            let ok = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)
            if !ok { throw DigestError.malformed(text) }
        }
        return Digest(algorithm: alg, hex: hex)
    }

    /// The SHA-256 digest of `data`.
    public static func Of(data: [uint8]) -> Digest {
        Digest(algorithm: "sha256", hex: sha256.ToHex(sha256.Sum256(data)))
    }

    /// Checks that `data` is what this digest names.
    public func Verify(data: [uint8]) throws {
        let got = Digest.Of(data)
        if got != self {
            throw DigestError.mismatch(expected: description, got: got.description)
        }
    }

    public var description: string { Algorithm + ":" + Hex }

    /// The first 12 hex digits: how `docker images` shows an ID.
    public var Short: string { string(Hex.prefix(12)) }
}
