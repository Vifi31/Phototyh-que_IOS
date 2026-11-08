# Photothèque pour iOS — notes de travail (CLAUDE.md)

Application iOS autonome (SwiftUI, iOS 17+), déclinaison de `C:\DVP\Phototheque`
(bureau, Node.js). Dépôt : https://github.com/Vifi31/Phototyh-que_IOS.

## Commandes

```bash
scripts/test-wsl.sh                      # tests du cœur sous WSL (Swift dans ~/swift)
swift test --package-path Core           # idem sous macOS / Linux avec Swift installé
xcodegen generate                        # macOS : génère Phototheque.xcodeproj (non versionné)
```

Depuis Windows : `wsl.exe -e bash /mnt/c/DVP/PhotothequeIOS/scripts/test-wsl.sh`.
L'app SwiftUI ne compile que sur macOS : elle est vérifiée par la CI GitHub
(`.github/workflows/ci.yml` : compilation, lancement simulateur avec import de
`ci/photos/`, contrôle de la base, `.ipa` non signée). Statut des étapes
lisible sans compte : `https://api.github.com/repos/Vifi31/Phototyh-que_IOS/actions/runs`.

## Architecture

- `Core/` (paquet `PhotothequeCore`) : toute la logique, sans UIKit/SwiftUI.
  `Database` (SQLite3 du SDK ou `CSQLite` sous Linux), `Schema` (user_version),
  `Catalog` + extensions (Keywords, Search, Collections, Duplicates, Backup).
- `App/` : vues SwiftUI, `Library` (@MainActor, seule à toucher au catalogue),
  `ImageTools` (ImageIO : métadonnées, vignettes, dHash), `ImageCache`.

## Conventions (reprises du bureau)

- Jamais de modification ni de suppression d'un original : l'import copie.
- Recherche : texte replié (`TextFold`) dans `search_text`, FTS5 `remove_diacritics 2`,
  saisie jamais injectée brute dans MATCH (`Catalog.ftsQuery`).
- Avant une restauration : sauvegarde de sécurité. Restauration = fusion, rien n'est supprimé.
- Ne jamais présenter une fonction comme terminée sans vérification (tests WSL + CI).
- À chaque livraison : version (`project.yml` MARKETING_VERSION), CHANGELOG, commit (Vifi31).

## Pièges

- `db.lastInsertId` : le lire **avant** `log(...)` (qui insère dans `history`).
- WSL : `swift test --build-system native` (le système par défaut perd LD_LIBRARY_PATH
  à l'édition de liens) ; libncurses6 / libsqlite3-dev extraits sans root dans ~/swiftdeps.
- `SWIFT_VERSION 5.0` pour l'app (concurrence stricte de Swift 6 non activée).
