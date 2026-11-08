# Photothèque et iOS : compatibilité

Ce document fait l'état des lieux de la compatibilité avec iOS. Il compare la
Photothèque de bureau (version 0.30.0, dépôt
[Vifi31/Phototheque](https://github.com/Vifi31/Phototheque)) avec la version
iOS de ce dépôt. Il a été établi le 8 novembre 2026.

## 1. La version de bureau ne peut pas fonctionner sur iPhone ou iPad

Les causes sont techniques, sans contournement acceptable.

| Brique de bureau | Situation sur iOS |
| --- | --- |
| **Node.js 24** (moteur de l'application) | iOS n'exécute pas Node.js. Apple interdit aux apps de télécharger et lancer un autre moteur de code. Le projet « nodejs-mobile » est figé en Node 18, qui n'a pas `node:sqlite`. |
| **`node:sqlite`** (base) | Absent sur iOS, mais SQLite est fourni par le système. → La base reste SQLite, utilisée directement par Swift. |
| **sharp / libvips** (images) | Binaires natifs compilés pour Windows, macOS et Linux, jamais pour iOS. → Remplacés par **ImageIO** (vignettes, métadonnées) et **CryptoKit** (SHA-256), fournis par iOS. |
| **exifr** (EXIF, IPTC, XMP) | → Remplacé par ImageIO, qui lit EXIF, TIFF, GPS et IPTC. |
| **Serveur web local + interface dans le navigateur** | Une app iOS ne peut pas laisser tourner un serveur en arrière-plan. → L'interface est réécrite en **SwiftUI**. |
| **Indexation sans copie de dossiers quelconques** | Le bac à sable d'iOS interdit de parcourir le disque. → **Import par copie** depuis l'app Photos (sélecteur système) ou depuis Fichiers. Les originaux ne sont ni modifiés ni supprimés. |
| **Installateur IExpress / PowerShell, signature Ed25519** | Une app iOS s'installe par Xcode, TestFlight, l'App Store, ou par chargement latéral avec un identifiant Apple. Elle est signée par Apple. Voir [INSTALLATION-IOS.md](INSTALLATION-IOS.md). |
| **« Ouvrir dans… » un logiciel externe** | → Feuille de partage d'iOS. |
| **Guide PDF généré par Edge** | Sans objet. |

## 2. L'interface web de bureau ouverte dans Safari sur iPhone

L'interface a été testée à la taille d'un iPhone (375 × 812 points) :

- la page s'affiche sans défilement horizontal ;
- la balise `viewport` est présente ;
- la grille et les filtres s'empilent en colonne.

Elle reste pourtant inutilisable sur iPhone :

- **inaccessible depuis l'iPhone** : le serveur n'écoute que sur 127.0.0.1, l'ordinateur lui-même, par sécurité ;
- **gestes souris sans équivalent tactile** :
  - glisser-déposer HTML5 entre les cadres d'album ;
  - zoom au double-clic et à la molette ;
  - raccourcis clavier de classement (0-9, I, K, Z) ;
- **chemins de dossiers tapés à la main** pour l'indexation et l'import ;
- **écran trop petit** : la barre latérale et la barre du haut prennent la moitié de l'écran.

C'est pourquoi une **application iOS autonome** a été écrite, à la demande de
l'utilisateur. Elle ne dépend pas d'un ordinateur.

## 3. Ce que fait la version iOS 0.1.0

Le cœur (`Core/`, Swift pur + SQLite) reprend les règles de la version de bureau :

- import sans jamais toucher à l'original ;
- doublons exacts par SHA-256 ;
- noms uniques ;
- recherche insensible à la casse et aux accents (FTS5 `remove_diacritics 2`, avec repli `LIKE`) ;
- mots-clés hiérarchiques avec synonymes ;
- sauvegarde de sécurité avant toute restauration.

Les tableaux ci-dessous classent les domaines de la version de bureau selon
leur état dans la version iOS.

### Présents

| Domaine (bureau) | iOS 0.1.0 |
| --- | --- |
| Catalogue SQLite, migrations, intégrité | Présent : schéma versionné (`user_version`), contrôle `integrity_check` et clés étrangères. |
| Import, doublons exacts, noms uniques | Présent : depuis Photos (fichier d'origine, `preferredItemEncoding: .current`) et Fichiers ; re-sélection d'une photo déjà importée reconnue. |
| Vignettes en cache régénérable | Présent : `Library/Caches/Vignettes`, vidable depuis les Réglages. |
| Métadonnées EXIF / IPTC / GPS à l'import | Présent : date (avec décalage horaire EXIF), appareil, objectif, GPS, titre, légende, mots-clés, note IPTC. |
| Notes, étiquettes de couleur | Présent : mêmes numéros d'étiquette que sur le bureau. |
| Mots-clés hiérarchiques, synonymes | Présent : création par chemin « Lieux/France/Paris », déplacement (cycles refusés), fusion, suppression (les enfants remontent). |
| Doublons de vocabulaire | Présent : regroupés, fusion en un geste. |
| Recherche plein texte et critères | Présent : texte, année, note, étiquette, mot-clé (avec ou sans sous-mots-clés), appareil, GPS, manques (mot-clé, titre, lieu, date), tri. |
| Collections et recherches enregistrées | Présent : la recherche enregistrée se recalcule à chaque ouverture. |
| Photos semblables (dHash) | Présent : tolérance réglable, chaîne de ressemblance, jamais de suppression automatique. |
| Visionneuse | Présent : balayage, zoom au pincement (8×) et au double toucher, fiche complète, lien vers Plans. |
| Sauvegarde / vérification / restauration | Présent : archive ZIP du catalogue seul ou complète, avec contrôle CRC + SHA-256 de chaque photo. La restauration fusionne, ne supprime rien et fait d'abord une sauvegarde de sécurité. |
| Catalogue CSV | Présent : séparateur « ; », UTF-8 avec BOM. |
| Journal | Présent. |
| Partage, export de l'original | Présent : feuille de partage (Enregistrer dans Photos, AirDrop, Mail…). |

### Absents de la version 0.1.0

| Domaine (bureau) | Ce qui manque |
| --- | --- |
| Tableau de bord | Seulement les chiffres clés et les manques, dans les Réglages. Pas de graphiques. |
| Retouche non destructive | Absente. |
| Exports avec redimensionnement, filigrane ou profils | Absents. |
| Albums, planches-contact, catalogues, portfolios, rapports PDF | Absents. |
| Variantes, référence de groupe | Absentes. |
| Supports de stockage, indexation sans copie | Impossibles sous iOS (bac à sable). |
| Sauvegardes programmées, destinations multiples, chiffrement | Absents. La copie hors de l'appareil passe par le bouton Partager (iCloud Drive, ordinateur, disque). |
| Verrouillage par mot de passe | Absent. Le code de l'iPhone et Face ID protègent l'appareil. |
| Assistant IA | Absent. |
| Écriture d'annexes XMP | Absente. |
| Échange de catalogue avec la version de bureau | Absent : les formats de sauvegarde diffèrent. Le CSV est lisible des deux côtés. |

## 4. Matériel et versions

- **Système** : iOS 17 ou plus récent ; même programme pour iPhone et iPad.
- **Formats** : ceux que lit iOS, c'est-à-dire JPEG, HEIC/HEIF, PNG, TIFF, GIF, et les RAW pris en charge par ImageIO, comme le DNG et la plupart des boîtiers récents.
- **Espace** : chaque photo importée est copiée. Le volume est indiqué dans les Réglages.

## 5. Ce qui a été vérifié, et comment

| Vérification | Moyen | Résultat |
| --- | --- | --- |
| Cœur Swift | `scripts/test-wsl.sh` sous Windows + WSL (Ubuntu 26.04, Swift 6.4.2). Testé avec l'en-tête SQLite du système et avec les déclarations intégrées. | 25 tests réussis. |
| Cœur Swift sur la plateforme Apple | CI GitHub (macOS : CryptoKit, SQLite du système). | Voir la dernière exécution de la CI. |
| Compilation de l'app iOS | CI GitHub : Xcode, compilation simulateur et iPhone. | Voir la dernière exécution de la CI. |
| Lancement réel | CI GitHub, simulateur iPhone : import automatique de 3 photos d'essai, puis contrôle dans la base (métadonnées, empreintes, vignettes) et contrôle que l'app tourne encore. | Voir la dernière exécution de la CI. |
| Sur un vrai iPhone | — | **Non essayé** : aucun appareil n'est relié au poste de développement. |

L'interface SwiftUI ne se compile pas sous Linux. Elle n'est vérifiée que par
la CI macOS.
