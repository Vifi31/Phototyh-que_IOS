import SwiftUI
import PhotothequeCore

/// Arbre des mots-clés : création, sous-mots-clés, renommage, synonymes, déplacement, fusion, suppression.
struct KeywordsView: View {
    @EnvironmentObject var library: Library
    @State private var tree: [KeywordNode] = []
    @State private var lookalikes: [[Keyword]] = []
    @State private var prompt: TextPrompt?
    @State private var moving: Keyword?
    @State private var toDelete: Keyword?

    var body: some View {
        NavigationStack {
            List {
                if tree.isEmpty {
                    Text("Aucun mot-clé. Touchez + pour en créer, ou ajoutez-en depuis la fiche d'une photo. Un chemin comme « Lieux/France/Paris » crée toute la hiérarchie.")
                        .foregroundStyle(.secondary)
                }
                OutlineGroup(tree, children: \.childrenOrNil) { node in
                    row(node.keyword)
                }
                if !lookalikes.isEmpty {
                    Section("Doublons de vocabulaire") {
                        ForEach(lookalikes, id: \.first!.id) { group in
                            HStack {
                                Text(group.map(\.name).joined(separator: " · "))
                                Spacer()
                                Button("Fusionner") {
                                    library.run {
                                        for k in group.dropFirst() { try library.catalog.mergeKeyword(k.id, into: group[0].id) }
                                    }
                                }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mots-clés")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        prompt = TextPrompt(title: "Nouveau mot-clé", message: "« Lieux/France/Paris » crée les niveaux manquants.") { name in
                            library.run { try library.catalog.keywordPath(name) }
                        }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Nouveau mot-clé")
                }
            }
            .textPrompt($prompt)
            .sheet(item: $moving) { k in MoveKeywordSheet(keyword: k) }
            .confirmationDialog("Supprimer « \(toDelete?.name ?? "") » ?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    if let k = toDelete { library.run { try library.catalog.deleteKeyword(k.id) } }
                    toDelete = nil
                }
            } message: {
                Text("Les photos ne sont pas touchées ; les sous-mots-clés remontent d'un niveau.")
            }
            .onAppear(perform: load)
            .onChange(of: library.revision) { _, _ in load() }
        }
    }

    private func load() {
        tree = (try? library.catalog.keywordTree()) ?? []
        lookalikes = (try? library.catalog.keywordLookalikes()) ?? []
    }

    private func row(_ k: Keyword) -> some View {
        Button {
            library.criteria = SearchCriteria(keywordId: k.id, sort: library.criteria.sort)
            library.tab = .photos
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.name).foregroundStyle(.primary)
                    if !k.synonyms.isEmpty { Text(k.synonyms.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text("\(k.photoCount)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .contextMenu {
            Button { library.criteria = SearchCriteria(keywordId: k.id, sort: library.criteria.sort); library.tab = .photos } label: {
                Label("Voir les photos", systemImage: "photo.on.rectangle")
            }
            Button {
                prompt = TextPrompt(title: "Sous-mot-clé de « \(k.name) »") { name in library.run { try library.catalog.createKeyword(name, parent: k.id) } }
            } label: { Label("Nouveau sous-mot-clé…", systemImage: "plus") }
            Button {
                prompt = TextPrompt(title: "Renommer", initial: k.name) { name in library.run { try library.catalog.renameKeyword(k.id, name) } }
            } label: { Label("Renommer…", systemImage: "pencil") }
            Button {
                prompt = TextPrompt(title: "Synonymes de « \(k.name) »", message: "Séparés par des points-virgules. La recherche les trouve aussi.",
                                    initial: k.synonyms.joined(separator: "; "), placeholder: "synonyme; autre") { text in
                    library.run { try library.catalog.setSynonyms(k.id, text.components(separatedBy: CharacterSet(charactersIn: ";,"))) }
                }
            } label: { Label("Synonymes…", systemImage: "text.badge.plus") }
            Button { moving = k } label: { Label("Déplacer…", systemImage: "arrow.turn.down.right") }
            Button(role: .destructive) { toDelete = k } label: { Label("Supprimer…", systemImage: "trash") }
        }
    }
}

/// Choix du nouveau parent d'un mot-clé (ou de la racine).
struct MoveKeywordSheet: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let keyword: Keyword

    var body: some View {
        NavigationStack {
            List {
                Button("Au premier niveau") { move(nil) }
                ForEach(((try? library.catalog.keywords()) ?? []).filter { $0.id != keyword.id }) { k in
                    Button((try? library.catalog.keywordPathName(k.id)) ?? k.name) { move(k.id) }
                }
            }
            .navigationTitle("Ranger « \(keyword.name) » sous…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
        }
    }

    private func move(_ parent: Int64?) {
        library.run { try library.catalog.moveKeyword(keyword.id, parent: parent) }
        dismiss()
    }
}
