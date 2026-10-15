// oci: pull, keep and prepare container images, for vm to run.
//
//     oci pull alpine:3.20             fetch an image into the store
//     oci push me/app:1                upload an image to its registry
//     oci images                       what the store holds
//     oci inspect alpine:3.20          its config and layers
//     oci unpack alpine:3.20 ./root    its layers merged into a directory
//     oci cpio alpine:3.20 root.cpio   the same tree as a newc archive
//     oci fetch alpine-vmlinuz-virt-aarch64   a pinned large file
//     oci rm alpine:3.20               forget a name
//     oci prune                        delete blobs nothing names
//
// The store is $VERTEX_OCI_ROOT, or vertex/oci in the user's data
// directory; --root says otherwise.
package main

import (
    "encoding/json"
    "oci/spec"
    "fs"
    "oci/build"
    "oci/fetch"
    "oci/registry"
    "oci/rootfs"
    "oci/store"
    "os/process"
)

func usage() {
    print("""
Usage: oci [--root <dir>] <command> [args]

Commands:
  pull <name> [--platform os/arch[/variant]]   fetch an image (default linux/arm64/v8)
  build [-t name] [-f Dockerfile] [--build-arg K=V] [--target stage] <context>
                                               build a Dockerfile (RUN needs container build)
  push <name> [--as other] [--platform os/arch]   upload an image to its registry
  images                                       list the images kept
  inspect <name>                               show an image's config and layers
  unpack <name> <dir>                          write the image's merged tree into a directory
  cpio <name> <file>                           write the merged tree as a newc cpio (an initramfs)
  fetch [<file>...]                            download pinned files vm needs (no args: list them)
  rm <name>...                                 forget names (blobs stay until prune)
  prune                                        delete blobs no name reaches
""")
}

func human(_ n: int64) -> string {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = float64(n)
    var u = 0
    while v >= 1000 && u < units.count - 1 {
        v /= 1000
        u += 1
    }
    if u == 0 { return "\(n) B" }
    let tenths = int((v * 10).rounded())
    return "\(tenths / 10).\(tenths % 10) \(units[u])"
}

func pad(_ s: string, _ n: int) -> string {
    s.count >= n ? s + " " : s + string(repeating: " ", count: n - s.count)
}

public func main() async -> int32 {
    var args = Array(process.Args.dropFirst())
    var root: string? = nil
    if args.count >= 2 && args[0] == "--root" {
        root = args[1]
        args.removeFirst(2)
    }
    guard let cmd = args.first else {
        usage()
        return 2
    }
    args.removeFirst()
    do {
        let st = try store.Store(root: root)
        switch cmd {
        case "pull":
            var platform = spec.Platform.Default
            var names: [string] = []
            var i = 0
            while i < args.count {
                if args[i] == "--platform" && i + 1 < args.count {
                    platform = spec.Platform.Parse(args[i + 1])
                    i += 2
                    continue
                }
                names.append(args[i])
                i += 1
            }
            if names.isEmpty {
                usage()
                return 2
            }
            for name in names {
                print("pulling \(name) for \(platform)")
                let img = try await registry.Pull(name, into: st, platform: platform) { p in
                    if p.What != "manifest" && p.Done == p.Total {
                        print("  \(p.What)  \(human(p.Total))")
                    }
                }
                print("\(img.Name)  \(img.ManifestDigest.Short)  \(human(img.Size))")
            }
        case "push":
            var platform = spec.Platform.Default
            var target: string? = nil
            var names: [string] = []
            var i = 0
            while i < args.count {
                if args[i] == "--platform" && i + 1 < args.count {
                    platform = spec.Platform.Parse(args[i + 1])
                    i += 2
                } else if args[i] == "--as" && i + 1 < args.count {
                    target = args[i + 1]
                    i += 2
                } else {
                    names.append(args[i])
                    i += 1
                }
            }
            if names.count != 1 {
                usage()
                return 2
            }
            print("pushing \(target ?? names[0])")
            try await registry.Push(names[0], from: st, platform: platform, as: target) { p in
                print("  \(p.What)  \(human(p.Total))")
            }
        case "build":
            var o = build.Options(context: ".")
            var i = 0
            var context: string? = nil
            while i < args.count {
                let a = args[i]
                if (a == "-t" || a == "--tag") && i + 1 < args.count {
                    o.Tag = args[i + 1]
                    i += 2
                } else if (a == "-f" || a == "--file") && i + 1 < args.count {
                    o.Dockerfile = args[i + 1]
                    i += 2
                } else if a == "--build-arg" && i + 1 < args.count {
                    let kv = args[i + 1].split(separator: "=", maxSplits: 1).map { string($0) }
                    o.BuildArgs[kv[0]] = kv.count > 1 ? kv[1] : ""
                    i += 2
                } else if a == "--target" && i + 1 < args.count {
                    o.Target = args[i + 1]
                    i += 2
                } else {
                    context = a
                    i += 1
                }
            }
            o.Context = context ?? "."
            let img = try await build.Builder(store: st).Build(o)
            print("built \(img.Name)  \(img.ManifestDigest.Short)  \(human(img.Size))")
        case "images":
            print(pad("NAME", 58) + pad("ID", 14) + pad("PLATFORM", 16) + "SIZE")
            for r in st.Records {
                let id = string(r.Descriptor.Digest.dropFirst(7).prefix(12))
                let size = (try? st.Image(r.Name).Size).map { human($0) } ?? "?"
                let kind = r.Descriptor.ArtifactType == fetch.ArtifactType ? "file" : (r.Descriptor.Platform?.description ?? "")
                print(pad(r.Name, 58) + pad(id, 14) + pad(kind, 16) + size)
            }
        case "inspect":
            guard let name = args.first else {
                usage()
                return 2
            }
            let img = try st.Image(name)
            print("Name:        \(img.Name)")
            print("Manifest:    \(img.ManifestDigest)")
            print("Platform:    \(img.Config.OS)/\(img.Config.Architecture)")
            print("Command:     \(img.Config.Command.joined(separator: " "))")
            if !img.Config.WorkingDir.isEmpty { print("WorkingDir:  \(img.Config.WorkingDir)") }
            if !img.Config.User.isEmpty { print("User:        \(img.Config.User)") }
            for e in img.Config.Env { print("Env:         \(e)") }
            for p in img.Config.ExposedPorts { print("Port:        \(p)") }
            for v in img.Config.Volumes { print("Volume:      \(v)") }
            if !img.Config.StopSignal.isEmpty { print("StopSignal:  \(img.Config.StopSignal)") }
            if let h = img.Config.Healthcheck { print("Healthcheck: \(json.Encode(h))") }
            for t in img.Config.OnBuild { print("OnBuild:     \(t)") }
            for (i, l) in img.Manifest.Layers.enumerated() {
                print("Layer \(i):     \(l.Digest)  \(human(l.Size))")
            }
        case "unpack", "cpio":
            if args.count != 2 {
                usage()
                return 2
            }
            let img = try st.Image(args[0])
            let plan = try rootfs.Merge(img, in: st)
            print("\(plan.Count) entries, \(human(plan.FileBytes)) of files, \(plan.Whiteouts) whiteouts")
            if cmd == "unpack" {
                let sink = try rootfs.DirSink(root: fs.Path(args[1]))
                try plan.Emit(to: sink)
                print("wrote \(sink.Count) entries to \(args[1])" +
                      (sink.Skipped > 0 ? " (\(sink.Skipped) device nodes and fifos need root; skipped)" : ""))
            } else {
                let sink = try rootfs.CpioSink(path: fs.Path(args[1]), plan: plan)
                try plan.Emit(to: sink)
                print("wrote \(sink.Count) entries to \(args[1])")
            }
        case "fetch":
            if args.isEmpty {
                for f in fetch.Catalog.All {
                    let have = fetch.Path(f, in: st) != nil
                    print(pad(f.Name, 32) + pad(f.Version, 10) + pad(human(f.Size), 10) + (have ? "fetched" : "-"))
                }
                return 0
            }
            for name in args {
                guard let f = fetch.Catalog.Named(name) else { throw fetch.FetchError.unknown(name) }
                let p = try await fetch.Fetch(f, into: st)
                print("\(f.Reference)  \(human(f.Size))  \(p)")
            }
        case "rm":
            for name in args {
                try st.Untag(name)
                print("untagged \(name)")
            }
        case "prune":
            let freed = try st.Prune()
            print("freed \(human(freed))")
        case "help", "--help", "-h":
            usage()
        default:
            print("oci: unknown command \(cmd)")
            usage()
            return 2
        }
    } catch {
        print("oci: \(error)")
        return 1
    }
    return 0
}
