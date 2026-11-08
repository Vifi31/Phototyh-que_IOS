import Foundation

/// Contenu d'une sauvegarde (fichier `phototheque-ios.json` de l'archive).
/// Les photos sont reconnues par leur empreinte SHA-256, les mots-clés par leur chemin.
public struct BackupManifest: Codable, Sendable {
    public static let formatName = "phototheque-ios-sauvegarde"
    public var format: String = BackupManifest.formatName
    public var version: Int = 1
    public var appVersion: String
    public var createdAt: String
    public var includesPhotos: Bool
    public var photos: [BackupPhoto]
    public var keywords: [BackupKeyword]
    public var collections: [BackupCollection]
}

public struct BackupPhoto: Codable, Sendable {
    public var sha256: String
    public var fileName: String
    public var relPath: String
    public var size: Int64
    public var width: Int?
    public var height: Int?
    public var format: String
    public var takenAt: String?
    public var importedAt: String
    public var cameraMake: String
    public var cameraModel: String
    public var lens: String
    public var latitude: Double?
    public var longitude: Double?
    public var place: String
    public var title: String
    public var caption: String
    public var rating: Int
    public var color: Int
    public var source: String
    public var dhash: String?
    public var keywords: [[String]]
}

public struct BackupKeyword: Codable, Sendable {
    public var path: [String]
    public var synonyms: [String]
}

public struct BackupCollection: Codable, Sendable {
    public var name: String
    public var kind: CollectionKind
    public var criteria: SearchCriteria?
    public var keywordPath: [String]?
    public var photos: [String]
}

/// Bilan d'une restauration.
public struct RestoreReport: Equatable, Sendable {
    public var photosAdded = 0
    public var photosUpdated = 0
    public var photosWithoutFile = 0
    public var keywords = 0
    public var collectionsAdded = 0
    public var safetyBackup: String?
}

/// Bilan d'une vérification d'archive.
public struct ArchiveCheck: Equatable, Sendable {
    public var photos: Int
    public var files: Int
    public var keywords: Int
    public var collections: Int
    public var createdAt: String
    public var problems: [String]
    public var ok: Bool { problems.isEmpty }
}

extension Catalog {
    public static var appVersion = "0.1.0"

    private func keywordPathList(_ id: Int64) throws -> [String] {
        var names: [String] = []
        var cur: Int64? = id
        while let c = cur, names.count < 32, let k = try keyword(c) { names.insert(k.name, at: 0); cur = k.parentId }
        return names
    }

    func manifest(includePhotos: Bool) throws -> BackupManifest {
        let all = try db.query("SELECT * FROM photos ORDER BY id").map(Photo.init(row:))
        var pathCache: [Int64: [String]] = [:]
        func path(_ id: Int64) throws -> [String] {
            if let p = pathCache[id] { return p }
            let p = try keywordPathList(id); pathCache[id] = p; return p
        }
        let photos = try all.map { p -> BackupPhoto in
            BackupPhoto(sha256: p.sha256, fileName: p.fileName, relPath: p.relPath, size: p.size, width: p.width, height: p.height,
                        format: p.format, takenAt: p.takenAt, importedAt: p.importedAt, cameraMake: p.cameraMake,
                        cameraModel: p.cameraModel, lens: p.lens, latitude: p.latitude, longitude: p.longitude, place: p.place,
                        title: p.title, caption: p.caption, rating: p.rating, color: p.color, source: p.source, dhash: p.dhash,
                        keywords: try keywordsOf(p.id).map { try path($0.id) })
        }
        let kws = try keywords().map { BackupKeyword(path: try path($0.id), synonyms: $0.synonyms) }
        let colls = try collections().map { c -> BackupCollection in
            let shas = try db.query("""
                SELECT p.sha256 FROM collection_photos cp JOIN photos p ON p.id = cp.photo_id
                WHERE cp.collection_id = ? ORDER BY cp.position
                """, [.int(c.id)]).compactMap { $0.string("sha256") }
            var crit = c.criteria
            var kp: [String]?
            if let k = crit?.keywordId { kp = try path(k); crit?.keywordId = nil }
            return BackupCollection(name: c.name, kind: c.kind, criteria: crit, keywordPath: kp, photos: shas)
        }
        return BackupManifest(appVersion: Catalog.appVersion, createdAt: ISODate.now, includesPhotos: includePhotos,
                              photos: photos, keywords: kws, collections: colls)
    }

    /// Crée une archive ZIP dans `Sauvegardes/` (ou à l'emplacement donné) : catalogue + photos si demandé.
    @discardableResult
    public func backup(includePhotos: Bool, to url: URL? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "Phototheque-\(includePhotos ? "complete" : "catalogue")-\(f.string(from: Date())).zip"
        let dest = url ?? Catalog.uniqueURL(in: backupsDir, name: name)
        let m = try manifest(includePhotos: includePhotos)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".tmp")
        try? FileManager.default.removeItem(at: tmp)
        do {
            let zip = try ZipWriter(url: tmp)
            try zip.add(name: "phototheque-ios.json", data: try enc.encode(m))
            if includePhotos {
                for (i, p) in m.photos.enumerated() {
                    let src = photosDir.appendingPathComponent(p.relPath)
                    if FileManager.default.fileExists(atPath: src.path) { try zip.add(name: "Photos/" + p.relPath, file: src) }
                    progress?(i + 1, m.photos.count)
                }
            }
            try zip.finish()
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        log("sauvegarde", dest.lastPathComponent)
        return dest
    }

    public func backups() -> [(url: URL, size: Int64, date: Date)] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "zip" }.map { u in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (u, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    static func readManifest(_ zip: ZipReader) throws -> BackupManifest {
        guard let e = zip.entry("phototheque-ios.json") else { throw SQLiteError("Cette archive n'est pas une sauvegarde de Photothèque pour iOS.") }
        let m = try JSONDecoder().decode(BackupManifest.self, from: try zip.read(e))
        guard m.format == BackupManifest.formatName else { throw SQLiteError("Format de sauvegarde inconnu : \(m.format)") }
        guard m.version <= 1 else { throw SQLiteError("Sauvegarde créée par une version plus récente (format \(m.version)).") }
        return m
    }

    /// Vérifie une archive sans rien modifier : lecture du catalogue, CRC et empreinte SHA-256 de chaque photo.
    public static func verifyArchive(_ url: URL) throws -> ArchiveCheck {
        let zip = try ZipReader(url: url)
        let m = try readManifest(zip)
        var problems: [String] = []
        var files = 0
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("verif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        for p in m.photos {
            guard let e = zip.entry("Photos/" + p.relPath) else {
                if m.includesPhotos { problems.append("Fichier absent : \(p.relPath)") }
                continue
            }
            let out = tmpDir.appendingPathComponent("f")
            do {
                try zip.extract(e, to: out)
                if try SHA256Hasher.file(out) != p.sha256 { problems.append("Empreinte différente : \(p.relPath)") } else { files += 1 }
            } catch { problems.append("\(p.relPath) : \(error.localizedDescription)") }
            try? FileManager.default.removeItem(at: out)
        }
        return ArchiveCheck(photos: m.photos.count, files: files, keywords: m.keywords.count, collections: m.collections.count,
                            createdAt: m.createdAt, problems: problems)
    }

    /// Restaure une sauvegarde par fusion :
    /// - une sauvegarde de sécurité du catalogue actuel est faite d'abord ;
    /// - photos reconnues par SHA-256 : les informations de l'archive (titre, légende, note, étiquette, lieu,
    ///   mots-clés ajoutés) sont appliquées ; photos absentes : recopiées depuis l'archive si elle les contient ;
    /// - mots-clés et collections manquants : recréés. Rien n'est supprimé.
    public func restore(from url: URL, progress: ((Int, Int) -> Void)? = nil) throws -> RestoreReport {
        let zip = try ZipReader(url: url)
        let m = try Catalog.readManifest(zip)
        var report = RestoreReport()
        if try db.scalarInt("SELECT COUNT(*) FROM photos") > 0 {
            report.safetyBackup = try backup(includePhotos: false).lastPathComponent
        }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("restauration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for k in m.keywords where !k.path.isEmpty {
            let id = try keywordPath(k.path.joined(separator: "/"))
            if !k.synonyms.isEmpty, let cur = try keyword(id) {
                var syn = cur.synonyms
                for s in k.synonyms where !syn.contains(where: { TextFold.fold($0) == TextFold.fold(s) }) { syn.append(s) }
                try setSynonyms(id, syn)
            }
            report.keywords += 1
        }

        for (i, bp) in m.photos.enumerated() {
            defer { progress?(i + 1, m.photos.count) }
            var target = try photo(sha256: bp.sha256)
            if target == nil {
                guard let e = zip.entry("Photos/" + bp.relPath) else { report.photosWithoutFile += 1; continue }
                let tmp = tmpDir.appendingPathComponent(TextFold.safeFileName(bp.fileName))
                try zip.extract(e, to: tmp)
                let meta = PhotoMetadata(width: bp.width, height: bp.height, format: bp.format, takenAt: ISODate.date(bp.takenAt),
                                         cameraMake: bp.cameraMake, cameraModel: bp.cameraModel, lens: bp.lens,
                                         latitude: bp.latitude, longitude: bp.longitude)
                target = try importFile(at: tmp, metadata: meta, originalName: bp.fileName, source: bp.source, dhash: bp.dhash).photo
                try? FileManager.default.removeItem(at: tmp)
                report.photosAdded += 1
            } else {
                report.photosUpdated += 1
            }
            guard let p = target else { continue }
            try db.transaction {
                try db.run("UPDATE photos SET title = ?, caption = ?, rating = ?, color = ?, place = ?, taken_at = IFNULL(taken_at, ?), dhash = IFNULL(dhash, ?) WHERE id = ?",
                           [.text(bp.title), .text(bp.caption), .of(max(0, min(5, bp.rating))), .of(max(0, min(5, bp.color))), .text(bp.place),
                            .of(bp.takenAt), .of(bp.dhash), .int(p.id)])
                for path in bp.keywords where !path.isEmpty {
                    let kid = try keywordPath(path.joined(separator: "/"))
                    try db.run("INSERT OR IGNORE INTO photo_keywords(photo_id, keyword_id) VALUES (?, ?)", [.int(p.id), .int(kid)])
                }
                try refreshSearchText([p.id])
            }
        }

        let existing = try collections()
        for c in m.collections {
            var crit = c.criteria
            if let kp = c.keywordPath, !kp.isEmpty { crit?.keywordId = try keywordPath(kp.joined(separator: "/")) }
            if let same = existing.first(where: { $0.name == c.name && $0.kind == c.kind }) {
                if c.kind == .static { try addToCollection(same.id, try c.photos.compactMap { try photo(sha256: $0)?.id }) }
                continue
            }
            if c.kind == .smart, let crit {
                try createSmartCollection(c.name, criteria: crit)
            } else {
                try createCollection(c.name, photoIds: try c.photos.compactMap { try photo(sha256: $0)?.id })
            }
            report.collectionsAdded += 1
        }
        log("restauration", "\(url.lastPathComponent) : \(report.photosAdded) ajoutée(s), \(report.photosUpdated) mise(s) à jour")
        return report
    }

    // MARK: - Catalogue CSV

    /// Catalogue CSV (séparateur « ; », UTF-8 avec BOM pour Excel), mêmes colonnes principales que la version de bureau.
    public func catalogCSV(_ criteria: SearchCriteria = SearchCriteria()) throws -> String {
        let header = ["Fichier", "Titre", "Légende", "Date de prise de vue", "Appareil", "Objectif", "Dimensions",
                      "Note", "Étiquette", "Lieu", "Latitude", "Longitude", "Mots-clés", "SHA-256"]
        func cell(_ s: String) -> String {
            let needs = s.contains(";") || s.contains("\"") || s.contains("\n") || s.contains("\r")
            return needs ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = [header.map(cell).joined(separator: ";")]
        for p in try search(criteria, limit: Int(Int32.max)) {
            let kws = try keywordsOf(p.id).map { try keywordPathName($0.id) }.joined(separator: ", ")
            let dims = (p.width != nil && p.height != nil) ? "\(p.width!) × \(p.height!)" : ""
            let row = [p.relPath, p.title, p.caption, p.takenAt ?? "", p.camera, p.lens, dims, p.rating > 0 ? String(p.rating) : "",
                       ColorLabel(rawValue: p.color).map { $0 == .none ? "" : $0.name } ?? "", p.place,
                       p.latitude.map { String(format: "%.6f", $0) } ?? "", p.longitude.map { String(format: "%.6f", $0) } ?? "",
                       kws, p.sha256]
            lines.append(row.map(cell).joined(separator: ";"))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}
