// Package build makes images from Dockerfiles into an oci store, as
// `docker build` does: each stage from its FROM, COPY and ADD from the
// build context or another stage, the config instructions, and RUN --
// which needs a Linux to run in, so an Executor does it (container/virt's
// boots the tree so far as a VM) and build keeps what it changed as a
// layer.
//
//     let b = build.Builder(store: st, executor: container.VmExecutor())
//     let img = try await b.Build(build.Options(context: "."))
package build

import (
    "archive/tar"
    "compress/gzip"
    "crypto/sha256"
    "encoding/json"
    "fs"
    "io"
    "net/http"
    "net/url"
    "oci/digest"
    "oci/dockerfile"
    "oci/registry"
    "oci/rootfs"
    "oci/spec"
    "oci/store"
)

public enum BuildError: Error, CustomStringConvertible {
    case noExecutor(line: int)
    case runFailed(line: int, command: string, status: int32)
    case badInstruction(line: int, message: string)
    case notInContext(string)
    case noStage(string)

    public var description: string {
        switch self {
        case .noExecutor(let l):
            return "line \(l): RUN needs a Linux to run in; build with `container build`, which runs it in a VM"
        case .runFailed(let l, let c, let s):
            return "line \(l): RUN \(c) exited with \(s)"
        case .badInstruction(let l, let m): return "line \(l): \(m)"
        case .notInContext(let p): return "\(p) is not in the build context"
        case .noStage(let s): return "no stage called \(s)"
        }
    }
}

/// Runs a RUN instruction's command.
public protocol Executor: AnyObject {
    /// Runs `command` in the tree `layers` make, bottom first, with `env`
    /// ("KEY=value") in `workdir` as `user`, and writes the tree it leaves
    /// to `output` as a tar. Returns the command's exit status.
    func Run(layers: [rootfs.Layer], env: [string], workdir: string, user: string,
             command: [string], output: fs.Path) async throws -> int32
}

/// What to build.
public struct Options {
    /// The build context: the directory COPY and ADD read from.
    public var Context: string
    /// The Dockerfile; nil is Context/Dockerfile.
    public var Dockerfile: string? = nil
    /// The name to give the image; nil leaves it unnamed (by digest).
    public var Tag: string? = nil
    /// --build-arg values.
    public var BuildArgs: [string: string] = [:]
    /// The stage to stop at; nil is the last.
    public var Target: string? = nil
    public var Platform: spec.Platform = spec.Platform.Default

    public init(context: string) {
        Context = context
    }
}

/// A stage's image as built so far.
final class State {
    var layers: [spec.Descriptor] = []
    var config: spec.Config
    var history: [json.Value] = []
    var vars: [string: string] = [:]
    var shell: [string] = ["/bin/sh", "-c"]
    var plan: rootfs.Plan? = nil
    var pendingWorkdir: string? = nil

    init(config: spec.Config) {
        self.config = config
    }
}

public final class Builder {
    let st: store.Store
    let executor: Executor?
    let log: (string) -> Void
    var stages: [string: State] = [:]

    public init(store st: store.Store, executor: Executor? = nil, log: @escaping (string) -> Void = { print($0) }) {
        self.st = st
        self.executor = executor
        self.log = log
    }

    /// Builds `o` and returns the image, named o.Tag if given.
    public func Build(_ o: Options) async throws -> store.Image {
        let path = o.Dockerfile ?? (o.Context + "/Dockerfile")
        let file = try dockerfile.Parse(try fs.ReadText(fs.Path(path)))
        let ignore = Ignore(try? fs.ReadText(fs.Path(o.Context + "/.dockerignore")))
        var globals: [string: string] = [:]
        for (k, v) in file.GlobalArgs {
            if let given = o.BuildArgs[k] { globals[k] = given } else if let d = v { globals[k] = d }
        }
        var last = file.Stages.count - 1
        if let t = o.Target {
            guard let s = file.FindStage(t) else { throw BuildError.noStage(t) }
            last = s.Index
        }
        var final: State? = nil
        for stage in file.Stages[0...last] {
            log("[\(stage.Index + 1)/\(last + 1)] FROM \(dockerfile.Expand(stage.From, globals))" +
                (stage.Name.isEmpty ? "" : " AS \(stage.Name)"))
            let s = try await from(dockerfile.Expand(stage.From, globals), o.Platform)
            for (k, v) in globals { s.vars[k] = v }
            if stages[dockerfile.Expand(stage.From, globals).lowercased()] == nil {
                try await trigger(s, o, ignore, globals)
            }
            for ins in stage.Instructions {
                try await step(ins, s, o, ignore, globals)
            }
            try flushWorkdir(s)
            stages[stage.Name.isEmpty ? "\(stage.Index)" : stage.Name] = s
            stages["\(stage.Index)"] = s
            final = s
        }
        return try commit(final!, o)
    }

    /// The state FROM starts with: a stage before, nothing, or an image.
    func from(_ name: string, _ platform: spec.Platform) async throws -> State {
        if let prev = stages[name.lowercased()] {
            let s = State(config: prev.config)
            s.layers = prev.layers
            s.history = prev.history
            s.plan = prev.plan
            return s
        }
        if name == "scratch" {
            var c = spec.Config(platform: platform)
            c.Env = []
            return State(config: c)
        }
        var img: store.Image
        if st.Resolve(name) == nil {
            log("  pulling \(name)")
            img = try await registry.Pull(name, into: st, platform: platform)
        } else {
            img = try st.Image(name, platform: platform)
        }
        let s = State(config: img.Config)
        s.layers = img.Manifest.Layers
        if let h = (try? json.Parse(bytes: img.Config.Encode()))?["history"]?.Array {
            s.history = h
        }
        return s
    }

    func step(_ ins: dockerfile.Instruction, _ s: State, _ o: Options, _ ignore: Ignore,
              _ globals: [string: string]) async throws {
        let expand = { (t: string) -> string in dockerfile.Expand(t, s.vars) }
        log("  \(ins.Command) \(ins.Rest)")
        switch ins.Command {
        case "ARG":
            for (k, v) in dockerfile.ArgPairs(ins.Rest) {
                if let given = o.BuildArgs[k] {
                    s.vars[k] = given
                } else if let d = v {
                    s.vars[k] = expand(d)
                } else if let g = globals[k] {
                    s.vars[k] = g
                }
            }
        case "ENV":
            for (k, v) in dockerfile.ArgPairs(ins.Rest) {
                let value = expand(v ?? "")
                s.config.Setenv(k, value)
                s.vars[k] = value
            }
            note(s, ins, empty: true)
        case "LABEL":
            for (k, v) in dockerfile.ArgPairs(ins.Rest) {
                s.config.Labels[expand(k)] = expand(v ?? "")
            }
            note(s, ins, empty: true)
        case "MAINTAINER":
            s.config.Labels["maintainer"] = ins.Rest
            note(s, ins, empty: true)
        case "WORKDIR":
            var dir = expand(ins.Rest)
            if !dir.hasPrefix("/") {
                dir = (s.config.WorkingDir.isEmpty ? "/" : s.config.WorkingDir) + "/" + dir
            }
            s.config.WorkingDir = "/" + ((try? rootfs.Clean(dir)) ?? dir)
            s.pendingWorkdir = s.config.WorkingDir
            note(s, ins, empty: true)
        case "USER":
            s.config.User = expand(ins.Rest)
            note(s, ins, empty: true)
        case "CMD":
            s.config.Cmd = ins.Json ?? (s.shell + [ins.Rest])
            note(s, ins, empty: true)
        case "ENTRYPOINT":
            s.config.Entrypoint = ins.Json ?? (s.shell + [ins.Rest])
            // As Docker does: a new entrypoint drops an inherited CMD.
            s.config.Cmd = []
            note(s, ins, empty: true)
        case "SHELL":
            guard let j = ins.Json, !j.isEmpty else {
                throw BuildError.badInstruction(line: ins.Line, message: "SHELL takes a JSON array")
            }
            s.shell = j
            note(s, ins, empty: true)
        case "EXPOSE":
            for p in ins.Words {
                let port = expand(p)
                let full = port.contains("/") ? port : port + "/tcp"
                if !s.config.ExposedPorts.contains(full) { s.config.ExposedPorts.append(full) }
            }
            note(s, ins, empty: true)
        case "STOPSIGNAL":
            s.config.StopSignal = expand(ins.Rest)
            note(s, ins, empty: true)
        case "VOLUME":
            for v in (ins.Json ?? dockerfile.SplitWords(expand(ins.Rest))) {
                let dir = "/" + ((try? rootfs.Clean(v)) ?? v)
                if !s.config.Volumes.contains(dir) { s.config.Volumes.append(dir) }
            }
            note(s, ins, empty: true)
        case "HEALTHCHECK":
            s.config.Healthcheck = try healthcheck(ins, s)
            note(s, ins, empty: true)
        case "ONBUILD":
            let words = ins.Rest.split(separator: " ", maxSplits: 1).map { string($0) }
            guard let first = words.first, !["ONBUILD", "FROM", "MAINTAINER"].contains(first.uppercased()) else {
                throw BuildError.badInstruction(line: ins.Line, message: "ONBUILD can't trigger \(ins.Rest)")
            }
            s.config.OnBuild.append(ins.Rest)
            note(s, ins, empty: true)
        case "COPY", "ADD":
            try await copy(ins, s, o, ignore)
        case "RUN":
            try await run(ins, s)
        default:
            throw BuildError.badInstruction(line: ins.Line, message: "unknown instruction \(ins.Command)")
        }
    }

    /// HEALTHCHECK's config value: NONE, or a Test with the flags' timings.
    func healthcheck(_ ins: dockerfile.Instruction, _ s: State) throws -> json.Value? {
        let rest = dockerfile.Expand(ins.Rest, s.vars)
        if rest.uppercased() == "NONE" {
            var o = json.Object()
            o["Test"] = .array([.string("NONE")])
            return .object(o)
        }
        guard rest.hasPrefix("CMD") || rest.hasPrefix("cmd") else {
            throw BuildError.badInstruction(line: ins.Line, message: "HEALTHCHECK takes NONE or CMD")
        }
        let body = trimSpaces(string(rest.dropFirst(3)))
        var o = json.Object()
        if body.hasPrefix("["), let v = try? json.Parse(body), let arr = v.Array {
            o["Test"] = .array([.string("CMD")] + arr)
        } else {
            o["Test"] = .array([.string("CMD-SHELL"), .string(body)])
        }
        for (flag, key) in [("interval", "Interval"), ("timeout", "Timeout"),
                                      ("start-period", "StartPeriod"), ("start-interval", "StartInterval")] {
            guard let text = ins.Flags[flag] else { continue }
            guard let ns = duration(dockerfile.Expand(text, s.vars)) else {
                throw BuildError.badInstruction(line: ins.Line, message: "HEALTHCHECK --\(flag)=\(text) isn't a duration")
            }
            o[key] = .number("\(ns)")
        }
        if let r = ins.Flags["retries"] {
            guard let n = int(dockerfile.Expand(r, s.vars)) else {
                throw BuildError.badInstruction(line: ins.Line, message: "HEALTHCHECK --retries=\(r) isn't a number")
            }
            o["Retries"] = .number("\(n)")
        }
        return .object(o)
    }

    /// Runs the ONBUILD triggers an image carries, as if they followed
    /// the FROM, and clears them from the new image.
    func trigger(_ s: State, _ o: Options, _ ignore: Ignore, _ globals: [string: string]) async throws {
        let triggers = s.config.OnBuild
        if triggers.isEmpty { return }
        s.config.OnBuild = []
        let file = try dockerfile.Parse("FROM scratch\n" + triggers.joined(separator: "\n"))
        for ins in file.Stages[0].Instructions {
            log("  ONBUILD \(ins.Command) \(ins.Rest)")
            try await step(ins, s, o, ignore, globals)
        }
    }

    /// A history entry for an instruction.
    func note(_ s: State, _ ins: dockerfile.Instruction, empty: bool) {
        var h = json.Object()
        h["created_by"] = .string("\(ins.Command) \(ins.Rest)")
        h["comment"] = .string("vertex-oci")
        if empty { h["empty_layer"] = .bool(true) }
        s.history.append(.object(h))
    }

    /// Adds `tarBytes` (uncompressed) as a layer.
    func addLayer(_ s: State, _ tarBytes: [uint8], _ ins: dockerfile.Instruction?) throws {
        let diffId = digest.Digest.Of(tarBytes)
        let gz = gzip.Compress(tarBytes)
        let d = try st.WriteBlob(gz)
        s.layers.append(spec.Descriptor(mediaType: spec.MediaType.layerGzip, digest: d.description, size: int64(gz.count)))
        s.config.DiffIds.append(diffId.description)
        s.plan = nil
        if let i = ins {
            note(s, i, empty: false)
        }
    }

    /// The tree the layers so far make.
    func plan(_ s: State) throws -> rootfs.Plan {
        if let p = s.plan { return p }
        var ls: [rootfs.Layer] = []
        for l in s.layers {
            ls.append(rootfs.Layer(path: st.BlobPath(try digest.Digest.Parse(l.Digest)), mediaType: l.MediaType))
        }
        let p = try rootfs.Merge(ls)
        s.plan = p
        return p
    }

    /// A WORKDIR no RUN made: a layer with the directory.
    func flushWorkdir(_ s: State) throws {
        guard let dir = s.pendingWorkdir, dir != "/" else { return }
        s.pendingWorkdir = nil
        let rel = (try? rootfs.Clean(dir)) ?? dir
        if (try plan(s)).Lookup(rel) != nil { return }
        var w = tar.Writer(io.Cursor())
        var at = ""
        for part in rel.split(separator: "/") {
            at = at.isEmpty ? string(part) : at + "/" + string(part)
            if (try plan(s)).Lookup(at) == nil {
                try w.WriteHeader(tar.Header(name: at + "/", mode: 0o755, typeflag: .directory))
            }
        }
        try w.Close()
        try addLayer(s, w.Inner.Bytes, nil)
    }

    func run(_ ins: dockerfile.Instruction, _ s: State) async throws {
        guard let ex = executor else { throw BuildError.noExecutor(line: ins.Line) }
        if ins.Flags["mount"] != nil {
            log("    (RUN --mount is not supported; running without it)")
        }
        let command = ins.Json ?? (s.shell + [ins.Rest])
        // ARGs are in the environment of the RUNs after them.
        var env = s.config.Env
        for (k, v) in s.vars where s.config.Getenv(k) == nil {
            env.append(k + "=" + v)
        }
        var layers: [rootfs.Layer] = []
        for l in s.layers {
            layers.append(rootfs.Layer(path: st.BlobPath(try digest.Digest.Parse(l.Digest)), mediaType: l.MediaType))
        }
        let out = st.Root / "ingest" / "run-\(digest.Digest.Of([uint8]("\(ins.Line)\(command)".utf8)).Short).tar"
        defer { try? fs.Remove(out) }
        let status = try await ex.Run(layers: layers, env: env, workdir: s.config.WorkingDir.isEmpty ? "/" : s.config.WorkingDir,
                                      user: s.config.User, command: command, output: out)
        if status != 0 {
            throw BuildError.runFailed(line: ins.Line, command: ins.Rest, status: status)
        }
        let layer = try Diff(parent: try plan(s), tree: out)
        s.pendingWorkdir = nil
        try addLayer(s, layer, ins)
    }

    // MARK: COPY and ADD

    /// Where a destination is, absolute, without the leading "/".
    func destination(_ d: string, _ s: State) -> string {
        var p = d
        if !p.hasPrefix("/") {
            p = (s.config.WorkingDir.isEmpty ? "/" : s.config.WorkingDir) + "/" + p
        }
        return (try? rootfs.Clean(p)) ?? p
    }

    func copy(_ ins: dockerfile.Instruction, _ s: State, _ o: Options, _ ignore: Ignore) async throws {
        var words = ins.Words.map { dockerfile.Expand($0, s.vars) }
        if words.count < 2 {
            throw BuildError.badInstruction(line: ins.Line, message: "\(ins.Command) needs a source and a destination")
        }
        let destWord = words.removeLast()
        let dest = destination(destWord, s)
        let destIsDir = destWord.hasSuffix("/") || words.count > 1
        let owner = ownerOf(ins.Flags["chown"])
        let chmod = ins.Flags["chmod"].flatMap { uint32($0, radix: 8) }
        var w = tar.Writer(io.Cursor())
        var made = Set<string>()

        func parents(_ path: string) throws {
            var at = ""
            let parts = path.split(separator: "/").map { string($0) }
            for part in parts.dropLast() {
                at = at.isEmpty ? part : at + "/" + part
                if made.contains(at) { continue }
                made.insert(at)
                try w.WriteHeader(tar.Header(name: at + "/", mode: 0o755, typeflag: .directory,
                                             uid: owner.0, gid: owner.1))
            }
        }

        func put(_ h: tar.Header, _ data: [uint8]) throws {
            try parents(h.Name)
            var out = h
            out.Uid = owner.0
            out.Gid = owner.1
            if let m = chmod, h.Typeflag != tar.FileType.symlink { out.Mode = int64(m) }
            if h.Typeflag == tar.FileType.directory {
                if made.contains(h.Name) { return }
                made.insert(h.Name)
                out.Name = h.Name + "/"
            }
            try w.WriteHeader(out)
            if !data.isEmpty { try w.Write(data) }
        }

        if let fromName = ins.Flags["from"] {
            // Out of another stage's tree, or an image's.
            let src = try await from(dockerfile.Expand(fromName, s.vars), o.Platform)
            let p = try plan(src)
            for word in words {
                let rel = (try? rootfs.Clean(word)) ?? word
                guard let top = p.Lookup(rel) else { throw BuildError.notInContext("\(fromName):\(word)") }
                let base = string(rel.split(separator: "/").last ?? "")
                let into = top.Kind == rootfs.Kind.directory || destIsDir
                let sink = Collect(prefix: rel)
                try p.Emit(to: sink)
                for (e, data) in sink.Entries {
                    var name: string
                    if e.Path == rel {
                        if top.Kind == rootfs.Kind.directory { continue }
                        name = into ? dest + "/" + base : dest
                    } else {
                        let sub = string(e.Path.dropFirst(rel.count + 1))
                        name = (top.Kind == rootfs.Kind.directory ? dest : dest + "/" + base) + "/" + sub
                    }
                    try put(entryHeader(e, name, data.count), data)
                }
            }
        } else {
            for word in words {
                if ins.Command == "ADD" && (word.hasPrefix("http://") || word.hasPrefix("https://")) {
                    let data = try await download(word)
                    let base = string(word.split(separator: "/").last ?? "download")
                    let name = destIsDir ? dest + "/" + base : dest
                    try put(tar.Header(name: name, size: int64(data.count), mode: 0o600, typeflag: .regular), data)
                    continue
                }
                let matches = try contextMatches(o.Context, word, ignore)
                if matches.isEmpty { throw BuildError.notInContext(word) }
                let into = destIsDir || matches.count > 1
                for m in matches {
                    let full = fs.Path(o.Context) / m
                    let meta = try fs.Stat(full, followSymlinks: false)
                    let base = string(m.split(separator: "/").last ?? "")
                    if meta.IsDir() {
                        try walk(o.Context, m, ignore) { rel, md, data, link in
                            let name = dest + "/" + string(rel.dropFirst(m.count + 1))
                            try put(hostHeader(name, md, data.count, link), data)
                        }
                        continue
                    }
                    let data = meta.IsSymlink() ? [] : try fs.ReadFile(full)
                    // ADD unpacks a local tar into the destination.
                    if ins.Command == "ADD" && isTar(m) {
                        try untar(data, m, dest) { h, d in try put(h, d) }
                        continue
                    }
                    let link = meta.IsSymlink() ? (try fs.ReadLink(full)).Value : ""
                    let name = into ? dest + "/" + base : dest
                    try put(hostHeader(name, meta, data.count, link), data)
                }
            }
        }
        try w.Close()
        try addLayer(s, w.Inner.Bytes, ins)
    }

    func download(_ address: string) async throws -> [uint8] {
        var cfg = http.ClientConfig(enabledVersions: [http.HttpVersion.http1_1, http.HttpVersion.http2])
        cfg.MaxRedirects = 10
        var c = http.Client(config: cfg)
        let target = try url.Parse(address)
        let res = try await c.DoUrl(http.Request(method: "GET", url: target.RequestURI), url: target)
        if res.StatusCode != 200 {
            throw BuildError.badInstruction(line: 0, message: "ADD \(address): \(res.StatusCode)")
        }
        return res.Body
    }

    // MARK: Committing

    func commit(_ s: State, _ o: Options) throws -> store.Image {
        var cfg = s.config
        var raw = (try? json.Parse(bytes: cfg.Encode()))?.Object ?? json.Object()
        raw["history"] = .array(s.history)
        raw["created"] = .string("1970-01-01T00:00:00Z")
        var configBytes = [uint8](json.Encode(.object(raw)).utf8)
        if let back = try? spec.Config.Parse(configBytes) {
            cfg = back
            configBytes = cfg.Encode()
        }
        let cd = try st.WriteBlob(configBytes)
        let m = spec.Manifest(config: spec.Descriptor(mediaType: spec.MediaType.config, digest: cd.description,
                                                      size: int64(configBytes.count)),
                              layers: s.layers)
        let mb = m.Encode()
        let md = try st.WriteBlob(mb)
        let name = o.Tag ?? "vertex.local/build/\(md.Short):latest"
        try st.Tag(name, spec.Descriptor(mediaType: spec.MediaType.manifest, digest: md.description,
                                         size: int64(mb.count), platform: o.Platform))
        return try st.Image(name, platform: o.Platform)
    }
}

/// "30s", "1m30s", "500ms" as nanoseconds.
func duration(_ text: string) -> int64? {
    var total: int64 = 0
    var num = ""
    var unit = ""
    func flush() -> bool {
        guard let n = float64(num) else { return false }
        let per: float64
        switch unit {
        case "ns": per = 1
        case "us", "µs": per = 1e3
        case "ms": per = 1e6
        case "s": per = 1e9
        case "m": per = 60e9
        case "h": per = 3600e9
        default: return false
        }
        total += int64(n * per)
        num = ""
        unit = ""
        return true
    }
    for ch in text {
        if ch.isNumber || ch == "." {
            if !unit.isEmpty && !flush() { return nil }
            num.append(ch)
        } else {
            unit.append(ch)
        }
    }
    if num.isEmpty || !flush() { return nil }
    return total
}

func trimSpaces(_ s: string) -> string {
    var b = [uint8](s.utf8)
    while let f = b.first, f == 0x20 || f == 0x09 { b.removeFirst() }
    while let l = b.last, l == 0x20 || l == 0x09 { b.removeLast() }
    return string(decoding: b, as: UTF8.self)
}

/// `--chown=uid[:gid]`, numbers or root; 0:0 otherwise.
func ownerOf(_ flag: string?) -> (int, int) {
    guard let f = flag else { return (0, 0) }
    let parts = f.split(separator: ":").map { string($0) }
    func id(_ s: string) -> int { s == "root" ? 0 : (int(s) ?? 0) }
    let u = parts.isEmpty ? 0 : id(parts[0])
    return (u, parts.count > 1 ? id(parts[1]) : u)
}

func isTar(_ name: string) -> bool {
    name.hasSuffix(".tar") || name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
}

/// A tar header for a file of this machine's, put at `name`.
func hostHeader(_ name: string, _ m: fs.FileMetadata, _ size: int, _ link: string) -> tar.Header {
    let mode = int64((m.Unix?.Mode ?? 0o644) & 0o7777)
    if m.IsDir() {
        return tar.Header(name: name, mode: mode, typeflag: .directory, modTime: m.Modified.UnixSeconds)
    }
    if m.IsSymlink() {
        return tar.Header(name: name, mode: 0o777, typeflag: .symlink, modTime: m.Modified.UnixSeconds, linkname: link)
    }
    return tar.Header(name: name, size: int64(size), mode: mode, typeflag: .regular, modTime: m.Modified.UnixSeconds)
}

/// A tar header for an entry of a merged tree, put at `name`.
func entryHeader(_ e: rootfs.Entry, _ name: string, _ size: int) -> tar.Header {
    var t = tar.FileType.regular
    switch e.Kind {
    case .directory: t = .directory
    case .symlink: t = .symlink
    case .hardlink: t = .link
    case .charDevice: t = .characterDevice
    case .blockDevice: t = .blockDevice
    case .fifo: t = .fifo
    default: break
    }
    return tar.Header(name: name, size: int64(size), mode: int64(e.Mode), typeflag: t, modTime: e.ModTime,
                      uid: int(e.Uid), gid: int(e.Gid), linkname: e.Linkname,
                      devmajor: int64(e.DevMajor), devminor: int64(e.DevMinor))
}

/// Unpacks a (perhaps gzipped) tar's entries under `dest`.
func untar(_ data: [uint8], _ name: string, _ dest: string, _ put: (tar.Header, [uint8]) throws -> Void) throws {
    let bytes = (data.count > 2 && data[0] == 0x1F && data[1] == 0x8B) ? try gzip.Decompress(data) : data
    var r = tar.Reader(io.Cursor(bytes))
    while let h = try r.Next() {
        guard let rel = try? rootfs.Clean(h.Name), !rel.isEmpty else { continue }
        var out = h
        out.Name = dest + "/" + rel
        out.Prefix = ""
        let body = try r.ReadAll()
        try put(out, body)
    }
}

/// Collects the entries under a path of a merged tree, with their data.
final class Collect: rootfs.Sink {
    let prefix: string
    var Entries: [(rootfs.Entry, [uint8])] = []

    init(prefix: string) {
        self.prefix = prefix
    }

    func Add(_ e: rootfs.Entry, _ data: [uint8]) throws {
        if e.Path == prefix || e.Path.hasPrefix(prefix + "/") {
            Entries.append((e, data))
        }
    }

    func Finish() throws {}
}

/// A file's SHA-256, for content that wants naming.
func sha(_ b: [uint8]) -> string {
    sha256.ToHex(sha256.Sum256(b))
}
