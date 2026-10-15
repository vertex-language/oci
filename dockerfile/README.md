# oci/dockerfile

Reads Dockerfiles as Docker's BuildKit frontend does: parser directives (`# escape=`), comments, line continuations, stages (`FROM … AS name`), flags (`--from=`, `--chown=`), JSON and shell forms, and variable substitution (`$V`, `${V}`, `${V:-default}`, `${V:+alt}`).

```vertex
import "oci/dockerfile"
```

## Types

- **`DockerfileError`** (enum)
- **`Instruction`** (struct): One instruction, as written.
- **`Stage`** (struct): A FROM and what follows it, up to the next FROM.
- **`Dockerfile`** (struct): A parsed Dockerfile.

## Functions

- `func Parse(_ text: string) throws -> Dockerfile`: Parses `text`.
- `func SplitWords(_ s: string, escape: Character = "\\") -> [string]`: Splits as sh splits words: whitespace separates, quotes and the escape character keep things together.
- `func ArgPairs(_ rest: string) -> [(string, string?)]`: `KEY=value` pairs, as ENV, LABEL and ARG write them; ENV's and LABEL's old `KEY value` form is one pair.
- `func Expand(_ s: string, _ vars: [string: string], escape: Character = "\\") -> string`: Substitutes variables as Dockerfile instructions do: `$NAME`, `${NAME}`, `${NAME:-default}`, `${NAME:+alternative}`; `\$` is a dollar sign.

Part of the [`oci`](https://github.com/vertex-language/oci) repository.
