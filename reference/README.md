# oci/reference

Parses image names the way Docker does: alpine docker.io/library/alpine:latest alpine:3.20 docker.io/library/alpine:3.20 user/app docker.io/user/app:latest ghcr.io/owner/app:v1 ghcr.io/owner/app:v1 localhost:5000/app@sha256:… a digest instead of a tag.

```vertex
import "oci/reference"
```

## Types

- **`ReferenceError`** (enum)
- **`Reference`** (struct)

Part of the [`oci`](https://github.com/vertex-language/oci) repository.
