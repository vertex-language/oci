# oci/spec

The OCI image format (image-spec v1.1): descriptors, manifests, indexes and image configs, read from and written to JSON.

```vertex
import "oci/spec"
```

## Types

- **`MediaType`** (enum)
- **`ImageError`** (enum)
- **`Platform`** (struct): An OS and CPU an image is for.
- **`Descriptor`** (struct): A pointer to content: its type, digest and size.
- **`Manifest`** (struct): An image for one platform: its config and its layers, bottom first.
- **`Index`** (struct): Manifests for several platforms (a "manifest list" in Docker's words), or, in an image layout, the images a store holds.
- **`Config`** (struct): How to run an image, and the layers' uncompressed digests. Fields this package doesn't model (history, healthcheck, …) are kept as they were.

Part of the [`oci`](https://github.com/vertex-language/oci) repository.
