import SwiftUI
import PhotosUI
import PhotothequeCore

/// Grille des photos : recherche, filtres, sélection et actions groupées, import.
struct LibraryView: View {
    @EnvironmentObject var library: Library
    @AppStorage("grille.taille") private var cellSize: Double = 110

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var selecting = false
    @State private var selection = Set<Int64>()
    @State private var viewerIndex: ViewerStart?
    @State private var prompt: TextPrompt?
    @State private var keywordSheet = false
    @State private var collectionSheet = false
    @State private var confirmDelete = false

    struct ViewerStart: Identifiable { let id: Int }

    private var selectedIds: [Int64] { library.photos.map(\.id).filter { selection.contains($0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.photos.isEmpty {
                    emptyState.padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.6), spacing: 2)], spacing: 2) {
                        ForEach(Array(library.photos.enumerated()), id: \.element.id) { index, photo in
                            PhotoCell(photo: photo, selected: selection.contains(photo.id), selecting: selecting)
                                .onTapGesture {
                                    if selecting { toggle(photo.id) } else { viewerIndex = ViewerStart(id: index) }
                                }
                                .contextMenu { contextMenu(for: photo) }
                        }
                    }
                    if library.total > library.photos.count {
                        Text("\(library.photos.count) photos affichées sur \(library.total) : affinez la recherche.")
                            .font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $library.criteria.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Mots-clés, titre, lieu, appareil…")
            .safeAreaInset(edge: .top) { activeFilters }
            .toolbar { toolbar }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: nil,
                          selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared())
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                Task { await library.importFromPhotos(items) }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let e): library.report(e)
                }
            }
            .fullScreenCover(item: $viewerIndex) { start in
                PhotoViewer(photos: library.photos, startIndex: start.id)
            }
            .sheet(isPresented: $keywordSheet) {
                KeywordPickerSheet(title: "Ajouter un mot-clé à \(selectedIds.count) photo(s)") { kid in
                    library.run { try library.catalog.assignKeyword(kid, to: selectedIds) }
                }
            }
            .sheet(isPresented: $collectionSheet) {
                CollectionPickerSheet(photoIds: selectedIds)
            }
            .confirmationDialog("Retirer \(selectedIds.count) photo(s) de Photothèque ?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Retirer du catalogue", role: .destructive) {
                    let ids = selectedIds
                    library.run { try library.catalog.delete(ids) }
                    selection.removeAll()
                }
            } message: {
                Text("La copie gardée par Photothèque et ses informations (mots-clés, notes…) sont effacées. Les originaux dans l'app Photos ou Fichiers ne sont pas touchés.")
            }
            .textPrompt($prompt)
        }
    }

    private var title: String {
        if let cid = library.criteria.collectionId, let c = try? library.catalog.collection(cid) { return c.name }
        return library.total == 1 ? "1 photo" : "\(library.total) photos"
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 54)).foregroundStyle(.secondary)
            if library.criteria.isEmpty {
                Text("Aucune photo pour l'instant").font(.headline)
                Text("Importez des photos depuis l'app Photos ou depuis Fichiers. Photothèque en garde une copie : vos originaux ne sont jamais modifiés.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
                HStack {
                    Button { showPhotoPicker = true } label: { Label("Depuis Photos", systemImage: "photo") }
                    Button { showFileImporter = true } label: { Label("Depuis Fichiers", systemImage: "folder") }
                }.buttonStyle(.borderedProminent)
            } else {
                Text("Aucune photo ne correspond").font(.headline)
                Button("Effacer les filtres") { library.criteria = SearchCriteria(sort: library.criteria.sort) }
            }
        }
    }

    // MARK: - Filtres actifs

    @ViewBuilder private var activeFilters: some View {
        let chips = filterChips
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(chips, id: \.0) { chip in
                        Button { chip.2() } label: {
                            HStack(spacing: 4) { Text(chip.1); Image(systemName: "xmark.circle.fill") }
                                .font(.footnote).padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal).padding(.vertical, 4)
            }
            .background(.bar)
        }
    }

    private var filterChips: [(String, String, () -> Void)] {
        let c = library.criteria
        var out: [(String, String, () -> Void)] = []
        if let id = c.collectionId { out.append(("coll", "Collection : " + ((try? library.catalog.collection(id))?.name ?? "?"), { library.criteria.collectionId = nil })) }
        if let id = c.keywordId { out.append(("kw", "Mot-clé : " + ((try? library.catalog.keywordPathName(id)) ?? "?"), { library.criteria.keywordId = nil })) }
        if let y = c.year { out.append(("year", "Année \(y)", { library.criteria.year = nil })) }
        if let r = c.minRating { out.append(("rating", "≥ \(r) ★", { library.criteria.minRating = nil })) }
        if let col = c.color { out.append(("color", "Étiquette \(ColorLabel(rawValue: col)?.name ?? "")", { library.criteria.color = nil })) }
        if let cam = c.camera { out.append(("cam", cam, { library.criteria.camera = nil })) }
        if let g = c.hasGPS { out.append(("gps", g ? "Avec GPS" : "Sans GPS", { library.criteria.hasGPS = nil })) }
        if let m = c.missing { out.append(("missing", m.label, { library.criteria.missing = nil })) }
        return out
    }

    // MARK: - Barre d'outils

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(selecting ? "OK" : "Choisir") {
                selecting.toggle()
                if !selecting { selection.removeAll() }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            filterMenu
            Menu {
                Button { showPhotoPicker = true } label: { Label("Depuis Photos", systemImage: "photo") }
                Button { showFileImporter = true } label: { Label("Depuis Fichiers", systemImage: "folder") }
            } label: { Image(systemName: "plus") }
            .accessibilityLabel("Importer")
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(selection.count == library.photos.count ? "Aucune" : "Toutes") {
                    selection = selection.count == library.photos.count ? [] : Set(library.photos.map(\.id))
                }
                Spacer()
                Text("\(selection.count) choisie(s)").font(.footnote)
                Spacer()
                Menu {
                    Menu("Note") {
                        ForEach(0...5, id: \.self) { n in
                            Button(n == 0 ? "Sans note" : String(repeating: "★", count: n)) {
                                library.run { try library.catalog.setRating(selectedIds, n) }
                            }
                        }
                    }
                    Menu("Étiquette") {
                        ForEach(ColorLabel.allCases, id: \.self) { c in
                            Button(c.name) { library.run { try library.catalog.setColor(selectedIds, c.rawValue) } }
                        }
                    }
                    Button { keywordSheet = true } label: { Label("Ajouter un mot-clé…", systemImage: "tag") }
                    Button { collectionSheet = true } label: { Label("Ajouter à une collection…", systemImage: "rectangle.stack.badge.plus") }
                    Button {
                        prompt = TextPrompt(title: "Lieu", message: "Lieu de \(selectedIds.count) photo(s)", placeholder: "Ville, région…") { text in
                            library.run { try library.catalog.setPlace(selectedIds, text) }
                        }
                    } label: { Label("Indiquer le lieu…", systemImage: "mappin") }
                    if let cid = library.criteria.collectionId, (try? library.catalog.collection(cid))?.kind == .static {
                        Button { library.run { try library.catalog.removeFromCollection(cid, selectedIds) } } label: {
                            Label("Retirer de cette collection", systemImage: "rectangle.stack.badge.minus")
                        }
                    }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Retirer du catalogue…", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(selection.isEmpty)
                ShareLink(items: selectedIds.compactMap { id in library.photos.first { $0.id == id } }.map { library.url($0) }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Tri", selection: $library.criteria.sort) {
                ForEach(PhotoSort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Menu("Note minimale") {
                Button("Toutes") { library.criteria.minRating = nil }
                ForEach(1...5, id: \.self) { n in Button(String(repeating: "★", count: n) + " et plus") { library.criteria.minRating = n } }
            }
            Menu("Étiquette") {
                Button("Toutes") { library.criteria.color = nil }
                ForEach(ColorLabel.allCases.filter { $0 != .none }, id: \.self) { c in Button(c.name) { library.criteria.color = c.rawValue } }
            }
            Menu("Année") {
                Button("Toutes") { library.criteria.year = nil }
                ForEach((try? library.catalog.years()) ?? [], id: \.year) { y in
                    Button("\(String(y.year)) (\(y.count))") { library.criteria.year = y.year }
                }
            }
            Menu("Appareil") {
                Button("Tous") { library.criteria.camera = nil }
                ForEach((try? library.catalog.cameras()) ?? [], id: \.name) { c in
                    Button("\(c.name) (\(c.count))") { library.criteria.camera = c.name }
                }
            }
            Menu("Position GPS") {
                Button("Indifférent") { library.criteria.hasGPS = nil }
                Button("Avec position") { library.criteria.hasGPS = true }
                Button("Sans position") { library.criteria.hasGPS = false }
            }
            Menu("Manques") {
                Button("Aucun filtre") { library.criteria.missing = nil }
                ForEach(MissingInfo.allCases, id: \.self) { m in Button(m.label) { library.criteria.missing = m } }
            }
            Divider()
            Menu("Taille des vignettes") {
                Button("Petites") { cellSize = 80 }
                Button("Moyennes") { cellSize = 110 }
                Button("Grandes") { cellSize = 170 }
            }
            if !library.criteria.isEmpty {
                Button {
                    prompt = TextPrompt(title: "Enregistrer la recherche", message: "Une recherche enregistrée se met à jour toute seule.", placeholder: "Nom") { name in
                        library.run { try library.catalog.createSmartCollection(name, criteria: library.criteria) }
                    }
                } label: { Label("Enregistrer la recherche…", systemImage: "bookmark") }
                Button(role: .destructive) { library.criteria = SearchCriteria(sort: library.criteria.sort) } label: {
                    Label("Effacer les filtres", systemImage: "xmark")
                }
            }
        } label: {
            Image(systemName: library.criteria.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filtres et tri")
    }

    @ViewBuilder private func contextMenu(for photo: Photo) -> some View {
        Button { viewerIndex = ViewerStart(id: library.photos.firstIndex(of: photo) ?? 0) } label: { Label("Ouvrir", systemImage: "eye") }
        ShareLink(item: library.url(photo)) { Label("Partager", systemImage: "square.and.arrow.up") }
        Button {
            selecting = true
            selection = [photo.id]
        } label: { Label("Choisir", systemImage: "checkmark.circle") }
    }

    private func toggle(_ id: Int64) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

/// Choix (ou création) d'un mot-clé.
struct KeywordPickerSheet: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (Int64) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            List {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    Button {
                        do { let id = try library.catalog.keywordPath(trimmed); onPick(id); dismiss() } catch { library.report(error) }
                    } label: { Label("Créer « \(trimmed) »", systemImage: "plus") }
                }
                ForEach(matches, id: \.id) { k in
                    Button {
                        onPick(k.id); dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text((try? library.catalog.keywordPathName(k.id)) ?? k.name)
                            if !k.synonyms.isEmpty { Text(k.synonyms.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nom ou chemin (Lieux/France/Paris)")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
        }
    }

    private var matches: [Keyword] {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return (try? library.catalog.keywords()) ?? [] }
        return (try? library.catalog.suggestKeywords(t, limit: 50)) ?? []
    }
}

/// Ajout de photos à une collection existante ou nouvelle.
struct CollectionPickerSheet: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let photoIds: [Int64]
    @State private var prompt: TextPrompt?

    var body: some View {
        NavigationStack {
            List {
                Button {
                    prompt = TextPrompt(title: "Nouvelle collection", placeholder: "Nom") { name in
                        library.run { try library.catalog.createCollection(name, photoIds: photoIds) }
                        dismiss()
                    }
                } label: { Label("Nouvelle collection…", systemImage: "plus") }
                ForEach(((try? library.catalog.collections()) ?? []).filter { $0.kind == .static }) { c in
                    Button {
                        library.run { try library.catalog.addToCollection(c.id, photoIds) }
                        dismiss()
                    } label: {
                        HStack { Text(c.name); Spacer(); Text("\(c.count)").foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Ajouter \(photoIds.count) photo(s)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
            .textPrompt($prompt)
        }
    }
}
