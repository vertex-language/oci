# oci/digest

Names content by its hash, as OCI does everywhere: "sha256:" and 64 hex digits. A blob is trusted once its bytes hash to the digest it was asked for.

```vertex
import "oci/digest"
```

## Types

- **`DigestError`** (enum)
- **`Digest`** (struct): "sha256:<64 hex digits>".

Part of the [`oci`](https://github.com/vertex-language/oci) repository.
