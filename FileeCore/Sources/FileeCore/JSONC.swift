import Foundation

/// JSON with comments and trailing commas, as VS Code writes it.
public enum JSONC {
    /// Removes `//` and `/* */` comments and trailing commas, leaving strings untouched.
    public static func strip(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count {
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "," {
                var j = i + 1
                while j < chars.count, CharacterSet.whitespacesAndNewlines.contains(chars[j]) { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    i += 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    public static func object(from data: Data) throws -> Any {
        let text = String(decoding: data, as: UTF8.self)
        let clean = strip(text)
        return try JSONSerialization.jsonObject(with: Data(clean.utf8), options: [.fragmentsAllowed])
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let clean = strip(String(decoding: data, as: UTF8.self))
        return try JSONDecoder().decode(type, from: Data(clean.utf8))
    }
}
