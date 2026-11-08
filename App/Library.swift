import SwiftUI
import PhotosUI
import PhotothequeCore

/// État partagé de l'application : catalogue ouvert, recherche courante, messages.
/// Toutes les opérations sur le catalogue se font sur le fil principal (une seule connexion SQLite).
@MainActor
final class Library: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    let catalog: Catalog!
    let openError: String?

    @Published var tab: AppTab = .photos
    @Published var criteria = SearchCriteria() { didSet { if criteria != oldValue { reload() } } }
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var total = 0
    @Published var message: Message?
    @Published var busy: String?
    /// Incrémenté à chaque modification : les vues secondaires se rechargent.
    @Published private(set) var revision = 0

    static let gridLimit = 5000

    /// Dossier de la photothèque : Documents/Photothèque (visible dans l'app Fichiers, « Sur mon iPhone »).
    static func rootURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Photothèque", isDirectory: true)
    }

    static func open() -> Library {
        Catalog.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Catalog.appVersion
        let lib: Library
        do { lib = Library(catalog: try Catalog(root: rootURL()), error: nil) }
        catch { return Library(catalog: nil, error: error.localizedDescription) }
        #if DEBUG
        // Essai automatique (CI, simulateur) : importe les images d'un dossier au lancement.
        if let dir = ProcessInfo.processInfo.environment["PHOTOTHEQUE_DEMO_DIR"] {
            let urls = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
                .filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            Task { @MainActor in await lib.importFiles(urls) }
        }
        #endif
        return lib
    }

    init(catalog: Catalog?, error: String?) {
        self.catalog = catalog
        self.openError = error
        if catalog != nil { reload() }
    }

    func reload() {
        guard let catalog else { return }
        do {
            photos = try catalog.search(criteria, limit: Library.gridLimit)
            total = try catalog.count(criteria)
        } catch { report(error) }
    }

    /// Exécute une modification, puis rafraîchit l'affichage ; les erreurs sont affichées.
    func run(_ body: () throws -> Void) {
        do { try body() } catch { report(error) }
        revision += 1
        reload()
    }

    func report(_ error: Error) {
        message = Message(text: error.localizedDescription, isError: true)
    }

    func inform(_ text: String) {
        message = Message(text: text, isError: false)
    }

    func url(_ p: Photo) -> URL { catalog.fileURL(p) }

    func refreshed(_ p: Photo) -> Photo { (try? catalog.photo(p.id)) ?? p }

    // MARK: - Import

    /// Photos choisies dans la photothèque d'iOS : une copie de l'original est rangée dans Photothèque.
    func importFromPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var added = 0, dup = 0, failed: [String] = []
        for (i, item) in items.enumerated() {
            busy = "Import \(i + 1) / \(items.count)…"
            if let sid = item.itemIdentifier, (try? catalog.photo(sourceId: sid)) != nil { dup += 1; continue }
            do {
                guard let picked = try await item.loadTransferable(type: PickedFile.self) else { failed.append("photo \(i + 1)"); continue }
                defer { try? FileManager.default.removeItem(at: picked.url.deletingLastPathComponent()) }
                let outcome = try await importOne(picked.url, name: picked.url.lastPathComponent, source: "photos", sourceId: item.itemIdentifier)
                if outcome.isDuplicate { dup += 1 } else { added += 1 }
            } catch {
                failed.append("photo \(i + 1) : \(error.localizedDescription)")
            }
        }
        finishImport(added: added, dup: dup, failed: failed)
    }

    /// Fichiers choisis dans l'app Fichiers (iCloud Drive, clé USB, serveur…) : copiés, jamais déplacés.
    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var added = 0, dup = 0, failed: [String] = []
        for (i, url) in urls.enumerated() {
            busy = "Import \(i + 1) / \(urls.count)…"
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let outcome = try await importOne(url, name: url.lastPathComponent, source: "fichiers", sourceId: nil)
                if outcome.isDuplicate { dup += 1 } else { added += 1 }
            } catch {
                failed.append("\(url.lastPathComponent) : \(error.localizedDescription)")
            }
        }
        finishImport(added: added, dup: dup, failed: failed)
    }

    private func importOne(_ url: URL, name: String, source: String, sourceId: String?) async throws -> ImportOutcome {
        // Lecture des métadonnées et empreinte visuelle hors du fil principal.
        let analysis = await Task.detached(priority: .userInitiated) { () -> (PhotoMetadata, String?) in
            (ImageTools.metadata(of: url), ImageTools.dhash(of: url))
        }.value
        return try catalog.importFile(at: url, metadata: analysis.0, originalName: name, source: source, sourceId: sourceId, dhash: analysis.1)
    }

    private func finishImport(added: Int, dup: Int, failed: [String]) {
        busy = nil
        revision += 1
        reload()
        var parts = ["\(added) photo(s) ajoutée(s)"]
        if dup > 0 { parts.append("\(dup) déjà présente(s)") }
        var text = parts.joined(separator: ", ") + "."
        if !failed.isEmpty { text += "\n\nNon importée(s) :\n" + failed.prefix(10).joined(separator: "\n") }
        message = Message(text: text, isError: !failed.isEmpty && added == 0)
    }

    /// Calcule les empreintes visuelles manquantes (photos restaurées ou importées par une version antérieure).
    func computeMissingHashes() async {
        let todo = (try? catalog.photosWithoutDHash(limit: 100_000)) ?? []
        guard !todo.isEmpty else { return }
        for (i, p) in todo.enumerated() {
            busy = "Empreintes \(i + 1) / \(todo.count)…"
            let url = catalog.fileURL(p)
            let h = await Task.detached(priority: .utility) { ImageTools.dhash(of: url) }.value
            if let h { try? catalog.setDHash(p.id, h) }
        }
        busy = nil
        revision += 1
    }
}

/// Fichier reçu du sélecteur de photos (copie temporaire de l'original).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}
