import Foundation

/// Schéma de la base et migrations numérotées (`PRAGMA user_version`).
public enum Schema {
    public static let version = 1

    static let v1 = """
    CREATE TABLE photos (
      id INTEGER PRIMARY KEY,
      file_name TEXT NOT NULL,
      rel_path TEXT NOT NULL UNIQUE,
      sha256 TEXT NOT NULL,
      size INTEGER NOT NULL,
      width INTEGER,
      height INTEGER,
      format TEXT NOT NULL DEFAULT '',
      taken_at TEXT,
      imported_at TEXT NOT NULL,
      camera_make TEXT NOT NULL DEFAULT '',
      camera_model TEXT NOT NULL DEFAULT '',
      lens TEXT NOT NULL DEFAULT '',
      latitude REAL,
      longitude REAL,
      place TEXT NOT NULL DEFAULT '',
      title TEXT NOT NULL DEFAULT '',
      caption TEXT NOT NULL DEFAULT '',
      rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
      color INTEGER NOT NULL DEFAULT 0 CHECK (color BETWEEN 0 AND 5),
      source TEXT NOT NULL DEFAULT '',
      source_id TEXT,
      dhash TEXT,
      search_text TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX photos_sha ON photos(sha256);
    CREATE INDEX photos_taken ON photos(taken_at);
    CREATE INDEX photos_source ON photos(source_id);

    CREATE TABLE keywords (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      name_key TEXT NOT NULL,
      parent_id INTEGER REFERENCES keywords(id) ON DELETE SET NULL,
      synonyms TEXT NOT NULL DEFAULT ''
    );
    CREATE UNIQUE INDEX keywords_unique ON keywords(IFNULL(parent_id, 0), name_key);

    CREATE TABLE photo_keywords (
      photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      keyword_id INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
      PRIMARY KEY (photo_id, keyword_id)
    );
    CREATE INDEX photo_keywords_kw ON photo_keywords(keyword_id);

    CREATE TABLE collections (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('static', 'smart')),
      criteria TEXT,
      created_at TEXT NOT NULL
    );
    CREATE TABLE collection_photos (
      collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
      photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      position INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (collection_id, photo_id)
    );

    CREATE TABLE history (
      id INTEGER PRIMARY KEY,
      at TEXT NOT NULL,
      action TEXT NOT NULL,
      detail TEXT NOT NULL DEFAULT ''
    );

    CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """

    /// Index plein texte (FTS5) tenu à jour par déclencheurs. Absent si le SQLite n'a pas FTS5.
    static let fts = """
    CREATE VIRTUAL TABLE photos_fts USING fts5(search_text, content='photos', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
    CREATE TRIGGER photos_fts_ai AFTER INSERT ON photos BEGIN
      INSERT INTO photos_fts(rowid, search_text) VALUES (new.id, new.search_text);
    END;
    CREATE TRIGGER photos_fts_ad AFTER DELETE ON photos BEGIN
      INSERT INTO photos_fts(photos_fts, rowid, search_text) VALUES ('delete', old.id, old.search_text);
    END;
    CREATE TRIGGER photos_fts_au AFTER UPDATE OF search_text ON photos BEGIN
      INSERT INTO photos_fts(photos_fts, rowid, search_text) VALUES ('delete', old.id, old.search_text);
      INSERT INTO photos_fts(rowid, search_text) VALUES (new.id, new.search_text);
    END;
    """

    /// Applique les migrations manquantes. Renvoie vrai si l'index FTS5 est disponible.
    @discardableResult
    static func migrate(_ db: Database, fullText: Bool = true) throws -> Bool {
        let current = try db.scalarInt("PRAGMA user_version")
        if current > version {
            throw SQLiteError("La base a été créée par une version plus récente de Photothèque (schéma \(current)).")
        }
        if current < 1 {
            try db.transaction {
                try db.execute(v1)
                if fullText && db.hasFTS5() { try db.execute(fts) }
                try db.execute("PRAGMA user_version = 1")
            }
        }
        return try db.first("SELECT name FROM sqlite_master WHERE name = 'photos_fts'") != nil
    }

    /// Contrôle d'intégrité SQLite + clés étrangères.
    public static func integrity(_ db: Database) throws -> [String] {
        var problems: [String] = []
        for r in try db.query("PRAGMA integrity_check") {
            if let s = r.values.values.first, case .text(let t) = s, t != "ok" { problems.append(t) }
        }
        let fk = try db.query("PRAGMA foreign_key_check")
        if !fk.isEmpty { problems.append("\(fk.count) référence(s) cassée(s)") }
        return problems
    }
}
