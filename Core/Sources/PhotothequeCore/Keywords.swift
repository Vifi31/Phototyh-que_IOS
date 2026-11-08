import Foundation

/// Mots-clés hiérarchiques avec synonymes.
extension Catalog {
    public func keyword(_ id: Int64) throws -> Keyword? {
        try db.first("""
            SELECT k.*, (SELECT COUNT(*) FROM photo_keywords pk WHERE pk.keyword_id = k.id) AS photo_count
            FROM keywords k WHERE k.id = ?
            """, [.int(id)]).map(Keyword.init(row:))
    }

    public func keywords() throws -> [Keyword] {
        try db.query("""
            SELECT k.*, (SELECT COUNT(*) FROM photo_keywords pk WHERE pk.keyword_id = k.id) AS photo_count
            FROM keywords k ORDER BY k.name_key
            """).map(Keyword.init(row:))
    }

    /// Arbre complet, trié par nom à chaque niveau.
    public func keywordTree() throws -> [KeywordNode] {
        let all = try keywords()
        let byParent = Dictionary(grouping: all, by: { $0.parentId ?? 0 })
        func build(_ parent: Int64, depth: Int) -> [KeywordNode] {
            guard depth < 32 else { return [] }
            return (byParent[parent] ?? []).map { KeywordNode(keyword: $0, children: build($0.id, depth: depth + 1)) }
        }
        return build(0, depth: 0)
    }

    /// Chemin lisible « Lieux › France › Paris ».
    public func keywordPathName(_ id: Int64, separator: String = " › ") throws -> String {
        var names: [String] = []
        var cur: Int64? = id
        while let c = cur, names.count < 32, let k = try keyword(c) { names.insert(k.name, at: 0); cur = k.parentId }
        return names.joined(separator: separator)
    }

    public func keywordsOf(_ photoId: Int64) throws -> [Keyword] {
        try db.query("""
            SELECT k.*, 0 AS photo_count FROM keywords k JOIN photo_keywords pk ON pk.keyword_id = k.id
            WHERE pk.photo_id = ? ORDER BY k.name_key
            """, [.int(photoId)]).map(Keyword.init(row:))
    }

    /// Crée le mot-clé (ou renvoie celui qui existe déjà sous le même parent, sans tenir compte des accents ni de la casse).
    @discardableResult
    public func createKeyword(_ name: String, parent: Int64? = nil) throws -> Int64 {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SQLiteError("Nom de mot-clé vide") }
        let key = TextFold.fold(clean)
        if let r = try db.first("SELECT id FROM keywords WHERE IFNULL(parent_id, 0) = ? AND name_key = ?", [.int(parent ?? 0), .text(key)]),
           let id = r.int64("id") { return id }
        try db.run("INSERT INTO keywords(name, name_key, parent_id) VALUES (?, ?, ?)", [.text(clean), .text(key), .of(parent)])
        return db.lastInsertId
    }

    /// « Lieux/France/Paris » : crée chaque niveau au besoin et renvoie le dernier.
    @discardableResult
    public func keywordPath(_ path: String) throws -> Int64 {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "|" || $0 == "›" || $0 == ">" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw SQLiteError("Nom de mot-clé vide") }
        return try db.transaction {
            var parent: Int64?
            for p in parts { parent = try createKeyword(p, parent: parent) }
            return parent!
        }
    }

    public func renameKeyword(_ id: Int64, _ name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SQLiteError("Nom de mot-clé vide") }
        guard let k = try keyword(id) else { return }
        let key = TextFold.fold(clean)
        if let r = try db.first("SELECT id FROM keywords WHERE IFNULL(parent_id, 0) = ? AND name_key = ? AND id <> ?", [.int(k.parentId ?? 0), .text(key), .int(id)]), r.int64("id") != nil {
            throw SQLiteError("Le mot-clé « \(clean) » existe déjà à cet endroit.")
        }
        try db.run("UPDATE keywords SET name = ?, name_key = ? WHERE id = ?", [.text(clean), .text(key), .int(id)])
        try refreshSearchText(keyword: id)
    }

    /// Déplace un mot-clé sous un autre parent (refuse de le ranger sous l'un de ses descendants).
    public func moveKeyword(_ id: Int64, parent: Int64?) throws {
        if let p = parent {
            var cur: Int64? = p
            var depth = 0
            while let c = cur, depth < 64 {
                if c == id { throw SQLiteError("Un mot-clé ne peut pas être rangé sous lui-même ou sous l'un de ses sous-mots-clés.") }
                cur = try keyword(c)?.parentId
                depth += 1
            }
        }
        guard let k = try keyword(id) else { return }
        if let r = try db.first("SELECT id FROM keywords WHERE IFNULL(parent_id, 0) = ? AND name_key = ? AND id <> ?", [.int(parent ?? 0), .text(TextFold.fold(k.name)), .int(id)]), r.int64("id") != nil {
            throw SQLiteError("Le mot-clé « \(k.name) » existe déjà à cet endroit.")
        }
        try db.run("UPDATE keywords SET parent_id = ? WHERE id = ?", [.of(parent), .int(id)])
        try refreshSearchText(keyword: id)
    }

    public func setSynonyms(_ id: Int64, _ synonyms: [String]) throws {
        let clean = synonyms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try db.run("UPDATE keywords SET synonyms = ? WHERE id = ?", [.text(clean.joined(separator: "; ")), .int(id)])
        try refreshSearchText(keyword: id)
    }

    /// Supprime le mot-clé ; ses sous-mots-clés remontent d'un niveau. Les photos ne sont pas touchées.
    public func deleteKeyword(_ id: Int64) throws {
        guard let k = try keyword(id) else { return }
        let photoIds = try db.query("""
            WITH RECURSIVE sub(id) AS (SELECT ? UNION SELECT kk.id FROM keywords kk JOIN sub ON kk.parent_id = sub.id)
            SELECT DISTINCT photo_id FROM photo_keywords WHERE keyword_id IN (SELECT id FROM sub)
            """, [.int(id)]).compactMap { $0.int64("photo_id") }
        try db.transaction {
            // Libère le nom pendant le déplacement (un enfant peut porter le même nom que son parent).
            try db.run("UPDATE keywords SET name_key = name_key || char(1) || id WHERE id = ?", [.int(id)])
            for child in try db.query("SELECT id, name_key FROM keywords WHERE parent_id = ?", [.int(id)]) {
                guard let cid = child.int64("id") else { continue }
                // Un homonyme au niveau supérieur : fusion (les photos passent sur celui-ci).
                if let twin = try db.first("SELECT id FROM keywords WHERE IFNULL(parent_id, 0) = ? AND name_key = ? AND id <> ?",
                                           [.int(k.parentId ?? 0), .text(child.string("name_key") ?? ""), .int(cid)])?.int64("id") {
                    try mergeKeyword(cid, into: twin)
                } else {
                    try db.run("UPDATE keywords SET parent_id = ? WHERE id = ?", [.of(k.parentId), .int(cid)])
                }
            }
            try db.run("DELETE FROM keywords WHERE id = ?", [.int(id)])
            try refreshSearchText(photoIds)
        }
        log("mot-clé supprimé", k.name)
    }

    /// Fusionne `source` dans `target` (affectations, synonymes, sous-mots-clés), puis supprime `source`.
    public func mergeKeyword(_ source: Int64, into target: Int64) throws {
        guard source != target, let s = try keyword(source), let t = try keyword(target) else { return }
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO photo_keywords(photo_id, keyword_id) SELECT photo_id, ? FROM photo_keywords WHERE keyword_id = ?", [.int(target), .int(source)])
            var syn = t.synonyms
            for x in s.synonyms + [s.name] where TextFold.fold(x) != TextFold.fold(t.name) && !syn.contains(where: { TextFold.fold($0) == TextFold.fold(x) }) { syn.append(x) }
            try db.run("UPDATE keywords SET synonyms = ? WHERE id = ?", [.text(syn.joined(separator: "; ")), .int(target)])
            for child in try db.query("SELECT id FROM keywords WHERE parent_id = ?", [.int(source)]) {
                if let cid = child.int64("id") { try moveKeywordForce(cid, parent: target) }
            }
            try db.run("DELETE FROM keywords WHERE id = ?", [.int(source)])
            try refreshSearchText(keyword: target)
        }
    }

    private func moveKeywordForce(_ id: Int64, parent: Int64) throws {
        guard let k = try keyword(id) else { return }
        if let twin = try db.first("SELECT id FROM keywords WHERE IFNULL(parent_id, 0) = ? AND name_key = ? AND id <> ?", [.int(parent), .text(TextFold.fold(k.name)), .int(id)])?.int64("id") {
            try mergeKeyword(id, into: twin)
        } else {
            try db.run("UPDATE keywords SET parent_id = ? WHERE id = ?", [.int(parent), .int(id)])
        }
    }

    public func assignKeyword(_ keywordId: Int64, to photoIds: [Int64]) throws {
        try db.transaction {
            for p in photoIds { try db.run("INSERT OR IGNORE INTO photo_keywords(photo_id, keyword_id) VALUES (?, ?)", [.int(p), .int(keywordId)]) }
            try refreshSearchText(photoIds)
        }
    }

    public func removeKeyword(_ keywordId: Int64, from photoIds: [Int64]) throws {
        try db.transaction {
            for p in photoIds { try db.run("DELETE FROM photo_keywords WHERE photo_id = ? AND keyword_id = ?", [.int(p), .int(keywordId)]) }
            try refreshSearchText(photoIds)
        }
    }

    /// Mots-clés dont le nom (ou un synonyme) commence par la saisie — pour l'autocomplétion.
    public func suggestKeywords(_ prefix: String, limit: Int = 12) throws -> [Keyword] {
        let p = TextFold.fold(prefix.trimmingCharacters(in: .whitespaces))
        guard !p.isEmpty else { return [] }
        return try keywords().filter { k in
            TextFold.fold(k.name).hasPrefix(p) || k.synonyms.contains { TextFold.fold($0).hasPrefix(p) }
        }.prefix(limit).map { $0 }
    }

    /// Groupes de mots-clés qui ne diffèrent que par la casse, les accents ou la ponctuation (doublons de vocabulaire).
    public func keywordLookalikes() throws -> [[Keyword]] {
        let all = try keywords()
        let groups = Dictionary(grouping: all, by: { TextFold.tokens($0.name).joined(separator: " ") })
        return groups.values.filter { $0.count > 1 }.map { $0.sorted { $0.id < $1.id } }.sorted { $0[0].name < $1[0].name }
    }
}
