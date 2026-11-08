import SwiftUI
import PhotothequeCore

/// Image d'une photo du catalogue (vignette ou aperçu), chargée en tâche de fond.
struct PhotoImage: View {
    @EnvironmentObject var library: Library
    let photo: Photo
    let maxPixel: Int
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.12))
            }
        }
        .task(id: "\(photo.sha256)-\(maxPixel)") {
            let img = await ImageCache.shared.image(for: library.url(photo), key: photo.sha256, maxPixel: maxPixel)
            image = img
            failed = img == nil
        }
    }
}

/// Case carrée de la grille.
struct PhotoCell: View {
    let photo: Photo
    var selected = false
    var selecting = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(PhotoImage(photo: photo, maxPixel: 360))
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if photo.color > 0 { Circle().fill(labelColor(photo.color)).frame(width: 9, height: 9) }
                    if photo.rating > 0 {
                        Text(String(repeating: "★", count: photo.rating)).font(.system(size: 9)).foregroundStyle(.yellow)
                    }
                }
                .padding(3)
                .shadow(radius: 1)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .overlay { if selected { Rectangle().stroke(Color.accentColor, lineWidth: 3) } }
            .contentShape(Rectangle())
            .accessibilityLabel(photo.displayTitle)
    }
}

/// Note de 0 à 5 étoiles (toucher l'étoile déjà choisie retire la note).
struct RatingPicker: View {
    let rating: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { n in
                Button { onChange(n == rating ? 0 : n) } label: {
                    Image(systemName: n <= rating ? "star.fill" : "star")
                        .foregroundStyle(n <= rating ? .yellow : .secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(n) étoile(s)")
            }
        }
    }
}

/// Étiquettes de couleur.
struct ColorPicker5: View {
    let color: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ColorLabel.allCases.filter { $0 != .none }, id: \.self) { c in
                Button { onChange(c.rawValue == color ? 0 : c.rawValue) } label: {
                    Circle().fill(labelColor(c.rawValue))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.primary, lineWidth: c.rawValue == color ? 2.5 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Étiquette \(c.name)")
            }
        }
    }
}

func labelColor(_ n: Int) -> Color {
    switch ColorLabel(rawValue: n) ?? .none {
    case .red: return .red
    case .yellow: return .yellow
    case .green: return .green
    case .blue: return .blue
    case .purple: return .purple
    case .none: return .clear
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func date(_ iso: String?) -> String {
        guard let d = ISODate.date(iso) else { return "—" }
        return d.formatted(date: .long, time: .shortened)
    }

    static func shortDate(_ iso: String?) -> String {
        guard let d = ISODate.date(iso) else { return "—" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Saisie d'un texte dans une alerte (nom de mot-clé, de collection…).
struct TextPrompt: Identifiable {
    let id = UUID()
    let title: String
    var message: String = ""
    var initial: String = ""
    var placeholder: String = "Nom"
    let action: (String) -> Void
}

extension View {
    func textPrompt(_ prompt: Binding<TextPrompt?>) -> some View {
        modifier(TextPromptModifier(prompt: prompt))
    }
}

private struct TextPromptModifier: ViewModifier {
    @Binding var prompt: TextPrompt?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                TextField(prompt?.placeholder ?? "", text: $text)
                Button("Annuler", role: .cancel) { prompt = nil }
                Button("OK") {
                    let p = prompt
                    prompt = nil
                    p?.action(text)
                }
            } message: {
                if let m = prompt?.message, !m.isEmpty { Text(m) }
            }
            .onChange(of: prompt?.id) { _, _ in text = prompt?.initial ?? "" }
    }
}
