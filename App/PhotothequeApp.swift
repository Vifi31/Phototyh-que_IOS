import SwiftUI
import PhotothequeCore

@main
struct PhotothequeApp: App {
    @StateObject private var library = Library.open()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
    }
}

enum AppTab: Hashable { case photos, keywords, collections, duplicates, settings }

struct RootView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        Group {
            if let error = library.openError {
                ContentUnavailableView("Photothèque ne peut pas s'ouvrir", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                TabView(selection: $library.tab) {
                    LibraryView()
                        .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                        .tag(AppTab.photos)
                    KeywordsView()
                        .tabItem { Label("Mots-clés", systemImage: "tag") }
                        .tag(AppTab.keywords)
                    CollectionsView()
                        .tabItem { Label("Collections", systemImage: "rectangle.stack") }
                        .tag(AppTab.collections)
                    DuplicatesView()
                        .tabItem { Label("Doublons", systemImage: "square.on.square") }
                        .tag(AppTab.duplicates)
                    SettingsView()
                        .tabItem { Label("Réglages", systemImage: "gearshape") }
                        .tag(AppTab.settings)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let busy = library.busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(busy).font(.callout)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 64)
            }
        }
        .alert(item: $library.message) { m in
            Alert(title: Text(m.isError ? "Erreur" : "Photothèque"), message: Text(m.text), dismissButton: .default(Text("OK")))
        }
    }
}
