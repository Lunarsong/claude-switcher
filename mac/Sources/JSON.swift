import Foundation

// A small JSON value that keeps object key order and the exact text of numbers,
// so ~/.claude.json survives a read/modify/write with only the edited key changed.
// Output matches JavaScript's JSON.stringify(value, null, 2), which is how
// Claude Code writes that file.
indirect enum JSON: Equatable {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case number(String)      // raw literal, never re-formatted
    case bool(Bool)
    case null

    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    // MARK: access

    subscript(key: String) -> JSON? {
        get {
            if case let .object(pairs) = self { return pairs.first { $0.0 == key }?.1 }
            return nil
        }
        set {
            guard case var .object(pairs) = self else { return }
            if let i = pairs.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { pairs[i].1 = v } else { pairs.remove(at: i) }
            } else if let v = newValue {
                pairs.append((key, v))
            }
            self = .object(pairs)
        }
    }

    var string: String? { if case let .string(s) = self { return s }; return nil }
    var double: Double? {
        switch self {
        case let .number(n): return Double(n)
        case let .string(s): return Double(s)
        default: return nil
        }
    }
    var int64: Int64? {
        if case let .number(n) = self { return Int64(n) ?? Double(n).map { Int64($0) } }
        return nil
    }
    var array: [JSON]? { if case let .array(a) = self { return a }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    static func num(_ v: Int64) -> JSON { .number(String(v)) }

    // MARK: parse

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String) throws -> JSON {
        var p = Parser(Array(text.utf8))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        if p.i != p.b.count { throw ParseError(description: "Unexpected text after JSON at byte \(p.i)") }
        return v
    }

    static func parse(_ data: Data) throws -> JSON {
        guard let s = String(data: data, encoding: .utf8) else { throw ParseError(description: "Not UTF-8") }
        return try parse(s)
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) {
            // Skip a UTF-8 byte-order mark.
            self.b = b
            if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
        }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        func fail(_ m: String) -> ParseError { ParseError(description: "\(m) at byte \(i)") }

        mutating func value() throws -> JSON {
            guard i < b.count else { throw fail("Unexpected end") }
            switch b[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try arr()
            case UInt8(ascii: "\""): return .string(try str())
            case UInt8(ascii: "t"): try lit("true"); return .bool(true)
            case UInt8(ascii: "f"): try lit("false"); return .bool(false)
            case UInt8(ascii: "n"): try lit("null"); return .null
            default: return try number()
            }
        }

        mutating func lit(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw fail("Bad literal") }
            i += u.count
        }

        mutating func number() throws -> JSON {
            let start = i
            while i < b.count, "+-0123456789.eE".utf8.contains(b[i]) { i += 1 }
            guard i > start, let s = String(bytes: b[start..<i], encoding: .ascii), Double(s) != nil else { throw fail("Bad number") }
            return .number(s)
        }

        mutating func object() throws -> JSON {
            i += 1
            var pairs: [(String, JSON)] = []
            skipWS()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("Expected key") }
                let k = try str()
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("Expected :") }
                i += 1
                skipWS()
                let v = try value()
                // Duplicate keys: last one wins, like JSON.parse.
                if let j = pairs.firstIndex(where: { $0.0 == k }) { pairs[j].1 = v } else { pairs.append((k, v)) }
                skipWS()
                guard i < b.count else { throw fail("Unexpected end in object") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw fail("Expected , or }")
            }
        }

        mutating func arr() throws -> JSON {
            i += 1
            var items: [JSON] = []
            skipWS()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value())
                skipWS()
                guard i < b.count else { throw fail("Unexpected end in array") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("Expected , or ]")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count, let s = String(bytes: b[i..<i + 4], encoding: .ascii), let v = UInt32(s, radix: 16) else { throw fail("Bad \\u escape") }
            i += 4
            return v
        }

        mutating func str() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < b.count else { throw fail("Unterminated string") }
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < b.count else { throw fail("Bad escape") }
                let e = b[i]; i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var cp = try hex4()
                    if (0xD800...0xDBFF).contains(cp), i + 6 <= b.count, b[i] == 0x5C, b[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let lo = try hex4()
                        if (0xDC00...0xDFFF).contains(lo) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) } else { i = save }
                    }
                    let scalar = Unicode.Scalar(cp) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw fail("Bad escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    // MARK: serialize

    /// indent nil = compact (JSON.stringify(v)); 2 = JSON.stringify(v, null, 2).
    func serialized(indent: Int? = 2) -> String {
        var out = ""
        write(&out, indent: indent, level: 0)
        return out
    }

    private func write(_ out: inout String, indent: Int?, level: Int) {
        switch self {
        case .null: out += "null"
        case let .bool(v): out += v ? "true" : "false"
        case let .number(n): out += n
        case let .string(s): JSON.quote(s, into: &out)
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (n, v) in items.enumerated() {
                if n > 0 { out += "," }
                if let ind = indent { out += "\n" + String(repeating: " ", count: ind * (level + 1)) }
                v.write(&out, indent: indent, level: level + 1)
            }
            if let ind = indent { out += "\n" + String(repeating: " ", count: ind * level) }
            out += "]"
        case let .object(pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{"
            for (n, (k, v)) in pairs.enumerated() {
                if n > 0 { out += "," }
                if let ind = indent { out += "\n" + String(repeating: " ", count: ind * (level + 1)) }
                JSON.quote(k, into: &out)
                out += indent == nil ? ":" : ": "
                v.write(&out, indent: indent, level: level + 1)
            }
            if let ind = indent { out += "\n" + String(repeating: " ", count: ind * level) }
            out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }
}
