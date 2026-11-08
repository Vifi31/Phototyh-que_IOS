import Foundation

/// Ordre d'affichage.
public enum PhotoSort: String, Codable, CaseIterable, Sendable {
    case takenDesc, takenAsc, importedDesc, name, ratingDesc

    public var label: String {
        switch self {
        case .takenDesc: return "Plus récentes"
        case .takenAsc: return "Plus anciennes"
        case .importedDesc: return "Dernières importées"
        case .name: return "Nom de fichier"
        case .ratingDesc: return "Meilleures notes"
        }
    }

    var sql: String {
        switch self {
        case .takenDesc: return "IFNULL(p.taken_at, p.imported_at) DESC, p.id DESC"
        case .takenAsc: return "IFNULL(p.taken_at, p.imported_at) ASC, p.id ASC"
        case .importedDesc: return "p.imported_at DESC, p.id DESC"
        case .name: return "p.file_name COLLATE NOCASE ASC, p.id ASC"
        case .ratingDesc: return "p.rating DESC, IFNULL(p.taken_at, p.imported_at) DESC, p.id DESC"
        }
    }
}

/// Manques documentaires (même vocabulaire que le tableau de bord de bureau).
public enum MissingInfo: String, Codable, CaseIterable, Sendable {
    case keywords, title, place, date

    public var label: String {
        switch self {
        case .keywords: return "Sans mot-clé"
        case .title: return "Sans titre"
        case .place: return "Sans lieu"
        case .date: return "Sans date de prise de vue"
        }
    }
}

/// Critères de recherche (combinés par ET). Sérialisables : une recherche enregistrée est une collection dynamique.
public struct SearchCriteria: Codable, Equatable, Hashable, Sendable {
    public var text: String = ""
    public var year: Int?
    public var minRating: Int?
    public var color: Int?
    public var keywordId: Int64?
    public var includeSubKeywords: Bool = true
    public var camera: String?
    public var hasGPS: Bool?
    public var missing: MissingInfo?
    public var collectionId: Int64?
    public var sort: PhotoSort = .takenDesc

    public init(text: String = "", year: Int? = nil, minRating: Int? = nil, color: Int? = nil, keywordId: Int64? = nil,
                includeSubKeywords: Bool = true, camera: String? = nil, hasGPS: Bool? = nil, missing: MissingInfo? = nil,
                collectionId: Int64? = nil, sort: PhotoSort = .takenDesc) {
        self.text = text; self.year = year; self.minRating = minRating; self.color = color; self.keywordId = keywordId
        self.includeSubKeywords = includeSubKeywords; self.camera = camera; self.hasGPS = hasGPS; self.missing = missing
        self.collectionId = collectionId; self.sort = sort
    }

    /// Vrai si aucun filtre n'est actif (le tri ne compte pas).
    public var isEmpty: Bool {
        var c = self; c.sort = .takenDesc
        return c == SearchCriteria()
    }

    public func encoded() -> String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}"
    }

    public static func decode(_ s: String?) -> SearchCriteria? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SearchCriteria.self, from: d)
    }
}

extension Catalog {
    /// Requête FTS5 sûre : chaque mot devient un préfixe entre guillemets (jamais de syntaxe brute).
    static func ftsQuery(_ text: String) -> String? {
        let words = TextFold.tokens(text)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " AND ")
    }

    private func whereClause(_ c: SearchCriteria) -> (String, [SQLValue]) {
        var conds: [String] = []
        var params: [SQLValue] = []
        if !TextFold.tokens(c.text).isEmpty {
            if hasFullText, let q = Catalog.ftsQuery(c.text) {
                conds.append("p.id IN (SELECT rowid FROM photos_fts WHERE photos_fts MATCH ?)")
                params.append(.text(q))
            } else {
                for w in TextFold.tokens(c.text) {
                    conds.append("(' ' || p.search_text) LIKE ? ESCAPE '\\'")
                    let esc = w.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                    params.append(.text("% \(esc)%"))
                }
            }
        }
        if let y = c.year {
            conds.append("substr(IFNULL(p.taken_at, ''), 1, 4) = ?")
            params.append(.text(String(format: "%04d", y)))
        }
        if let r = c.minRating, r > 0 { conds.append("p.rating >= ?"); params.append(.of(r)) }
        if let col = c.color, col > 0 { conds.append("p.color = ?"); params.append(.of(col)) }
        if let k = c.keywordId {
            if c.includeSubKeywords {
                conds.append("""
                    p.id IN (SELECT pk.photo_id FROM photo_keywords pk WHERE pk.keyword_id IN (
                      WITH RECURSIVE sub(id) AS (SELECT ? UNION SELECT kk.id FROM keywords kk JOIN sub ON kk.parent_id = sub.id) SELECT id FROM sub))
                    """)
            } else {
                conds.append("p.id IN (SELECT photo_id FROM photo_keywords WHERE keyword_id = ?)")
            }
            params.append(.int(k))
        }
        if let cam = c.camera, !cam.isEmpty {
            conds.append("TRIM(p.camera_make || ' ' || p.camera_model) = ? OR p.camera_model = ?")
            conds[conds.count - 1] = "(" + conds[conds.count - 1] + ")"
            params.append(.text(cam)); params.append(.text(cam))
        }
        if let g = c.hasGPS {
            conds.append(g ? "p.latitude IS NOT NULL AND p.longitude IS NOT NULL" : "(p.latitude IS NULL OR p.longitude IS NULL)")
        }
        switch c.missing {
        case .keywords?: conds.append("NOT EXISTS (SELECT 1 FROM photo_keywords pk WHERE pk.photo_id = p.id)")
        case .title?: conds.append("p.title = ''")
        case .place?: conds.append("p.place = '' AND p.latitude IS NULL")
        case .date?: conds.append("p.taken_at IS NULL")
        case nil: break
        }
        if let col = c.collectionId {
            if let coll = try? collection(col), coll.kind == .smart, let sub = coll.criteria {
                var inner = sub; inner.collectionId = nil
                let (w, p) = whereClause(inner)
                conds.append("p.id IN (SELECT p.id FROM photos p WHERE \(w))")
                params.append(contentsOf: p)
            } else {
                conds.append("p.id IN (SELECT photo_id FROM collection_photos WHERE collection_id = ?)")
                params.append(.int(col))
            }
        }
        return (conds.isEmpty ? "1" : conds.joined(separator: " AND "), params)
    }

    public func search(_ c: SearchCriteria, limit: Int = 500, offset: Int = 0) throws -> [Photo] {
        let (w, params) = whereClause(c)
        var order = c.sort.sql
        if c.collectionId != nil, (try? collection(c.collectionId!))?.kind == .static, c.sort == .takenDesc {
            order = "(SELECT position FROM collection_photos cp WHERE cp.photo_id = p.id AND cp.collection_id = \(c.collectionId!)) ASC, " + order
        }
        return try db.query("SELECT p.* FROM photos p WHERE \(w) ORDER BY \(order) LIMIT ? OFFSET ?",
                            params + [.of(limit), .of(offset)]).map(Photo.init(row:))
    }

    public func count(_ c: SearchCriteria) throws -> Int {
        let (w, params) = whereClause(c)
        return try db.scalarInt("SELECT COUNT(*) AS n FROM photos p WHERE \(w)", params)
    }

    public func ids(_ c: SearchCriteria) throws -> [Int64] {
        let (w, params) = whereClause(c)
        return try db.query("SELECT p.id FROM photos p WHERE \(w) ORDER BY \(c.sort.sql)", params).compactMap { $0.int64("id") }
    }

    /// Années de prise de vue et nombre de photos.
    public func years() throws -> [(year: Int, count: Int)] {
        try db.query("SELECT substr(taken_at, 1, 4) AS y, COUNT(*) AS n FROM photos WHERE taken_at IS NOT NULL GROUP BY y ORDER BY y DESC")
            .compactMap { r in r.int("y").map { ($0, r.int("n") ?? 0) } }
    }

    public func cameras() throws -> [(name: String, count: Int)] {
        try db.query("""
            SELECT CASE WHEN camera_model LIKE camera_make || '%' THEN camera_model ELSE TRIM(camera_make || ' ' || camera_model) END AS cam,
                   COUNT(*) AS n FROM photos WHERE camera_model <> '' OR camera_make <> '' GROUP BY cam ORDER BY n DESC
            """).map { ($0.string("cam") ?? "", $0.int("n") ?? 0) }
    }
}
