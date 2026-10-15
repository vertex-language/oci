# oci/store

Keeps images on disk as an OCI image layout (image-spec, image-layout.md): content-addressed blobs, and an index naming the images that are kept.

```vertex
import "oci/store"
```

## Types

- **`StoreError`** (enum)
- **`Record`** (struct): A name the store keeps, and what it names.
- **`Image`** (struct): An image read out of the store: its manifest, its config, and the digest it was found under.
- **`Store`** (class): An image layout on disk.
- **`Ingest`** (class): A blob being written a piece at a time -- a layer as it downloads -- hashed as it goes.

## Functions

- `func DefaultRoot() -> string`: Where images are kept unless a root is given: $VERTEX_OCI_ROOT, else "vertex/oci" under the user's data directory (~/Library/Application Support on macOS, ~/.local/share on Linux, %APPDATA% on Windows).

Part of the [`oci`](https://github.com/vertex-language/oci) repository.
