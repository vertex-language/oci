// oci's checks, offline: digests, references, the image-spec types, the
// store, merging layers with whiteouts, and Dockerfile parsing. The
// program exits with the number that failed.
//
//     vsc run ./cmd/check
package main

import (
    "encoding/json"
    "archive/tar"
    "compress/gzip"
    "fs"
    "io"
    "oci/digest"
    "oci/dockerfile"
    "oci/reference"
    "oci/rootfs"
    "oci/spec"
    "oci/store"
)

var failures: int32 = 0

func check(ok: bool, what: string) {
    if ok {
        print("ok    \(what)")
    } else {
        print("FAIL  \(what)")
        failures += 1
    }
}

func testDigest() {
    let d = digest.Digest.Of([uint8]("abc".utf8))
    check(d.description == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc")
    check((try? digest.Digest.Parse(d.description)) == d, "a digest parses back")
    check((try? digest.Digest.Parse("sha256:xyz")) == nil, "a short digest is refused")
    check((try? digest.Digest.Parse("md5:" + d.Hex)) == nil, "another algorithm is refused")
    var refused = false
    do { try d.Verify([uint8]("abd".utf8)) } catch { refused = true }
    check(refused, "Verify refuses other bytes")
    check(d.Short == "ba7816bf8f01", "Short is 12 hex digits")
}

func testReference() {
    func full(s: string) -> string { (try? reference.Reference.Parse(s))?.description ?? "error" }
    check(full("alpine") == "docker.io/library/alpine:latest", "a bare name is Docker Hub's library")
    check(full("alpine:3.20") == "docker.io/library/alpine:3.20", "a tag")
    check(full("user/app") == "docker.io/user/app:latest", "a user repository")
    check(full("ghcr.io/owner/app:v1") == "ghcr.io/owner/app:v1", "another registry")
    check(full("localhost:5000/app") == "localhost:5000/app:latest", "a registry with a port")
    let h = String(repeating: "a", count: 64)
    check(full("alpine@sha256:" + h) == "docker.io/library/alpine@sha256:" + h, "a digest")
    check(full("Alpine") == "error", "upper case is refused")
    if let r = try? reference.Reference.Parse("alpine:3.20") {
        check(r.ApiHost == "registry-1.docker.io" && r.Familiar == "alpine:3.20", "Docker Hub's API host and short name")
    }
}

func testSpec() {
    let idx = spec.Index(manifests: [
        spec.Descriptor(mediaType: spec.MediaType.manifest, digest: "sha256:1", size: 1,
                        platform: spec.Platform(os: "linux", architecture: "amd64")),
        spec.Descriptor(mediaType: spec.MediaType.manifest, digest: "sha256:2", size: 1,
                        platform: spec.Platform(os: "linux", architecture: "arm64", variant: "v8")),
    ])
    check(idx.Select(spec.Platform.Default)?.Digest == "sha256:2", "an index selects linux/arm64/v8")
    check(idx.Select(spec.Platform(os: "windows", architecture: "arm64")) == nil, "no image for windows")
    if let back = try? spec.Index.Parse(idx.Encode()) {
        check(back.Manifests.count == 2 && back.Manifests[1].Platform?.Variant == "v8", "an index round-trips")
    } else {
        check(false, "an index round-trips")
    }
    var cfg = spec.Config()
    cfg.Cmd = ["sh"]
    cfg.Setenv("A", "1")
    cfg.Setenv("A", "2")
    cfg.DiffIds = ["sha256:x"]
    cfg.Volumes = ["/data"]
    cfg.StopSignal = "SIGTERM"
    cfg.OnBuild = ["COPY a /b"]
    cfg.Healthcheck = try? json.Parse("{\"Test\":[\"CMD-SHELL\",\"true\"],\"Retries\":3}")
    if let back = try? spec.Config.Parse(cfg.Encode()) {
        check(back.Getenv("A") == "2" && back.Cmd == ["sh"] && back.DiffIds == ["sha256:x"], "a config round-trips")
        check(back.Volumes == ["/data"] && back.StopSignal == "SIGTERM" && back.OnBuild == ["COPY a /b"] &&
              back.Healthcheck?["Retries"]?.Int == 3, "volumes, stop signal, healthcheck and onbuild round-trip")
    } else {
        check(false, "a config round-trips")
    }
}

/// A gzipped tar of entries: (name, type, data, linkname).
func layer(entries: [(string, tar.FileType, string, string)]) throws -> [uint8] {
    var w = tar.Writer(io.Cursor())
    for (name, t, data, link) in entries {
        let bytes = [uint8](data.utf8)
        try w.WriteHeader(tar.Header(name: name, size: t == tar.FileType.regular ? int64(bytes.count) : 0,
                                     mode: t == tar.FileType.directory ? 0o755 : 0o644, typeflag: t,
                                     modTime: 1700000000, linkname: link))
        if t == tar.FileType.regular && !bytes.isEmpty {
            try w.Write(bytes)
        }
    }
    try w.Close()
    return gzip.Compress(w.Inner.Bytes)
}

/// Collects what a plan emits.
final class Collect: rootfs.Sink {
    var files: [string: string] = [:]
    var kinds: [string: rootfs.Kind] = [:]
    var finished = false
    func Add(e: rootfs.Entry, data: [uint8]) throws {
        kinds[e.Path] = e.Kind
        if e.Kind == rootfs.Kind.file {
            files[e.Path] = string(decoding: data, as: UTF8.self)
        }
    }
    func Finish() throws { finished = true }
}

func testStoreAndRootfs(tmp: fs.Path) {
    do {
        let st = try store.Store(root: (tmp / "store").String())
        let d = try st.WriteBlob([uint8]("hello".utf8))
        check(st.HasBlob(d) && (try st.ReadBlob(d)) == [uint8]("hello".utf8), "a blob is stored and read back")
        let ing = try st.BeginIngest("x.partial")
        try ing.Write([uint8]("hel".utf8))
        try ing.Write([uint8]("lo".utf8))
        check((try? ing.Commit(expected: digest.Digest.Of([uint8]("nope".utf8)))) == nil, "an ingest of other bytes is refused")

        let base = try layer([("etc/", tar.FileType.directory, "", ""), ("etc/a", tar.FileType.regular, "a1", ""),
                              ("etc/b", tar.FileType.regular, "b1", ""), ("opt/", tar.FileType.directory, "", ""),
                              ("opt/x", tar.FileType.regular, "x", ""), ("bin/", tar.FileType.directory, "", ""),
                              ("bin/sh", tar.FileType.regular, "shell", ""),
                              ("bin/ash", tar.FileType.link, "", "bin/sh")])
        let top = try layer([("etc/a", tar.FileType.regular, "a2", ""), ("etc/.wh.b", tar.FileType.regular, "", ""),
                             ("opt/.wh..wh..opq", tar.FileType.regular, "", ""), ("opt/y", tar.FileType.regular, "y", ""),
                             ("./usr/lib/../../../escape", tar.FileType.regular, "", "")])
        let l1 = try st.WriteBlob(base)
        let l2 = try st.WriteBlob(top)
        let layers = [rootfs.Layer(path: st.BlobPath(l1), mediaType: spec.MediaType.layerGzip),
                      rootfs.Layer(path: st.BlobPath(l2), mediaType: spec.MediaType.layerGzip)]
        do {
            _ = try rootfs.Merge(layers)
            check(false, "a path climbing out of the root is refused")
        } catch {
            check(true, "a path climbing out of the root is refused")
        }
        let safeTop = try layer([("etc/a", tar.FileType.regular, "a2", ""), ("etc/.wh.b", tar.FileType.regular, "", ""),
                                 ("opt/.wh..wh..opq", tar.FileType.regular, "", ""), ("opt/y", tar.FileType.regular, "y", "")])
        let l3 = try st.WriteBlob(safeTop)
        let plan = try rootfs.Merge([layers[0], rootfs.Layer(path: st.BlobPath(l3), mediaType: spec.MediaType.layerGzip)])
        let c = Collect()
        try plan.Emit(to: c)
        check(c.files["etc/a"] == "a2", "an upper layer's file replaces the lower's")
        check(c.kinds["etc/b"] == nil, "a whiteout removes a lower file")
        check(c.kinds["opt/x"] == nil && c.files["opt/y"] == "y" && c.kinds["opt"] == rootfs.Kind.directory,
              "an opaque whiteout empties the directory of lower files only")
        check(c.kinds["bin/ash"] == rootfs.Kind.hardlink && plan.LinkCounts["bin/sh"] == 2, "hard links are kept and counted")
        check(c.finished && plan.Whiteouts == 2, "the sink is finished; two whiteouts applied")

        // A zstd layer, by media type and by its magic alone.
        let zlayer = try fs.ReadFile(fs.Path("testdata/layer.tar.zst"))
        let lz = try st.WriteBlob(zlayer)
        for mt in [spec.MediaType.layerZstd, spec.MediaType.layerTar] {
            let zp = try rootfs.Merge([rootfs.Layer(path: st.BlobPath(lz), mediaType: mt)])
            let zc = Collect()
            try zp.Emit(to: zc)
            check(zc.files["etc/a"] == "zstd-a\n" && zc.files["opt/x"] == "zstd-x\n", "a zstd layer merges (\(mt))")
        }

        // The tag, an image, and pruning.
        var cfg = spec.Config()
        cfg.DiffIds = ["sha256:0", "sha256:1"]
        let cd = try st.WriteBlob(cfg.Encode())
        let m = spec.Manifest(config: spec.Descriptor(mediaType: spec.MediaType.config, digest: cd.description,
                                                      size: try st.BlobSize(cd)),
                              layers: [spec.Descriptor(mediaType: spec.MediaType.layerGzip, digest: l1.description, size: int64(base.count)),
                                       spec.Descriptor(mediaType: spec.MediaType.layerGzip, digest: l3.description, size: int64(safeTop.count))])
        let mb = m.Encode()
        let md = try st.WriteBlob(mb)
        try st.Tag("test/image:1", spec.Descriptor(mediaType: spec.MediaType.manifest, digest: md.description,
                                                   size: int64(mb.count), platform: spec.Platform.Default))
        let again = try store.Store(root: (tmp / "store").String())
        check(again.Resolve("docker.io/test/image:1") != nil && again.Resolve(md.Short) != nil,
              "a name is found in full and by digest prefix after reopening")
        let img = try again.Image("test/image:1")
        check(img.Manifest.Layers.count == 2 && img.Config.DiffIds.count == 2, "the image reads back")
        let freed = try again.Prune()
        check(!again.HasBlob(l2) && again.HasBlob(l1) && again.HasBlob(l3) && freed > 0, "prune keeps what a name reaches")
        try again.Untag("test/image:1")
        check(again.Records.isEmpty, "untag forgets the name")
    } catch {
        check(false, "store and rootfs threw \(error)")
    }
}

func testDockerfile() {
    let text = """
# syntax=docker/dockerfile:1
ARG BASE=alpine
ARG TAG
FROM ${BASE}:${TAG:-3.20} AS build
# a comment
RUN apk add --no-cache \\
      gcc \\
    # a comment inside a continuation
      musl-dev
ENV A=1 B="two words" C=$A
ENV LEGACY some value here
COPY --chown=1000:1000 ["src dir/", "/app/"]
WORKDIR /app
CMD ["./run", "--fast"]

from scratch
COPY --from=build /app/bin /bin
ENTRYPOINT /bin/app arg
"""
    do {
        let f = try dockerfile.Parse(text)
        check(f.Stages.count == 2 && f.GlobalArgs.count == 2, "two stages and two global ARGs")
        let b = f.Stages[0]
        check(b.Name == "build" && b.From == "${BASE}:${TAG:-3.20}", "FROM with AS")
        check(b.Instructions.count == 6, "comments and continuations fold away")
        let run = b.Instructions[0]
        check(run.Command == "RUN" && run.Rest.contains("gcc") && run.Rest.contains("musl-dev") && !run.Rest.contains("comment"),
              "a continued RUN is one instruction")
        let env = dockerfile.ArgPairs(b.Instructions[1].Rest)
        check(env.count == 3 && env[1].1 == "two words", "ENV key=value pairs with quotes")
        let legacy = dockerfile.ArgPairs(b.Instructions[2].Rest)
        check(legacy.count == 1 && legacy[0].0 == "LEGACY" && legacy[0].1 == "some value here", "ENV's legacy form")
        let copy = b.Instructions[3]
        check(copy.Flags["chown"] == "1000:1000" && copy.Json == ["src dir/", "/app/"], "COPY flags and JSON form")
        check(b.Instructions[5].Json == ["./run", "--fast"], "CMD's JSON form")
        let s2 = f.Stages[1]
        check(s2.From == "scratch" && s2.Instructions[0].Flags["from"] == "build", "lower-case from; COPY --from")
        check(s2.Instructions[1].Json == nil && s2.Instructions[1].Words == ["/bin/app", "arg"], "shell form ENTRYPOINT")
        check(f.FindStage("BUILD")?.Index == 0 && f.FindStage("1")?.Index == 1, "stages by name and number")
    } catch {
        check(false, "Dockerfile parse threw \(error)")
    }
    let vars = ["A": "1", "E": ""]
    check(dockerfile.Expand("x$A ${A}y ${B:-dflt} ${A:+alt} ${E:-e} \\$A '$A'", vars) == "x1 1y dflt alt e $A '$A'",
          "variable substitution")
    check(dockerfile.SplitWords("a \"b c\" 'd e' f\\ g") == ["a", "b c", "d e", "f g"], "word splitting")
    check((try? dockerfile.Parse("RUN x")) == nil, "RUN before FROM is refused")
    check((try? dockerfile.Parse("FROM a\nBOGUS x")) == nil, "an unknown instruction is refused")
    if let f = try? dockerfile.Parse("# escape=`\nFROM a\nRUN echo `\n  hi") {
        check(f.EscapeChar == "`" && f.Stages[0].Instructions[0].Rest == "echo  hi", "the escape directive")
    } else {
        check(false, "the escape directive")
    }
}

func main() -> int32 {
    let tmp = (try? fs.TempDir(prefix: "oci-check-")) ?? fs.Path("/tmp/oci-check")
    testDigest()
    testReference()
    testSpec()
    testStoreAndRootfs(tmp)
    testDockerfile()
    try? fs.RemoveAll(tmp)
    print(failures == 0 ? "ALL OCI CHECKS PASSED" : "\(failures) FAILED")
    return failures
}
