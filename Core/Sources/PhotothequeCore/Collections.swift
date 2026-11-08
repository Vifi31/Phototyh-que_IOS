import Foundation

/// Collections : sélections manuelles (statiques) et recherches enregistrées (dynamiques).
extension Catalog {
    private func collection(from r: Row) throws -> PhotoCollection {
        let id = r.int64("id") ?? 0
        let kind = CollectionKind(rawValue: r.string("kind") ?? "") ?? .static
        let crit = SearchCriteria.decode(r.string("criteria"))
        var c = PhotoCollection(id: id, name: r.string("name") ?? "", kind: kind, criteria: crit,
                                createdAt: r.string("created_at") ?? "", count: 0)
        if kind == .static {
            c.count = try db.scalarInt("SELECT COUNT(*) FROM collection_photos WHERE collection_id = ?", [.int(id)])
        } else if var inner = crit {
            inner.collectionId = nil
            c.count = try count(inner)
        }
        return c
    }

    public func collection(_ id: Int64) throws -> PhotoCollection? {
        guard let r = try db.first("SELECT * FROM collections WHERE id = ?", [.int(id)]) else { return nil }
        let kind = CollectionKind(rawValue: r.string("kind") ?? "") ?? .static
        // Pas de comptage ici : appelé par la recherche elle-même.
        return PhotoCollection(id: id, name: r.string("name") ?? "", kind: kind, criteria: SearchCriteria.decode(r.string("criteria")),
                               createdAt: r.string("created_at") ?? "", count: 0)
    }

    public func collections() throws -> [PhotoCollection] {
        try db.query("SELECT * FROM collections ORDER BY name COLLATE NOCASE").map { try collection(from: $0) }
    }

    @discardableResult
    public func createCollection(_ name: String, photoIds: [Int64] = []) throws -> Int64 {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SQLiteError("Nom de collection vide") }
        return try db.transaction {
            try db.run("INSERT INTO collections(name, kind, created_at) VALUES (?, 'static', ?)", [.text(clean), .text(ISODate.now)])
            let id = db.lastInsertId
            try addToCollection(id, photoIds)
            log("collection créée", clean)
            return id
        }
    }

    /// Recherche enregistrée : ses photos sont recalculées à chaque ouverture.
    @discardableResult
    public func createSmartCollection(_ name: String, criteria: SearchCriteria) throws -> Int64 {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SQLiteError("Nom de collection vide") }
        var c = criteria; c.collectionId = nil
        try db.run("INSERT INTO collections(name, kind, criteria, created_at) VALUES (?, 'smart', ?, ?)", [.text(clean), .text(c.encoded()), .text(ISODate.now)])
        let id = db.lastInsertId
        log("recherche enregistrée", clean)
        return id
    }

    public func renameCollection(_ id: Int64, _ name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SQLiteError("Nom de collection vide") }
        try db.run("UPDATE collections SET name = ? WHERE id = ?", [.text(clean), .int(id)])
    }

    /// Supprime la collection seulement : les photos restent dans le catalogue.
    public func deleteCollection(_ id: Int64) throws {
        try db.run("DELETE FROM collections WHERE id = ?", [.int(id)])
    }

    public func addToCollection(_ id: Int64, _ photoIds: [Int64]) throws {
        guard let c = try collection(id) else { return }
        guard c.kind == .static else { throw SQLiteError("Une recherche enregistrée se met à jour seule : on n'y ajoute pas de photo.") }
        try db.transaction {
            var pos = try db.scalarInt("SELECT IFNULL(MAX(position), 0) FROM collection_photos WHERE collection_id = ?", [.int(id)])
            for p in photoIds {
                pos += 1
                try db.run("INSERT OR IGNORE INTO collection_photos(collection_id, photo_id, position) VALUES (?, ?, ?)", [.int(id), .int(p), .of(pos)])
            }
        }
    }

    public func removeFromCollection(_ id: Int64, _ photoIds: [Int64]) throws {
        try db.transaction {
            for p in photoIds { try db.run("DELETE FROM collection_photos WHERE collection_id = ? AND photo_id = ?", [.int(id), .int(p)]) }
        }
    }

    public func collectionsOf(_ photoId: Int64) throws -> [PhotoCollection] {
        try db.query("""
            SELECT c.* FROM collections c JOIN collection_photos cp ON cp.collection_id = c.id
            WHERE cp.photo_id = ? ORDER BY c.name COLLATE NOCASE
            """, [.int(photoId)]).map { try collection(from: $0) }
    }
}
