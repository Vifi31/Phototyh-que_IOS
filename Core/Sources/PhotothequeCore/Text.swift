import Foundation

/// Outils de texte : recherche insensible à la casse et aux accents (même règle
/// que la Photothèque de bureau).
public enum TextFold {
    private static let ligatures: [Character: String] = ["œ": "oe", "æ": "ae", "ß": "ss", "ø": "o", "ł": "l", "đ": "d"]

    /// Minuscules, sans accents ni ligatures.
    public static func fold(_ s: String) -> String {
        let lower = s.lowercased()
        var expanded = ""
        expanded.reserveCapacity(lower.count)
        for ch in lower { if let r = ligatures[ch] { expanded += r } else { expanded.append(ch) } }
        let decomposed = expanded.decomposedStringWithCanonicalMapping
        var out = String.UnicodeScalarView()
        for u in decomposed.unicodeScalars {
            switch u.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Mots (lettres et chiffres) d'un texte replié.
    public static func tokens(_ s: String) -> [String] {
        var words: [String] = []
        var cur = ""
        for u in fold(s).unicodeScalars {
            if u.properties.isAlphabetic || u.properties.numericType != nil {
                cur.unicodeScalars.append(u)
            } else if !cur.isEmpty {
                words.append(cur); cur = ""
            }
        }
        if !cur.isEmpty { words.append(cur) }
        return words
    }

    /// Nom de fichier sûr (sans séparateur ni caractère interdit par les systèmes de fichiers).
    public static func safeFileName(_ name: String, fallback: String = "photo") -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}").union(.controlCharacters)
        var s = String(name.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = fallback }
        if s.utf8.count > 180 {
            let ext = (s as NSString).pathExtension
            let base = String((s as NSString).deletingPathExtension.prefix(120))
            s = ext.isEmpty ? base : base + "." + ext
        }
        return s
    }
}

/// Dates au format ISO 8601 (UTC), comme dans la base de bureau.
public enum ISODate {
    public static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
    public static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
    public static var now: String { string(Date()) }
}
