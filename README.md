# oci

Container images for Vertex: pull them from any OCI registry, keep them
in a standard OCI image layout, merge their layers into a filesystem
tree, and build them from Dockerfiles. Running them is
[`container`](../container)'s job: it boots an image from this store, and
`container build` builds Dockerfiles whose `RUN`s execute there.

Large files vm needs, such as the kernel it boots images with, come from
here too: they're fetched from URLs pinned to their SHA-256 and kept in the
same store, so no repository has to carry them.

```
 oci CLI / container run / container build
═══════════════════════════════════════════════════════════════════════════
 oci/build       Dockerfile → layers; RUN through an Executor (vm's)
 oci/dockerfile  parser: directives, continuations, stages, flags, $VARS
 oci/registry    distribution API: token auth, multi-arch, CDN redirects
 oci/fetch       pinned large files (kernel, initramfs, busybox) as artifacts
 oci/rootfs      layers merged, whiteouts applied → cpio (initramfs) or dir
 oci/store       OCI image layout: blobs/sha256, index.json, ingest
 oci/spec        image-spec types: index, manifest, config, descriptor
 oci/reference   docker.io/library/alpine:3.20 and friends
 oci/digest      sha256:… parse, compute, verify
```

## Packages

| Package | What it does |
| :--- | :--- |
| **`oci/digest`** | `Digest`: parse and check `sha256:<hex>`, compute one, verify bytes against one. |
| **`oci/reference`** | Image names as Docker reads them: `alpine` is `docker.io/library/alpine:latest`; registry hosts, ports, tags, digests; `ApiHost` (Docker Hub's API is `registry-1.docker.io`) and the short `Familiar` form. |
| **`oci/spec`** | The image-spec v1.1 JSON types, Docker's v2 schema 2 read too: `Descriptor`, `Manifest`, `Index` (with `Select(platform)`), `Config` (env, entrypoint, cmd, workdir, user, ports, labels, diff IDs; unknown fields kept), `Platform` (default `linux/arm64/v8`). |
| **`oci/store`** | An [OCI image layout](https://github.com/opencontainers/image-spec/blob/main/image-layout.md) at `$VERTEX_OCI_ROOT` or `vertex/oci` in the user's data directory. Blobs by digest, written through `Ingest` (hashed as they stream, checked on commit), names in `index.json` as `org.opencontainers.image.ref.name`, `Image(name)` through an index to the platform's manifest and config, `Prune()` of what no name reaches. skopeo, crane and containerd read the directory as it is. |
| **`oci/registry`** | The distribution API: manifests by tag or digest (checked), blobs streamed to the store and verified, `Push` of an image (blobs the registry has are skipped; uploads in 16 MB chunks), Bearer token auth from the `WWW-Authenticate` challenge (anonymous, or credentials from `~/.docker/config.json`), redirects to CDNs without the credentials, plain HTTP for `localhost` registries. `Pull(name, into:, platform:)`, `Push(name, from:, as:)`. |
| **`oci/rootfs`** | `Merge(layers)` reads layer headers (gzip, zstd or plain tar, PAX and GNU long names) and works out the tree: upper layers win, `.wh.<name>` deletes, `.wh..wh..opq` empties a directory of lower layers' entries, `..` is refused. `Plan.Emit` streams the layers again into a `Sink`: `CpioSink` writes a newc initramfs with owners, modes, device nodes and hard links exact; `DirSink` writes a host directory as far as the host allows. |
| **`oci/fetch`** | Large files pinned by URL and SHA-256, kept as OCI 1.1 artifacts (`vertex.local/files/<name>:<version>`). The `Catalog` has what vm boots images with: Alpine 3.20's linux-virt kernel and initramfs, its modloop, and a static busybox. |
| **`oci/dockerfile`** | BuildKit's Dockerfile syntax: `# escape=` directives, comments, continuations, `FROM … AS`, global and stage `ARG`s, `--flags`, JSON and shell forms, `ENV`/`LABEL` pairs (and the legacy forms), `$V`, `${V}`, `${V:-default}`, `${V:+alt}`. |
| **`oci/build`** | Builds a Dockerfile into the store: stages and `--target`, `FROM` a stage, an image (pulled) or `scratch`, `COPY`/`ADD` from the context (globs, `.dockerignore`, `--chown`, `--chmod`), from another stage (`--from`), local tars unpacked by `ADD`, URLs; `ENV`, `ARG`, `WORKDIR`, `USER`, `CMD`, `ENTRYPOINT`, `SHELL`, `EXPOSE`, `LABEL`, `VOLUME`, `STOPSIGNAL`, `HEALTHCHECK` (kept in the config) and `ONBUILD` (kept in the config, and run when an image with triggers is a `FROM`); history. `RUN` goes to an `Executor` that returns the tree it left as a tar; `Diff` keeps what changed, with whiteouts for what went. |

## The `oci` command

```bash
vsc build -o ./oci ./cmd/oci

./oci pull alpine:3.20                 # into the store, for linux/arm64/v8
./oci pull --platform linux/amd64 nginx
./oci images
./oci inspect python:3.12-slim
./oci unpack alpine:3.20 ./rootfs      # the merged tree, into a directory
./oci cpio alpine:3.20 rootfs.cpio     # the merged tree, as an initramfs
./oci push --as ghcr.io/me/demo:1 demo:1   # to its registry (docker login's credentials)
./oci build -t demo:1 ./ctx            # a Dockerfile without RUN (container build runs RUN)
./oci fetch                            # the pinned files, and which are here
./oci fetch alpine-vmlinuz-virt-aarch64
./oci rm demo:1
./oci prune
```

`--root <dir>` uses another store than the default.

## Running and building with container

```bash
cd ../container
./container run alpine:3.20 sh                       # a shell in Alpine, as a VM
./container run python:3.12-slim python3 -V
./container build -t myapp:1 ./myapp                 # RUN steps run in VMs
./container run myapp:1
```

## Checks

```bash
vsc run ./cmd/check     # digests, references, spec types, store, whiteouts, Dockerfiles
```

## Not yet

- `RUN --mount`, and a `HEALTHCHECK` or `VOLUME` that vm acts on: they are in the config, but `container` doesn't run healthchecks or mount volumes.
- Compressing layers with zstd when building or pushing (they are gzip; zstd is read).
- Credential helpers (`credsStore`); only `docker login`'s `auth` entries are read.
- Merging is single-threaded and inflates each layer twice (once to plan, once to emit); `compress/zstd` decodes at about 1 MB/s today.
