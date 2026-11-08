import Foundation
import XCTest
@testable import PhotothequeCore

final class HashingTests: XCTestCase {
    func testSHA256Vectors() {
        XCTAssertEqual(SHA256Hasher.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hasher.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        XCTAssertEqual(SHA256Hasher.hex(long), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Implémentation Swift pure, quelle que soit la plateforme, y compris par morceaux.
        var p = PureSHA256()
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        p.update(million.prefix(333_333)); p.update(million.dropFirst(333_333))
        XCTAssertEqual(p.finalize(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.of(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(CRC32.of(Data()), 0)
    }

    func testDHash() {
        let px = (0..<72).map { UInt8($0 % 9 * 20) }        // dégradé croissant : aucun bit
        XCTAssertEqual(DHash.compute(gray9x8: px), "0000000000000000")
        let rev = (0..<72).map { UInt8(200 - $0 % 9 * 20) } // décroissant : tous les bits
        XCTAssertEqual(DHash.compute(gray9x8: rev), "ffffffffffffffff")
        XCTAssertEqual(DHash.distance("0000000000000000", "00000000000000ff"), 8)
        XCTAssertNil(DHash.compute(gray9x8: [1, 2, 3]))
    }
}

final class TextTests: XCTestCase {
    func testFold() {
        XCTAssertEqual(TextFold.fold("Été à Noël"), "ete a noel")
        XCTAssertEqual(TextFold.fold("Œuvre ÇA"), "oeuvre ca")
        XCTAssertEqual(TextFold.tokens("Château-d'Œx, 2024 !"), ["chateau", "d", "oex", "2024"])
    }

    func testSafeFileName() {
        XCTAssertEqual(TextFold.safeFileName("a/b:c?.jpg"), "a_b_c_.jpg")
        XCTAssertEqual(TextFold.safeFileName("  .cache "), "cache")
        XCTAssertEqual(TextFold.safeFileName(""), "photo")
    }

    func testISODate() {
        let d = ISODate.date("2024-07-14T10:30:00Z")
        XCTAssertNotNil(d)
        XCTAssertEqual(ISODate.string(d!), "2024-07-14T10:30:00Z")
    }
}

/// Dossier temporaire + fichiers factices.
class CatalogTestCase: XCTestCase {
    var dir: URL!
    var cat: Catalog!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("phototheque-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cat = try Catalog(root: dir.appendingPathComponent("lib"))
    }

    override func tearDownWithError() throws {
        cat = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func makeFile(_ name: String, _ content: String) throws -> URL {
        let src = dir.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let u = src.appendingPathComponent(name)
        try Data(content.utf8).write(to: u)
        return u
    }

    @discardableResult
    func add(_ name: String, _ content: String, _ meta: PhotoMetadata = PhotoMetadata(), on c: Catalog? = nil) throws -> Photo {
        try (c ?? cat).importFile(at: try makeFile(name, content), metadata: meta).photo
    }

    func date(_ s: String) -> Date { ISODate.date(s)! }
}

final class CatalogTests: CatalogTestCase {
    func testSchemaAndIntegrity() throws {
        XCTAssertEqual(try cat.db.scalarInt("PRAGMA user_version"), Schema.version)
        XCTAssertEqual(try Schema.integrity(cat.db), [])
        XCTAssertTrue(cat.hasFullText, "SQLite \(Database.libraryVersion) sans FTS5")
        // Réouverture : pas de nouvelle migration.
        let again = try Catalog(root: cat.root)
        XCTAssertEqual(try again.db.scalarInt("PRAGMA user_version"), Schema.version)
    }

    func testImportCopiesWithoutTouchingSource() throws {
        let src = try makeFile("IMG_0001.JPG", "image-1")
        let before = try Data(contentsOf: src)
        let meta = PhotoMetadata(width: 4000, height: 3000, format: "JPEG", takenAt: date("2023-08-15T09:00:00Z"),
                                 cameraMake: "Apple", cameraModel: "iPhone 15", lens: "26 mm", latitude: 48.85, longitude: 2.35,
                                 title: "Tour", caption: "Vue de Paris", keywords: ["Lieux/France/Paris", "Monument"], rating: 4)
        let r = try cat.importFile(at: src, metadata: meta, source: "photos", sourceId: "ASSET-1")
        guard case .added(let p) = r else { return XCTFail("photo non ajoutée") }
        XCTAssertEqual(p.relPath, "2023/08/IMG_0001.JPG")
        XCTAssertEqual(p.rating, 4)
        XCTAssertEqual(p.camera, "Apple iPhone 15")
        XCTAssertEqual(p.sha256, SHA256Hasher.hex(Data("image-1".utf8)))
        XCTAssertTrue(cat.fileExists(p))
        XCTAssertEqual(try Data(contentsOf: src), before, "source modifiée")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "source déplacée")
        XCTAssertEqual(try cat.keywordsOf(p.id).map(\.name).sorted(), ["Monument", "Paris"])
        XCTAssertEqual(try cat.keywordPathName(try cat.keywordPath("Lieux/France/Paris")), "Lieux › France › Paris")
        XCTAssertEqual(try cat.photo(sourceId: "ASSET-1")?.id, p.id)
    }

    func testDuplicateAndUniqueNames() throws {
        let a = try add("a.jpg", "same", PhotoMetadata(takenAt: date("2024-01-02T00:00:00Z")))
        let dup = try cat.importFile(at: try makeFile("copie.jpg", "same"), metadata: PhotoMetadata(), sourceId: "X")
        XCTAssertTrue(dup.isDuplicate)
        XCTAssertEqual(dup.photo.id, a.id)
        XCTAssertEqual(dup.photo.sourceId, "X")
        XCTAssertEqual(try cat.stats().photos, 1)
        // Même nom, contenu différent : nom unique, rien n'est écrasé.
        let b = try add("a.jpg", "other", PhotoMetadata(takenAt: date("2024-01-20T00:00:00Z")))
        let c = try add("a.jpg", "third", PhotoMetadata(takenAt: date("2024-01-21T00:00:00Z")))
        XCTAssertEqual(b.relPath, "2024/01/a (2).jpg")
        XCTAssertEqual(c.relPath, "2024/01/a (3).jpg")
        XCTAssertEqual(try Data(contentsOf: cat.fileURL(a)), Data("same".utf8))
    }

    func testEditsAndDelete() throws {
        let p = try add("x.jpg", "x")
        try cat.setRating([p.id], 9)
        try cat.setColor([p.id], 2)
        try cat.setTitle(p.id, "  Coucher de soleil ")
        try cat.setCaption(p.id, "Plage de l'Écluse")
        try cat.setPlace([p.id], "Dinard")
        let q = try cat.photo(p.id)!
        XCTAssertEqual(q.rating, 5)
        XCTAssertEqual(q.color, 2)
        XCTAssertEqual(q.title, "Coucher de soleil")
        XCTAssertEqual(try cat.search(SearchCriteria(text: "ecluse")).map(\.id), [p.id])
        XCTAssertEqual(try cat.search(SearchCriteria(text: "dinard soleil")).map(\.id), [p.id])
        let src = dir.appendingPathComponent("source/x.jpg")
        try cat.delete([p.id])
        XCTAssertNil(try cat.photo(p.id))
        XCTAssertFalse(cat.fileExists(p))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "l'original ne doit pas être supprimé")
        XCTAssertEqual(try cat.history().first?.action, "suppression")
    }

    func testSettingsAndMissingFiles() throws {
        try cat.setSetting("grille", "L")
        XCTAssertEqual(cat.setting("grille"), "L")
        try cat.setSetting("grille", nil)
        XCTAssertNil(cat.setting("grille"))
        let p = try add("m.jpg", "m")
        try FileManager.default.removeItem(at: cat.fileURL(p))
        XCTAssertEqual(try cat.missingFiles().map(\.id), [p.id])
    }
}

final class KeywordTests: CatalogTestCase {
    func testTreeRenameMoveSynonyms() throws {
        let lieux = try cat.createKeyword("Lieux")
        let france = try cat.createKeyword("France", parent: lieux)
        let paris = try cat.createKeyword("Paris", parent: france)
        XCTAssertEqual(try cat.createKeyword("  paris ", parent: france), paris, "doublon insensible à la casse")
        XCTAssertEqual(try cat.createKeyword("PÂRIS", parent: france), paris, "doublon insensible aux accents")
        XCTAssertNotEqual(try cat.createKeyword("Paris"), paris, "même nom à un autre niveau : autorisé")
        let tree = try cat.keywordTree()
        XCTAssertEqual(tree.map(\.keyword.name), ["Lieux", "Paris"])
        XCTAssertEqual(tree[0].children[0].children[0].keyword.name, "Paris")
        XCTAssertNil(tree[1].childrenOrNil)

        let p = try add("p.jpg", "p")
        try cat.assignKeyword(paris, to: [p.id])
        // Recherche par parent et par synonyme.
        XCTAssertEqual(try cat.search(SearchCriteria(text: "france")).count, 1)
        try cat.setSynonyms(france, ["Hexagone", " ", "FR"])
        XCTAssertEqual(try cat.keyword(france)?.synonyms, ["Hexagone", "FR"])
        XCTAssertEqual(try cat.search(SearchCriteria(text: "hexagone")).count, 1)
        // Critère mot-clé : sous-mots-clés inclus ou non.
        XCTAssertEqual(try cat.count(SearchCriteria(keywordId: lieux)), 1)
        XCTAssertEqual(try cat.count(SearchCriteria(keywordId: lieux, includeSubKeywords: false)), 0)

        try cat.renameKeyword(france, "République française")
        XCTAssertEqual(try cat.search(SearchCriteria(text: "republique")).count, 1)
        XCTAssertThrowsError(try cat.moveKeyword(lieux, parent: paris), "cycle refusé")
        XCTAssertThrowsError(try cat.renameKeyword(paris, ""))
        XCTAssertEqual(try cat.suggestKeywords("hex").map(\.id), [france])
    }

    func testDeleteMovesChildrenUpAndKeepsPhotos() throws {
        let animaux = try cat.createKeyword("Animaux")
        let chat = try cat.createKeyword("Chat", parent: animaux)
        let p = try add("c.jpg", "c")
        try cat.assignKeyword(chat, to: [p.id])
        try cat.assignKeyword(animaux, to: [p.id])
        try cat.deleteKeyword(animaux)
        XCTAssertNil(try cat.keyword(animaux))
        XCTAssertNil(try cat.keyword(chat)?.parentId, "l'enfant remonte d'un niveau")
        XCTAssertNotNil(try cat.photo(p.id))
        XCTAssertEqual(try cat.keywordsOf(p.id).map(\.name), ["Chat"])
        XCTAssertEqual(try cat.search(SearchCriteria(text: "animaux")).count, 0, "texte de recherche recalculé")
    }

    func testDeleteParentWithSameNamedChild() throws {
        let a = try cat.createKeyword("Nature")
        let child = try cat.createKeyword("Nature", parent: a)
        let p = try add("n.jpg", "n")
        try cat.assignKeyword(child, to: [p.id])
        try cat.deleteKeyword(a)
        XCTAssertEqual(try cat.keywords().map(\.name), ["Nature"])
        XCTAssertEqual(try cat.keywordsOf(p.id).count, 1)
    }

    func testMergeAndLookalikes() throws {
        let a = try cat.createKeyword("Vélo")
        let b = try cat.createKeyword("velo")
        XCTAssertEqual(a, b)
        let c = try cat.createKeyword("Bicyclette")
        let d = try cat.createKeyword("Mer")
        let e = try cat.createKeyword("mer.")
        XCTAssertEqual(try cat.keywordLookalikes().map { $0.map(\.id) }, [[d, e]])
        let p = try add("v.jpg", "v")
        try cat.assignKeyword(c, to: [p.id])
        try cat.mergeKeyword(c, into: a)
        XCTAssertNil(try cat.keyword(c))
        XCTAssertEqual(try cat.keyword(a)?.synonyms, ["Bicyclette"])
        XCTAssertEqual(try cat.keywordsOf(p.id).map(\.id), [a])
        XCTAssertEqual(try cat.search(SearchCriteria(text: "bicyclette")).count, 1)
        try cat.removeKeyword(a, from: [p.id])
        XCTAssertEqual(try cat.keywordsOf(p.id).count, 0)
    }
}

final class SearchTests: CatalogTestCase {
    func fill() throws -> [Photo] {
        [
            try add("1.jpg", "1", PhotoMetadata(takenAt: date("2021-05-01T10:00:00Z"), cameraMake: "Canon", cameraModel: "Canon EOS R6", latitude: 1, longitude: 2, title: "Fête de la musique", rating: 5)),
            try add("2.jpg", "2", PhotoMetadata(takenAt: date("2022-06-01T10:00:00Z"), cameraMake: "Apple", cameraModel: "iPhone 13", caption: "Pique-nique", rating: 2)),
            try add("3.jpg", "3", PhotoMetadata(cameraMake: "Apple", cameraModel: "iPhone 13", keywords: ["Famille"])),
        ]
    }

    func testCriteria() throws {
        let p = try fill()
        try cat.setColor([p[1].id], ColorLabel.green.rawValue)
        XCTAssertEqual(try cat.count(SearchCriteria()), 3)
        XCTAssertEqual(try cat.search(SearchCriteria(text: "FETE")).map(\.id), [p[0].id])
        XCTAssertEqual(try cat.search(SearchCriteria(text: "piq")).map(\.id), [p[1].id], "préfixe")
        XCTAssertEqual(try cat.search(SearchCriteria(text: "\"; DROP TABLE photos; --")).count, 0, "saisie neutralisée")
        XCTAssertEqual(try cat.search(SearchCriteria(text: "2021")).map(\.id), [p[0].id], "année dans le texte")
        XCTAssertEqual(try cat.search(SearchCriteria(year: 2022)).map(\.id), [p[1].id])
        XCTAssertEqual(try cat.count(SearchCriteria(minRating: 2)), 2)
        XCTAssertEqual(try cat.search(SearchCriteria(color: 3)).map(\.id), [p[1].id])
        XCTAssertEqual(try cat.count(SearchCriteria(camera: "Apple iPhone 13")), 2)
        XCTAssertEqual(try cat.count(SearchCriteria(camera: "Canon EOS R6")), 1)
        XCTAssertEqual(try cat.count(SearchCriteria(hasGPS: true)), 1)
        XCTAssertEqual(try cat.count(SearchCriteria(missing: .keywords)), 2)
        XCTAssertEqual(try cat.count(SearchCriteria(missing: .title)), 2)
        XCTAssertEqual(try cat.count(SearchCriteria(missing: .date)), 1)
        XCTAssertEqual(try cat.years().map(\.year), [2022, 2021])
        XCTAssertEqual(try cat.cameras().first?.name, "Apple iPhone 13")
        XCTAssertEqual(try cat.search(SearchCriteria(sort: .ratingDesc)).first?.id, p[0].id)
        XCTAssertEqual(try cat.search(SearchCriteria(sort: .takenAsc)).first?.id, p[0].id)
        XCTAssertEqual(try cat.search(SearchCriteria(sort: .name)).map(\.fileName), ["1.jpg", "2.jpg", "3.jpg"])
        XCTAssertEqual(try cat.search(SearchCriteria(), limit: 1, offset: 1).count, 1)
        XCTAssertTrue(SearchCriteria(sort: .name).isEmpty)
        XCTAssertFalse(SearchCriteria(minRating: 1).isEmpty)
    }

    func testLikeFallbackWithoutFTS() throws {
        let plain = try Catalog(root: dir.appendingPathComponent("sans-fts"), fullText: false)
        XCTAssertFalse(plain.hasFullText)
        let p = try add("e.jpg", "e", PhotoMetadata(title: "Été 100% soleil_plage"), on: plain)
        XCTAssertEqual(try plain.search(SearchCriteria(text: "ete")).map(\.id), [p.id])
        XCTAssertEqual(try plain.search(SearchCriteria(text: "sol")).map(\.id), [p.id])
        XCTAssertEqual(try plain.search(SearchCriteria(text: "olei")).count, 0, "début de mot seulement, comme FTS5")
        XCTAssertEqual(try plain.search(SearchCriteria(text: "100%")).map(\.id), [p.id])
    }

    func testCriteriaCoding() {
        let c = SearchCriteria(text: "mer", minRating: 3, missing: .place, sort: .name)
        XCTAssertEqual(SearchCriteria.decode(c.encoded()), c)
        XCTAssertNil(SearchCriteria.decode("pas du json"))
    }
}

final class CollectionTests: CatalogTestCase {
    func testStaticAndSmart() throws {
        let a = try add("a.jpg", "a", PhotoMetadata(rating: 5))
        let b = try add("b.jpg", "b", PhotoMetadata(rating: 1))
        let s = try cat.createCollection("Sélection", photoIds: [b.id, a.id, b.id])
        XCTAssertEqual(try cat.search(SearchCriteria(collectionId: s)).map(\.id), [b.id, a.id], "ordre de la sélection")
        let smart = try cat.createSmartCollection("Meilleures", criteria: SearchCriteria(minRating: 4))
        XCTAssertEqual(try cat.search(SearchCriteria(collectionId: smart)).map(\.id), [a.id])
        XCTAssertThrowsError(try cat.addToCollection(smart, [b.id]))
        let c = try add("c.jpg", "c", PhotoMetadata(rating: 4))
        XCTAssertEqual(try cat.count(SearchCriteria(collectionId: smart)), 2, "recalculée")
        XCTAssertEqual(try cat.collections().map(\.count), [2, 2])
        try cat.removeFromCollection(s, [b.id])
        XCTAssertEqual(try cat.collectionsOf(a.id).map(\.name), ["Sélection"])
        try cat.renameCollection(s, "Choix")
        try cat.deleteCollection(s)
        XCTAssertNotNil(try cat.photo(a.id), "les photos restent")
        XCTAssertEqual(try cat.collections().map(\.name), ["Meilleures"])
        _ = c
    }
}

final class DuplicateTests: CatalogTestCase {
    func testSimilarGroups() throws {
        let a = try add("a.jpg", "a"); try cat.setDHash(a.id, "f0f0f0f0f0f0f0f0")
        let b = try add("b.jpg", "b"); try cat.setDHash(b.id, "f0f0f0f0f0f0f0f1")
        let c = try add("c.jpg", "c"); try cat.setDHash(c.id, "f0f0f0f0f0f0f0f3")
        let d = try add("d.jpg", "d"); try cat.setDHash(d.id, "0f0f0f0f0f0f0f0f")
        let e = try add("e.jpg", "e")
        let g = try cat.similarGroups(threshold: 1)
        XCTAssertEqual(g.map { $0.photos.map(\.id) }, [[a.id, b.id, c.id]], "chaîne a–b–c")
        XCTAssertEqual(g.first?.maxDistance, 1)
        XCTAssertEqual(try cat.similarGroups(threshold: 0).count, 0)
        XCTAssertEqual(try cat.photosWithoutDHash().map(\.id), [e.id])
        _ = d
    }
}

final class BackupTests: CatalogTestCase {
    func testZipRoundTrip() throws {
        let url = dir.appendingPathComponent("t.zip")
        let z = try ZipWriter(url: url)
        try z.add(name: "a.txt", data: Data("bonjour".utf8))
        try z.add(name: "dossier/é.bin", file: try makeFile("big", String(repeating: "x", count: 3_000_000)))
        XCTAssertThrowsError(try z.add(name: "a.txt", data: Data()))
        try z.finish()
        let r = try ZipReader(url: url)
        XCTAssertEqual(r.entries.map(\.name), ["a.txt", "dossier/é.bin"])
        XCTAssertEqual(String(decoding: try r.read(r.entry("a.txt")!), as: UTF8.self), "bonjour")
        let out = dir.appendingPathComponent("out.bin")
        try r.extract(r.entry("dossier/é.bin")!, to: out)
        XCTAssertEqual(try Data(contentsOf: out).count, 3_000_000)
        XCTAssertThrowsError(try ZipReader(url: try makeFile("pas-zip.zip", "nope")))
    }

    func populate() throws -> (Photo, Photo) {
        let a = try add("a.jpg", "AAAA", PhotoMetadata(takenAt: date("2020-02-02T00:00:00Z"), title: "Alpha", keywords: ["Lieux/Bretagne"], rating: 3))
        let b = try add("b.jpg", "BBBB", PhotoMetadata(caption: "Bêta"))
        try cat.setSynonyms(try cat.keywordPath("Lieux/Bretagne"), ["Breizh"])
        try cat.setColor([b.id], 4)
        try cat.setDHash(a.id, "00000000000000ff")
        try cat.createCollection("Choix", photoIds: [b.id, a.id])
        try cat.createSmartCollection("Bretagne", criteria: SearchCriteria(keywordId: try cat.keywordPath("Lieux/Bretagne")))
        return (a, b)
    }

    func testFullBackupRestoreIntoEmptyCatalog() throws {
        let (a, _) = try populate()
        let zip = try cat.backup(includePhotos: true)
        XCTAssertEqual(zip.deletingLastPathComponent().lastPathComponent, "Sauvegardes")
        XCTAssertEqual(cat.backups().count, 1)
        let check = try Catalog.verifyArchive(zip)
        XCTAssertTrue(check.ok, "\(check.problems)")
        XCTAssertEqual(check.files, 2)

        let other = try Catalog(root: dir.appendingPathComponent("autre"))
        let rep = try other.restore(from: zip)
        XCTAssertEqual(rep.photosAdded, 2)
        XCTAssertNil(rep.safetyBackup, "catalogue vide : pas de sauvegarde de sécurité")
        XCTAssertEqual(rep.collectionsAdded, 2)
        let ra = try other.photo(sha256: a.sha256)!
        XCTAssertEqual(ra.title, "Alpha")
        XCTAssertEqual(ra.rating, 3)
        XCTAssertEqual(ra.dhash, "00000000000000ff")
        XCTAssertEqual(try Data(contentsOf: other.fileURL(ra)), Data("AAAA".utf8))
        XCTAssertEqual(try other.search(SearchCriteria(text: "breizh")).map(\.sha256), [a.sha256])
        let colls = try other.collections()
        XCTAssertEqual(colls.map(\.name), ["Bretagne", "Choix"])
        XCTAssertEqual(try other.search(SearchCriteria(collectionId: colls[1].id)).map(\.fileName), ["b.jpg", "a.jpg"])
        XCTAssertEqual(try other.count(SearchCriteria(collectionId: colls[0].id)), 1, "critère mot-clé retrouvé par son chemin")
        XCTAssertEqual(try other.photo(sha256: SHA256Hasher.hex(Data("BBBB".utf8)))?.color, 4)
    }

    func testCatalogOnlyBackupMergesIntoExisting() throws {
        let (a, b) = try populate()
        let zip = try cat.backup(includePhotos: false)
        // Modifications après la sauvegarde, puis restauration : l'archive gagne sur les champs saisis.
        try cat.setTitle(a.id, "Modifié")
        try cat.removeKeyword(try cat.keywordPath("Lieux/Bretagne"), from: [a.id])
        let rep = try cat.restore(from: zip)
        XCTAssertEqual(rep.photosUpdated, 2)
        XCTAssertEqual(rep.photosAdded, 0)
        XCTAssertNotNil(rep.safetyBackup)
        XCTAssertEqual(try cat.photo(a.id)?.title, "Alpha")
        XCTAssertEqual(try cat.keywordsOf(a.id).count, 1)
        XCTAssertEqual(try cat.collections().count, 2, "pas de doublon de collection")
        XCTAssertEqual(try cat.search(SearchCriteria(collectionId: try cat.collections()[1].id)).count, 2)
        // Archive sans photos restaurée ailleurs : les fiches sans fichier sont comptées, pas inventées.
        let other = try Catalog(root: dir.appendingPathComponent("vide"))
        let r2 = try other.restore(from: zip)
        XCTAssertEqual(r2.photosWithoutFile, 2)
        XCTAssertEqual(try other.stats().photos, 0)
        _ = b
    }

    func testVerifyDetectsCorruption() throws {
        _ = try populate()
        let zip = try cat.backup(includePhotos: true)
        var bytes = try Data(contentsOf: zip)
        // Altère le contenu de la photo « AAAA » dans l'archive.
        let marker = Data("AAAA".utf8)
        guard let r = bytes.range(of: marker) else { return XCTFail("contenu introuvable") }
        bytes.replaceSubrange(r, with: Data("AAAB".utf8))
        try bytes.write(to: zip)
        let check = try Catalog.verifyArchive(zip)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.files, 1)
        let other = try Catalog(root: dir.appendingPathComponent("x"))
        XCTAssertThrowsError(try other.restore(from: zip), "CRC en échec à la restauration")
    }

    func testCSV() throws {
        _ = try populate()
        let csv = try cat.catalogCSV()
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}Fichier;Titre;"))
        XCTAssertTrue(csv.contains("2020/02/a.jpg;Alpha;;2020-02-02T00:00:00Z;"))
        XCTAssertTrue(csv.contains("Lieux › Bretagne"))
        XCTAssertTrue(csv.contains(";Bleue;"))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 4)
    }
}
