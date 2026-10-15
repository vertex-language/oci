# oci/build

Makes images from Dockerfiles into an oci store, as `docker build` does: each stage from its FROM, COPY and ADD from the build context or another stage, the config instructions, and RUN -- which needs a Linux to run in, so an Executor does it (container/virt's boots the tree so far as a VM) and build keeps what it changed as a layer.

```vertex
import "oci/build"
```

## Types

- **`BuildError`** (enum)
- **`Executor`** (protocol): Runs a RUN instruction's command.
- **`Options`** (struct): What to build.
- **`Builder`** (class)

## Functions

- `func Glob(_ pattern: string, _ name: string) -> bool`: A shell glob within one path component: `*`, `?`, `[abc]`.
- `func Diff(parent: rootfs.Plan, tree: fs.Path) throws -> [uint8]`: A layer, as an uncompressed tar, of what `tree` -- a tar of a whole filesystem, as a RUN left it -- changes from `parent`: what is new or different, with the directories it is in, and whiteouts for what is gone.

Part of the [`oci`](https://github.com/vertex-language/oci) repository.
