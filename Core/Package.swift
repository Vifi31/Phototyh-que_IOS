// swift-tools-version:5.9
// Cœur de Photothèque pour iOS : catalogue SQLite, mots-clés, recherche,
// collections, doublons, sauvegardes. Sans interface : compilable et testable
// sous Linux (WSL) comme sous iOS / macOS.
import PackageDescription

let package = Package(
    name: "PhotothequeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PhotothequeCore", targets: ["PhotothequeCore"]),
    ],
    targets: [
        // Sous Linux seulement : accès à la libsqlite3 du système.
        // Sous iOS / macOS, le module SQLite3 du SDK est utilisé.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "PhotothequeCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))]
        ),
        .testTarget(name: "PhotothequeCoreTests", dependencies: ["PhotothequeCore"]),
    ]
)
