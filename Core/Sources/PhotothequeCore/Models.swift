import Foundation

/// Étiquettes de couleur (mêmes numéros que la Photothèque de bureau).
public enum ColorLabel: Int, CaseIterable, Codable, Sendable {
    case none = 0, red, yellow, green, blue, purple
    public var name: String {
        switch self {
        case .none: return "Aucune"
        case .red: return "Rouge"
        case .yellow: return "Jaune"
        case .green: return "Verte"
        case .blue: return "Bleue"
        case .purple: return "Violette"
        }
    }
}

/// Fiche photo du catalogue.
public struct Photo: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64
    public var fileName: String
    public var relPath: String
    public var sha256: String
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
    public var sourceId: String?
    public var dhash: String?

    public var camera: String {
        let make = cameraMake.trimmingCharacters(in: .whitespaces)
        let model = cameraModel.trimmingCharacters(in: .whitespaces)
        if model.lowercased().hasPrefix(make.lowercased()) { return model }
        return [make, model].filter { !$0.isEmpty }.joined(separator: " ")
    }
    public var takenDate: Date? { ISODate.date(takenAt) }
    public var hasGPS: Bool { latitude != nil && longitude != nil }
    public var displayTitle: String { title.isEmpty ? fileName : title }

    init(row r: Row) {
        id = r.int64("id") ?? 0
        fileName = r.string("file_name") ?? ""
        relPath = r.string("rel_path") ?? ""
        sha256 = r.string("sha256") ?? ""
        size = r.int64("size") ?? 0
        width = r.int("width")
        height = r.int("height")
        format = r.string("format") ?? ""
        takenAt = r.string("taken_at")
        importedAt = r.string("imported_at") ?? ""
        cameraMake = r.string("camera_make") ?? ""
        cameraModel = r.string("camera_model") ?? ""
        lens = r.string("lens") ?? ""
        latitude = r.double("latitude")
        longitude = r.double("longitude")
        place = r.string("place") ?? ""
        title = r.string("title") ?? ""
        caption = r.string("caption") ?? ""
        rating = r.int("rating") ?? 0
        color = r.int("color") ?? 0
        source = r.string("source") ?? ""
        sourceId = r.string("source_id")
        dhash = r.string("dhash")
    }
}

/// Métadonnées lues dans le fichier au moment de l'import (ImageIO côté application).
public struct PhotoMetadata: Codable, Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var format: String
    public var takenAt: Date?
    public var cameraMake: String
    public var cameraModel: String
    public var lens: String
    public var latitude: Double?
    public var longitude: Double?
    public var title: String
    public var caption: String
    public var keywords: [String]
    public var rating: Int

    public init(width: Int? = nil, height: Int? = nil, format: String = "", takenAt: Date? = nil,
                cameraMake: String = "", cameraModel: String = "", lens: String = "",
                latitude: Double? = nil, longitude: Double? = nil, title: String = "", caption: String = "",
                keywords: [String] = [], rating: Int = 0) {
        self.width = width; self.height = height; self.format = format; self.takenAt = takenAt
        self.cameraMake = cameraMake; self.cameraModel = cameraModel; self.lens = lens
        self.latitude = latitude; self.longitude = longitude; self.title = title; self.caption = caption
        self.keywords = keywords; self.rating = rating
    }
}

/// Mot-clé (hiérarchique, avec synonymes).
public struct Keyword: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64
    public var name: String
    public var parentId: Int64?
    public var synonyms: [String]
    public var photoCount: Int

    init(row r: Row) {
        id = r.int64("id") ?? 0
        name = r.string("name") ?? ""
        parentId = r.int64("parent_id")
        synonyms = Keyword.splitSynonyms(r.string("synonyms") ?? "")
        photoCount = r.int("photo_count") ?? 0
    }

    static func splitSynonyms(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Nœud de l'arbre des mots-clés.
public struct KeywordNode: Identifiable, Hashable, Sendable {
    public var keyword: Keyword
    public var children: [KeywordNode]
    public var id: Int64 { keyword.id }
    /// `nil` pour une feuille (attendu par `List(children:)` de SwiftUI).
    public var childrenOrNil: [KeywordNode]? { children.isEmpty ? nil : children }
}

public enum CollectionKind: String, Codable, Sendable { case `static`, smart }

/// Collection : sélection manuelle (statique) ou recherche enregistrée (dynamique).
public struct PhotoCollection: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64
    public var name: String
    public var kind: CollectionKind
    public var criteria: SearchCriteria?
    public var createdAt: String
    public var count: Int
}

/// Résultat d'un import de fichier.
public enum ImportOutcome: Equatable, Sendable {
    case added(Photo)
    case duplicate(Photo)

    public var photo: Photo {
        switch self { case .added(let p), .duplicate(let p): return p }
    }
    public var isDuplicate: Bool { if case .duplicate = self { return true } else { return false } }
}

/// Chiffres du catalogue.
public struct CatalogStats: Equatable, Sendable {
    public var photos: Int
    public var bytes: Int64
    public var keywords: Int
    public var collections: Int
    public var withoutKeywords: Int
    public var withoutTitle: Int
    public var withGPS: Int
    public var rated: Int
}
