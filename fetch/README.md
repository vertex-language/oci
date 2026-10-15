# oci/fetch

Brings large files into the store from a URL pinned to its SHA-256: a kernel, firmware, a disk image.

```vertex
import "oci/fetch"
```

## Types

- **`FetchError`** (enum)
- **`File`** (struct): A file pinned by URL and digest.
- **`Catalog`** (enum): Files vm needs, pinned. A name here is what `oci fetch <name>` takes.

## Functions

- `func Path(_ f: File, in st: store.Store) -> fs.Path?`: Where a fetched file is on disk, if the store has it.
- `func Fetch(_ f: File, into st: store.Store, progress: (int64, int64) -> Void =`

Part of the [`oci`](https://github.com/vertex-language/oci) repository.
