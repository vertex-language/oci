# oci/rootfs

Makes an image's layers into one filesystem tree. Layers are tars applied bottom first; a layer removes what is below it with whiteouts (`.wh.<name>` deletes <name>, `.wh..wh..opq` empties its directory of what lower layers put there).

```vertex
import "oci/rootfs"
```

## Types

- **`RootfsError`** (enum)
- **`Kind`** (enum)
- **`Entry`** (struct): One path of the merged tree.
- **`Sink`** (protocol): What receives the merged tree.
- **`LayerStream`** (struct): A layer as a stream of tar bytes, decompressed if it is gzipped or zstd-compressed (by media type, or by magic number).
- **`Layer`** (struct): A layer's blob and type.
- **`Plan`** (class): The tree a stack of layers makes.
- **`CpioSink`** (class): Writes the tree as a newc cpio archive -- a Linux initramfs -- with every owner, mode, device node and hard link as the image has them.
- **`DirSink`** (class): Writes the tree into a directory on this machine, as far as it can: owners are not set and device nodes are skipped (they need root), and on a case-insensitive filesystem the later of two names that differ only by case wins.

## Functions

- `func Layers(of img: store.Image, in st: store.Store) throws -> [Layer]`: The layers of an image in a store, bottom first.
- `func Clean(_ name: string) throws -> string`: A path from a tar as a path in the tree: no "./", no leading or trailing "/", and nothing that climbs out.
- `func Merge(_ layers: [Layer]) throws -> Plan`: Reads the layers' headers and works out the tree they make.
- `func Merge(_ img: store.Image, in st: store.Store) throws -> Plan`: Merge for an image in a store.

Part of the [`oci`](https://github.com/vertex-language/oci) repository.
