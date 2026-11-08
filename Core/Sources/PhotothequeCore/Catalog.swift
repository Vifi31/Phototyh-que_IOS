import Foundation

/// Catalogue de la photothèque : un dossier contenant la base et les photos importées.
///
///     <racine>/
///     ├── catalogue.sqlite     base (référence)
///     ├── Photos/AAAA/MM/      copies importées (jamais modifiées)
///     ├── Sauvegardes/         archives de sauvegarde
///     └── Exports/             fichiers exportés
///
/// Les originaux (photothèque d'iOS, app Fichiers) ne sont jamais modifiés ni supprimés :
/// l'import en fait une copie.
public final class Catalog {
    public let root: URL
    public let db: Database
    public let hasFullText: Bool

    public var photosDir: URL { root.appendingPathComponent("Photos", isDirectory: true) }
    public var backupsDir: URL { root.appendingPathComponent("Sauvegardes", isDirectory: true) }
    public var exportsDir: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    public var databaseURL: URL { root.appendingPathComponent("catalogue.sqlite") }

    /// `fullText: false` : sans index FTS5 (recherche par LIKE ; utilisé par les tests).
    public init(root: URL, fullText: Bool = true) throws {
        self.root = root
        let fm = FileManager.default
        for d in [root, root.appendingPathComponent("Photos"), root.appendingPathComponent("Sauvegardes"), root.appendingPathComponent("Exports")] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        db = try Database(path: root.appendingPathComponent("catalogue.sqlite").path)
        hasFullText = try Schema.migrate(db, fullText: fullText)
    }

    // MARK: - Journal

    public func log(_ action: String, _ detail: String = "") {
        _ = try? db.run("INSERT INTO history(at, action, detail) VALUES (?, ?, ?)", [.text(ISODate.now), .text(action), .text(detail)])
    }

    public func history(limit: Int = 200) throws -> [(at: String, action: String, detail: String)] {
        try db.query("SELECT at, action, detail FROM history ORDER BY id DESC LIMIT ?", [.of(limit)])
            .map { ($0.string("at") ?? "", $0.string("action") ?? "", $0.string("detail") ?? "") }
    }

    // MARK: - Lecture

    public func photo(_ id: Int64) throws -> Photo? {
        try db.first("SELECT * FROM photos WHERE id = ?", [.int(id)]).map(Photo.init(row:))
    }

    public func photos(ids: [Int64]) throws -> [Photo] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let found = try db.query("SELECT * FROM photos WHERE id IN (\(marks))", ids.map { .int($0) }).map(Photo.init(row:))
        let byId = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        return ids.compactMap { byId[$0] }
    }

    public func photo(sha256: String) throws -> Photo? {
        try db.first("SELECT * FROM photos WHERE sha256 = ? ORDER BY id LIMIT 1", [.text(sha256)]).map(Photo.init(row:))
    }

    public func photo(sourceId: String) throws -> Photo? {
        try db.first("SELECT * FROM photos WHERE source_id = ? ORDER BY id LIMIT 1", [.text(sourceId)]).map(Photo.init(row:))
    }

    public func fileURL(_ p: Photo) -> URL { photosDir.appendingPathComponent(p.relPath) }

    public func fileExists(_ p: Photo) -> Bool { FileManager.default.fileExists(atPath: fileURL(p).path) }

    public func stats() throws -> CatalogStats {
        let r = try db.first("""
            SELECT COUNT(*) AS n, IFNULL(SUM(size), 0) AS bytes,
                   SUM(CASE WHEN title = '' THEN 1 ELSE 0 END) AS untitled,
                   SUM(CASE WHEN latitude IS NOT NULL AND longitude IS NOT NULL THEN 1 ELSE 0 END) AS gps,
                   SUM(CASE WHEN rating > 0 THEN 1 ELSE 0 END) AS rated,
                   SUM(CASE WHEN NOT EXISTS (SELECT 1 FROM photo_keywords pk WHERE pk.photo_id = photos.id) THEN 1 ELSE 0 END) AS nokw
            FROM photos
            """)
        return CatalogStats(
            photos: r?.int("n") ?? 0,
            bytes: r?.int64("bytes") ?? 0,
            keywords: try db.scalarInt("SELECT COUNT(*) FROM keywords"),
            collections: try db.scalarInt("SELECT COUNT(*) FROM collections"),
            withoutKeywords: r?.int("nokw") ?? 0,
            withoutTitle: r?.int("untitled") ?? 0,
            withGPS: r?.int("gps") ?? 0,
            rated: r?.int("rated") ?? 0)
    }

    // MARK: - Import

    /// Importe une copie du fichier `url` dans la photothèque.
    /// - Un fichier déjà présent (même SHA-256) n'est pas copié une seconde fois : la fiche existante est renvoyée.
    /// - Le fichier source n'est jamais déplacé, modifié ni supprimé.
    @discardableResult
    public func importFile(at url: URL, metadata: PhotoMetadata, originalName: String? = nil,
                           source: String = "fichiers", sourceId: String? = nil, dhash: String? = nil) throws -> ImportOutcome {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let sha = try SHA256Hasher.file(url)
        if let existing = try photo(sha256: sha) {
            if let sid = sourceId, existing.sourceId == nil {
                try db.run("UPDATE photos SET source_id = ? WHERE id = ?", [.text(sid), .int(existing.id)])
            }
            return .duplicate(try photo(existing.id) ?? existing)
        }

        let name = TextFold.safeFileName(originalName ?? url.lastPathComponent)
        let date = metadata.takenAt ?? (attrs[.modificationDate] as? Date) ?? Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month], from: date)
        let sub = String(format: "%04d/%02d", comps.year ?? 1970, comps.month ?? 1)
        let dir = photosDir.appendingPathComponent(sub, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Catalog.uniqueURL(in: dir, name: name)
        try fm.copyItem(at: url, to: dest)
        let rel = sub + "/" + dest.lastPathComponent

        do {
            let id: Int64 = try db.transaction {
                try db.run("""
                    INSERT INTO photos (file_name, rel_path, sha256, size, width, height, format, taken_at, imported_at,
                      camera_make, camera_model, lens, latitude, longitude, title, caption, rating, source, source_id, dhash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                        .text(name), .text(rel), .text(sha), .int(size), .of(metadata.width), .of(metadata.height),
                        .text(metadata.format.isEmpty ? (name as NSString).pathExtension.uppercased() : metadata.format),
                        .of(metadata.takenAt.map(ISODate.string)), .text(ISODate.now),
                        .text(metadata.cameraMake), .text(metadata.cameraModel), .text(metadata.lens),
                        .of(metadata.latitude), .of(metadata.longitude), .text(metadata.title), .text(metadata.caption),
                        .of(max(0, min(5, metadata.rating))), .text(source), .of(sourceId), .of(dhash),
                    ])
                let id = db.lastInsertId
                for k in metadata.keywords {
                    let kid = try keywordPath(k)
                    try db.run("INSERT OR IGNORE INTO photo_keywords(photo_id, keyword_id) VALUES (?, ?)", [.int(id), .int(kid)])
                }
                try refreshSearchText([id])
                return id
            }
            log("import", name)
            return .added(try photo(id)!)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    /// Nom libre dans `dir` : « nom.jpg », puis « nom (2).jpg », « nom (3).jpg »…
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - Modification

    public func setRating(_ ids: [Int64], _ rating: Int) throws {
        try update(ids, "rating", .of(max(0, min(5, rating))))
    }

    public func setColor(_ ids: [Int64], _ color: Int) throws {
        try update(ids, "color", .of(max(0, min(5, color))))
    }

    public func setTitle(_ id: Int64, _ title: String) throws {
        try update([id], "title", .text(title.trimmingCharacters(in: .whitespacesAndNewlines)), search: true)
    }

    public func setCaption(_ id: Int64, _ caption: String) throws {
        try update([id], "caption", .text(caption.trimmingCharacters(in: .whitespacesAndNewlines)), search: true)
    }

    public func setPlace(_ ids: [Int64], _ place: String) throws {
        try update(ids, "place", .text(place.trimmingCharacters(in: .whitespacesAndNewlines)), search: true)
    }

    public func setDHash(_ id: Int64, _ dhash: String?) throws {
        try db.run("UPDATE photos SET dhash = ? WHERE id = ?", [.of(dhash), .int(id)])
    }

    private func update(_ ids: [Int64], _ column: String, _ value: SQLValue, search: Bool = false) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids { try db.run("UPDATE photos SET \(column) = ? WHERE id = ?", [value, .int(id)]) }
            if search { try refreshSearchText(ids) }
        }
    }

    /// Retire des fiches du catalogue et efface la copie gardée par Photothèque.
    /// L'original (photothèque d'iOS, Fichiers) n'est pas concerné.
    public func delete(_ ids: [Int64]) throws {
        let list = try photos(ids: ids)
        try db.transaction {
            for p in list { try db.run("DELETE FROM photos WHERE id = ?", [.int(p.id)]) }
        }
        for p in list {
            try? FileManager.default.removeItem(at: fileURL(p))
            log("suppression", p.fileName)
        }
    }

    // MARK: - Texte de recherche

    /// Recalcule le texte indexé (titre, légende, nom, appareil, lieu, mots-clés avec parents et synonymes).
    func refreshSearchText(_ ids: [Int64]) throws {
        for id in ids {
            guard let p = try photo(id) else { continue }
            var parts = [p.title, p.caption, p.fileName, p.camera, p.lens, p.place, p.format]
            for k in try keywordsOf(id) {
                parts.append(k.name)
                parts.append(contentsOf: k.synonyms)
                var parent = k.parentId
                var guardCount = 0
                while let pid = parent, guardCount < 32, let pk = try keyword(pid) {
                    parts.append(pk.name)
                    parts.append(contentsOf: pk.synonyms)
                    parent = pk.parentId
                    guardCount += 1
                }
            }
            if let y = p.takenAt?.prefix(4) { parts.append(String(y)) }
            let text = TextFold.tokens(parts.joined(separator: " ")).joined(separator: " ")
            try db.run("UPDATE photos SET search_text = ? WHERE id = ? AND search_text <> ?", [.text(text), .int(id), .text(text)])
        }
    }

    func refreshSearchText(keyword id: Int64) throws {
        let ids = try db.query("""
            WITH RECURSIVE sub(id) AS (SELECT ? UNION SELECT k.id FROM keywords k JOIN sub ON k.parent_id = sub.id)
            SELECT DISTINCT photo_id FROM photo_keywords WHERE keyword_id IN (SELECT id FROM sub)
            """, [.int(id)]).compactMap { $0.int64("photo_id") }
        try refreshSearchText(ids)
    }

    // MARK: - Réglages

    public func setting(_ key: String) -> String? {
        let row: Row? = (try? db.first("SELECT value FROM settings WHERE key = ?", [.text(key)])) ?? nil
        return row?.string("value")
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }

    /// Fiches dont le fichier a disparu du dossier Photos.
    public func missingFiles() throws -> [Photo] {
        try db.query("SELECT * FROM photos ORDER BY id").map(Photo.init(row:)).filter { !fileExists($0) }
    }
}
