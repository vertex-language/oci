// Package dockerfile reads Dockerfiles as Docker's BuildKit frontend
// does: parser directives (`# escape=`), comments, line continuations,
// stages (`FROM … AS name`), flags (`--from=`, `--chown=`), JSON and
// shell forms, and variable substitution (`$V`, `${V}`, `${V:-default}`,
// `${V:+alt}`). What the instructions do is oci/build's business.
package dockerfile

import "encoding/json"

public enum DockerfileError: Error, CustomStringConvertible {
    case syntax(line: int, message: string)
    case noFrom

    public var description: string {
        switch self {
        case .syntax(let l, let m): return "Dockerfile line \(l): \(m)"
        case .noFrom: return "Dockerfile has no FROM"
        }
    }
}

/// One instruction, as written.
public struct Instruction {
    /// Upper case: "RUN", "COPY".
    public var Command: string
    /// `--name=value` flags before the arguments.
    public var Flags: [string: string]
    /// What follows the command and flags, continuations joined.
    public var Rest: string
    /// The JSON form's array, when it was written as one.
    public var Json: [string]?
    /// The line it starts on, from 1.
    public var Line: int

    /// The arguments as words: the JSON array, or the rest split as a
    /// shell splits it (quotes kept together, not expanded).
    public var Words: [string] {
        Json ?? SplitWords(Rest)
    }
}

/// A FROM and what follows it, up to the next FROM.
public struct Stage {
    public var Index: int
    /// `AS name`, lower case; "" when unnamed.
    public var Name: string
    /// The image, unexpanded: "alpine:${VERSION}".
    public var From: string
    /// `--platform=`, unexpanded.
    public var Platform: string
    public var Instructions: [Instruction]
    public var Line: int
}

/// A parsed Dockerfile.
public struct Dockerfile {
    public var Stages: [Stage]
    /// ARGs before the first FROM: name and default (nil without one).
    public var GlobalArgs: [(string, string?)]
    public var EscapeChar: Character

    /// The stage named `name` (case-insensitive) or numbered by it.
    public func FindStage(name: string) -> Stage? {
        let n = name.lowercased()
        for s in Stages where s.Name == n {
            return s
        }
        if let i = int(name), i >= 0 && i < Stages.count {
            return Stages[i]
        }
        return nil
    }
}

/// Instructions that take a JSON array as one of their forms.
let jsonForms: Set<string> = ["RUN", "CMD", "ENTRYPOINT", "SHELL", "COPY", "ADD", "VOLUME"]
/// Instructions that take `--flag=value`s.
let flagged: Set<string> = ["FROM", "RUN", "COPY", "ADD", "HEALTHCHECK"]
let known: Set<string> = ["FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
                          "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
                          "HEALTHCHECK", "SHELL"]

func trimmed(s: string) -> string {
    var b = [uint8](s.utf8)
    while let f = b.first, f == 0x20 || f == 0x09 || f == 0x0D { b.removeFirst() }
    while let l = b.last, l == 0x20 || l == 0x09 || l == 0x0D || l == 0x0A { b.removeLast() }
    return string(decoding: b, as: UTF8.self)
}

/// Parses `text`.
public func Parse(text: string) throws -> Dockerfile {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { string($0) }
    var escape: Character = "\\"
    var i = 0
    // Parser directives: `# key=value` lines at the very top.
    while i < lines.count {
        let t = trimmed(lines[i])
        guard t.hasPrefix("#") else { break }
        let body = trimmed(string(t.dropFirst()))
        guard let eq = body.firstIndex(of: "=") else { break }
        let key = trimmed(string(body[..<eq])).lowercased()
        let value = trimmed(string(body[body.index(after: eq)...]))
        if key == "escape" {
            if value == "`" { escape = "`" } else if value != "\\" {
                throw DockerfileError.syntax(line: i + 1, message: "escape must be \\ or `")
            }
        } else if key != "syntax" && key != "check" {
            break
        }
        i += 1
    }

    // Logical lines: comments dropped, continuations joined.
    var logical: [(string, int)] = []
    var current = ""
    var startLine = 0
    var continuing = false
    while i < lines.count {
        let raw = lines[i]
        let t = trimmed(raw)
        i += 1
        if t.hasPrefix("#") || (t.isEmpty && continuing) {
            continue
        }
        if t.isEmpty { continue }
        if !continuing {
            startLine = i
            current = ""
        }
        if t.last == escape {
            current += string(t.dropLast()) + " "
            continuing = true
            continue
        }
        current += t
        continuing = false
        logical.append((current, startLine))
    }
    if continuing && !trimmed(current).isEmpty {
        logical.append((current, startLine))
    }

    var file = Dockerfile(Stages: [], GlobalArgs: [], EscapeChar: escape)
    for (line, at) in logical {
        let t = trimmed(line)
        var cmdEnd = t.startIndex
        while cmdEnd < t.endIndex && t[cmdEnd] != " " && t[cmdEnd] != "\t" {
            cmdEnd = t.index(after: cmdEnd)
        }
        let command = string(t[..<cmdEnd]).uppercased()
        if !known.contains(command) {
            throw DockerfileError.syntax(line: at, message: "unknown instruction: \(string(t[..<cmdEnd]))")
        }
        var rest = trimmed(string(t[cmdEnd...]))
        var flags: [string: string] = [:]
        if flagged.contains(command) {
            while rest.hasPrefix("--") {
                var end = rest.startIndex
                while end < rest.endIndex && rest[end] != " " && rest[end] != "\t" {
                    end = rest.index(after: end)
                }
                let flag = string(rest[rest.index(rest.startIndex, offsetBy: 2)..<end])
                if let eq = flag.firstIndex(of: "=") {
                    let k = string(flag[..<eq])
                    // RUN --mount may be given more than once.
                    let v = string(flag[flag.index(after: eq)...])
                    flags[k] = flags[k] == nil ? v : flags[k]! + "\n" + v
                } else {
                    flags[flag] = "true"
                }
                rest = trimmed(string(rest[end...]))
            }
        }
        var jsonArgs: [string]? = nil
        if jsonForms.contains(command) && rest.hasPrefix("[") {
            if let v = try? json.Parse(rest), let arr = v.Array {
                var words: [string] = []
                var ok = true
                for e in arr {
                    if let s = e.String { words.append(s) } else { ok = false }
                }
                if ok { jsonArgs = words }
            }
        }
        let ins = Instruction(Command: command, Flags: flags, Rest: rest, Json: jsonArgs, Line: at)
        if command == "FROM" {
            let words = SplitWords(rest)
            if words.isEmpty {
                throw DockerfileError.syntax(line: at, message: "FROM needs an image")
            }
            var name = ""
            if words.count >= 3 && words[1].lowercased() == "as" {
                name = words[2].lowercased()
            } else if words.count != 1 {
                throw DockerfileError.syntax(line: at, message: "FROM takes an image and perhaps AS name")
            }
            file.Stages.append(Stage(Index: file.Stages.count, Name: name, From: words[0],
                                  Platform: flags["platform"] ?? "", Instructions: [], Line: at))
            continue
        }
        if file.Stages.isEmpty {
            if command == "ARG" {
                for (k, v) in ArgPairs(rest) {
                    file.GlobalArgs.append((k, v))
                }
                continue
            }
            throw DockerfileError.syntax(line: at, message: "\(command) before the first FROM")
        }
        file.Stages[file.Stages.count - 1].Instructions.append(ins)
    }
    if file.Stages.isEmpty {
        throw DockerfileError.noFrom
    }
    return file
}

/// Splits as sh splits words: whitespace separates, quotes and the
/// escape character keep things together. Quotes are removed.
public func SplitWords(s: string, escape: Character = "\\") -> [string] {
    var out: [string] = []
    var word = ""
    var inWord = false
    var quote: Character? = nil
    var escaped = false
    for c in s {
        if escaped {
            word.append(c)
            escaped = false
            inWord = true
            continue
        }
        if let q = quote {
            if c == q {
                quote = nil
            } else if c == escape && q == "\"" {
                escaped = true
            } else {
                word.append(c)
            }
            continue
        }
        if c == escape {
            escaped = true
            inWord = true
        } else if c == "\"" || c == "'" {
            quote = c
            inWord = true
        } else if c == " " || c == "\t" {
            if inWord {
                out.append(word)
                word = ""
                inWord = false
            }
        } else {
            word.append(c)
            inWord = true
        }
    }
    if inWord { out.append(word) }
    return out
}

/// `KEY=value` pairs, as ENV, LABEL and ARG write them; ENV's and
/// LABEL's old `KEY value` form is one pair. ARG's bare `NAME` has no
/// value.
public func ArgPairs(rest: string) -> [(string, string?)] {
    let words = SplitWords(rest)
    if words.count >= 2 && !words[0].contains("=") {
        // The legacy form: the first word is the key, the rest the value.
        var value = rest
        if let sp = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            value = trimmed(string(rest[sp...]))
        }
        let unquoted = SplitWords(value)
        return [(words[0], unquoted.count == 1 ? unquoted[0] : value)]
    }
    var out: [(string, string?)] = []
    for w in words {
        if let eq = w.firstIndex(of: "=") {
            out.append((string(w[..<eq]), string(w[w.index(after: eq)...])))
        } else {
            out.append((w, nil))
        }
    }
    return out
}

/// Substitutes variables as Dockerfile instructions do: `$NAME`,
/// `${NAME}`, `${NAME:-default}`, `${NAME:+alternative}`; `\$` is a
/// dollar sign. Single-quoted text is left alone.
public func Expand(s: string, vars: [string: string], escape: Character = "\\") -> string {
    let cs = Array(s)
    var out = ""
    var i = 0
    var inSingle = false
    while i < cs.count {
        let c = cs[i]
        if c == "'" {
            inSingle = !inSingle
            out.append(c)
            i += 1
            continue
        }
        if c == escape && i + 1 < cs.count && cs[i + 1] == "$" {
            out.append("$")
            i += 2
            continue
        }
        if c != "$" || inSingle || i + 1 >= cs.count {
            out.append(c)
            i += 1
            continue
        }
        if cs[i + 1] == "{" {
            var j = i + 2
            while j < cs.count && cs[j] != "}" { j += 1 }
            if j >= cs.count {
                out.append(c)
                i += 1
                continue
            }
            let inner = string(cs[(i + 2)..<j])
            i = j + 1
            if let colon = inner.firstIndex(of: ":") {
                let name = string(inner[..<colon])
                let rest = inner[inner.index(after: colon)...]
                let op = rest.first
                let word = Expand(string(rest.dropFirst()), vars, escape: escape)
                let value = vars[name] ?? ""
                if op == "-" {
                    out += value.isEmpty ? word : value
                } else if op == "+" {
                    out += value.isEmpty ? "" : word
                } else {
                    out += value
                }
            } else {
                out += vars[inner] ?? ""
            }
            continue
        }
        var j = i + 1
        while j < cs.count && (cs[j].isLetter || cs[j].isNumber || cs[j] == "_") { j += 1 }
        if j == i + 1 {
            out.append(c)
            i += 1
            continue
        }
        out += vars[string(cs[(i + 1)..<j])] ?? ""
        i = j
    }
    return out
}
