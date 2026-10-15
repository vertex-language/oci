# oci/registry

Pulls images from a registry that speaks the OCI distribution API (Docker Hub, ghcr.io, quay.io, a local registry:2).

```vertex
import "oci/registry"
```

## Types

- **`RegistryError`** (enum)
- **`Credentials`** (struct): A user name and password (or token) for a registry.
- **`Progress`** (struct): What a fetch is doing, for a progress display.
- **`Fetched`** (struct): A manifest or index as the registry sent it.
- **`Client`** (class): One registry, reached at its API host.

## Functions

- `func Pull(_ name: string, into st: store.Store, platform: spec.Platform = spec.Platform.Default, progress: (Progress) -> Void =`
- `func parseChallenge(_ header: string) -> (string, [string: string])`: "Bearer realm="…",service="…"" as its scheme and parameters.

Part of the [`oci`](https://github.com/vertex-language/oci) repository.
