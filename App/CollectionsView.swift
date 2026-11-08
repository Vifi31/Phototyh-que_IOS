import SwiftUI
import PhotothequeCore

/// Collections : sélections manuelles et recherches enregistrées.
struct CollectionsView: View {
    @EnvironmentObject var library: Library
    @State private var list: [PhotoCollection] = []
    @State private var prompt: TextPrompt?

    var body: some View {
        NavigationStack {
            List {
                if list.isEmpty {
                    Text("Aucune collection. Créez une sélection ici puis ajoutez-y des photos (Photos › Choisir › …), ou enregistrez une recherche depuis le menu des filtres.")
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { c in
                    Button {
                        library.criteria = SearchCriteria(collectionId: c.id)
                        library.tab = .photos
                    } label: {
                        HStack {
                            Image(systemName: c.kind == .smart ? "magnifyingglass.circle" : "rectangle.stack")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading) {
                                Text(c.name).foregroundStyle(.primary)
                                Text(c.kind == .smart ? "Recherche enregistrée" : "Sélection").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(c.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { library.run { try library.catalog.deleteCollection(c.id) } } label: { Label("Supprimer", systemImage: "trash") }
                        Button {
                            prompt = TextPrompt(title: "Renommer", initial: c.name) { name in library.run { try library.catalog.renameCollection(c.id, name) } }
                        } label: { Label("Renommer", systemImage: "pencil") }
                    }
                }
            }
            .navigationTitle("Collections")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        prompt = TextPrompt(title: "Nouvelle sélection") { name in library.run { try library.catalog.createCollection(name) } }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Nouvelle sélection")
                }
            }
            .textPrompt($prompt)
            .onAppear(perform: load)
            .onChange(of: library.revision) { _, _ in load() }
        }
    }

    private func load() { list = (try? library.catalog.collections()) ?? [] }
}

/// Photos semblables (empreinte visuelle). Rien n'est supprimé sans confirmation.
struct DuplicatesView: View {
    @EnvironmentObject var library: Library
    @AppStorage("doublons.seuil") private var threshold: Double = 6
    @State private var groups: [SimilarGroup] = []
    @State private var missing = 0
    @State private var viewer: ViewerGroup?
    @State private var toDelete: Photo?

    struct ViewerGroup: Identifiable { let id = UUID(); let photos: [Photo]; let index: Int }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading) {
                        Text("Tolérance : \(Int(threshold))")
                        Slider(value: $threshold, in: 0...16, step: 1, onEditingChanged: { editing in if !editing { load() } })
                        Text("0 : quasi identiques. 6 à 10 : même image retouchée, réduite ou réenregistrée. Les copies exactes ne sont jamais importées deux fois.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if missing > 0 {
                        Button("Calculer les \(missing) empreinte(s) manquante(s)") {
                            Task { await library.computeMissingHashes(); load() }
                        }
                    }
                }
                if groups.isEmpty {
                    Text("Aucune photo semblable à cette tolérance.").foregroundStyle(.secondary)
                }
                ForEach(groups) { g in
                    Section("\(g.photos.count) photos · écart \(g.maxDistance)") {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(Array(g.photos.enumerated()), id: \.element.id) { i, p in
                                    VStack(alignment: .leading, spacing: 4) {
                                        PhotoCell(photo: p).frame(width: 120)
                                            .onTapGesture { viewer = ViewerGroup(photos: g.photos, index: i) }
                                        Text(p.fileName).font(.caption2).lineLimit(1)
                                        Text([p.width.map { "\($0)×\(p.height ?? 0)" }, Fmt.bytes(p.size)].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Button(role: .destructive) { toDelete = p } label: { Label("Retirer", systemImage: "trash") }
                                            .font(.caption).buttonStyle(.borderless)
                                    }
                                    .frame(width: 120)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Doublons")
            .onAppear(perform: load)
            .onChange(of: library.revision) { _, _ in load() }
            .fullScreenCover(item: $viewer) { v in PhotoViewer(photos: v.photos, startIndex: v.index) }
            .confirmationDialog("Retirer « \(toDelete?.fileName ?? "") » de Photothèque ?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
                Button("Retirer du catalogue", role: .destructive) {
                    if let p = toDelete { library.run { try library.catalog.delete([p.id]) } }
                    toDelete = nil
                }
            } message: {
                Text("La copie gardée par Photothèque et ses informations sont effacées. L'original dans Photos ou Fichiers n'est pas touché.")
            }
        }
    }

    private func load() {
        groups = (try? library.catalog.similarGroups(threshold: Int(threshold))) ?? []
        missing = ((try? library.catalog.photosWithoutDHash(limit: 100_000)) ?? []).count
    }
}
