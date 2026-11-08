import SwiftUI
import UniformTypeIdentifiers
import PhotothequeCore

/// Réglages : chiffres, sauvegardes (créer, vérifier, partager, restaurer), catalogue CSV, intégrité, journal.
struct SettingsView: View {
    @EnvironmentObject var library: Library
    @State private var stats: CatalogStats?
    @State private var backups: [(url: URL, size: Int64, date: Date)] = []
    @State private var showRestorePicker = false
    @State private var restoreURL: URL?
    @State private var csvURL: URL?
    @State private var cacheSize: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                if let s = stats {
                    Section("Catalogue") {
                        LabeledContent("Photos", value: "\(s.photos)")
                        LabeledContent("Volume", value: Fmt.bytes(s.bytes))
                        LabeledContent("Mots-clés", value: "\(s.keywords)")
                        LabeledContent("Collections", value: "\(s.collections)")
                        manque("Sans mot-clé", s.withoutKeywords, .keywords)
                        manque("Sans titre", s.withoutTitle, .title)
                        LabeledContent("Avec position GPS", value: "\(s.withGPS)")
                        LabeledContent("Notées", value: "\(s.rated)")
                    }
                }

                Section {
                    Button { makeBackup(includePhotos: false) } label: { Label("Sauvegarder le catalogue", systemImage: "doc.zipper") }
                    Button { makeBackup(includePhotos: true) } label: { Label("Sauvegarde complète (avec les photos)", systemImage: "externaldrive.badge.plus") }
                    Button { showRestorePicker = true } label: { Label("Restaurer une sauvegarde…", systemImage: "arrow.counterclockwise") }
                    ForEach(backups, id: \.url) { b in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(b.url.lastPathComponent).font(.footnote).lineLimit(1)
                                Text("\(b.date.formatted(date: .abbreviated, time: .shortened)) · \(Fmt.bytes(b.size))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: b.url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                try? FileManager.default.removeItem(at: b.url); load()
                            } label: { Label("Supprimer", systemImage: "trash") }
                            Button { verify(b.url) } label: { Label("Vérifier", systemImage: "checkmark.seal") }.tint(.green)
                        }
                    }
                } header: {
                    Text("Sauvegardes")
                } footer: {
                    Text("Les archives sont rangées dans Fichiers › Sur mon iPhone › Photothèque › Sauvegardes. Partagez-les vers iCloud Drive, un disque ou un ordinateur pour les garder hors de l'appareil. Balayez une archive pour la vérifier. La restauration complète le catalogue sans rien supprimer, après une sauvegarde de sécurité.")
                }

                Section("Exports") {
                    Button { exportCSV() } label: { Label("Catalogue CSV (photos affichées)", systemImage: "tablecells") }
                    if let csvURL {
                        ShareLink(item: csvURL) { Label("Partager \(csvURL.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    }
                }

                Section("Entretien") {
                    Button { checkIntegrity() } label: { Label("Contrôler l'intégrité", systemImage: "stethoscope") }
                    Button {
                        ImageCache.shared.clear(); cacheSize = 0
                    } label: { Label("Vider le cache des vignettes (\(Fmt.bytes(cacheSize)))", systemImage: "trash") }
                    NavigationLink { HistoryView() } label: { Label("Journal", systemImage: "clock") }
                }

                Section("À propos") {
                    LabeledContent("Version", value: Catalog.appVersion)
                    LabeledContent("SQLite", value: Database.libraryVersion + (library.catalog.hasFullText ? " (FTS5)" : ""))
                    Text("Photothèque garde ses données dans l'appareil (aucun compte, aucun serveur). Les originaux importés depuis Photos ou Fichiers ne sont jamais modifiés.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Réglages")
            .onAppear(perform: load)
            .onChange(of: library.revision) { _, _ in load() }
            .fileImporter(isPresented: $showRestorePicker, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result { restoreURL = urls.first }
                if case .failure(let e) = result { library.report(e) }
            }
            .confirmationDialog("Restaurer « \(restoreURL?.lastPathComponent ?? "") » ?", isPresented: Binding(get: { restoreURL != nil }, set: { if !$0 { restoreURL = nil } }), titleVisibility: .visible) {
                Button("Restaurer") { if let u = restoreURL { restore(u) }; restoreURL = nil }
            } message: {
                Text("Une sauvegarde de sécurité du catalogue actuel est faite d'abord. Les informations de l'archive (titres, notes, mots-clés…) s'appliquent aux photos reconnues ; les photos absentes sont recopiées si l'archive les contient. Rien n'est supprimé.")
            }
        }
    }

    private func manque(_ label: String, _ n: Int, _ m: MissingInfo) -> some View {
        Button {
            library.criteria = SearchCriteria(missing: m)
            library.tab = .photos
        } label: {
            LabeledContent(label) { Text("\(n)").foregroundStyle(n > 0 ? Color.orange : Color.secondary) }
        }
        .disabled(n == 0)
    }

    private func load() {
        stats = try? library.catalog.stats()
        backups = library.catalog.backups()
        cacheSize = ImageCache.shared.diskSize
    }

    private func makeBackup(includePhotos: Bool) {
        library.busy = "Sauvegarde…"
        Task { @MainActor in
            await Task.yield()
            do {
                let url = try library.catalog.backup(includePhotos: includePhotos) { done, total in
                    library.busy = "Sauvegarde \(done) / \(total)…"
                }
                library.busy = nil
                load()
                library.inform("Sauvegarde créée : \(url.lastPathComponent). Pensez à la copier hors de l'appareil (bouton Partager).")
            } catch {
                library.busy = nil
                library.report(error)
            }
        }
    }

    private func verify(_ url: URL) {
        library.busy = "Vérification…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ArchiveCheck, Error> in
                Result { try Catalog.verifyArchive(url) }
            }.value
            library.busy = nil
            switch result {
            case .success(let c) where c.ok:
                library.inform("Archive intacte : \(c.photos) fiche(s), \(c.files) photo(s) vérifiée(s) par empreinte, \(c.keywords) mot(s)-clé(s), \(c.collections) collection(s).")
            case .success(let c):
                library.message = .init(text: "Archive abîmée :\n" + c.problems.prefix(10).joined(separator: "\n"), isError: true)
            case .failure(let e):
                library.report(e)
            }
        }
    }

    private func restore(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        library.busy = "Restauration…"
        Task { @MainActor in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await Task.yield()
            do {
                let r = try library.catalog.restore(from: url) { done, total in library.busy = "Restauration \(done) / \(total)…" }
                library.busy = nil
                library.run {}
                var text = "\(r.photosAdded) photo(s) ajoutée(s), \(r.photosUpdated) mise(s) à jour, \(r.collectionsAdded) collection(s) ajoutée(s)."
                if r.photosWithoutFile > 0 { text += "\n\(r.photosWithoutFile) fiche(s) sans fichier dans l'archive (sauvegarde du catalogue seul) : ignorée(s)." }
                if let s = r.safetyBackup { text += "\nSauvegarde de sécurité : \(s)" }
                library.inform(text)
                await library.computeMissingHashes()
            } catch {
                library.busy = nil
                library.report(error)
            }
        }
    }

    private func exportCSV() {
        do {
            let csv = try library.catalog.catalogCSV(library.criteria)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
            let url = library.catalog.exportsDir.appendingPathComponent("Catalogue-\(f.string(from: Date())).csv")
            try csv.data(using: .utf8)!.write(to: url)
            csvURL = url
        } catch { library.report(error) }
    }

    private func checkIntegrity() {
        do {
            let problems = try Schema.integrity(library.catalog.db)
            let missing = try library.catalog.missingFiles()
            if problems.isEmpty && missing.isEmpty {
                library.inform("Base intègre ; tous les fichiers des photos sont présents.")
            } else {
                var t = problems.joined(separator: "\n")
                if !missing.isEmpty { t += (t.isEmpty ? "" : "\n") + "\(missing.count) fichier(s) absent(s) : " + missing.prefix(5).map(\.relPath).joined(separator: ", ") }
                library.message = .init(text: t, isError: true)
            }
        } catch { library.report(error) }
    }
}

struct HistoryView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        List(Array(((try? library.catalog.history()) ?? []).enumerated()), id: \.offset) { _, h in
            VStack(alignment: .leading, spacing: 2) {
                Text(h.action.capitalized).font(.subheadline)
                if !h.detail.isEmpty { Text(h.detail).font(.caption).foregroundStyle(.secondary) }
                Text(Fmt.date(h.at)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Journal")
    }
}
