# Installer Photothèque sur iPhone ou iPad

Photothèque pour iOS demande **iOS 17 ou plus récent**. Apple n'autorise
l'installation que d'apps signées. Trois moyens existent, selon le matériel et
le compte Apple dont vous disposez.

| Moyen | Il faut | Durée de validité | Coût |
| --- | --- | --- | --- |
| **A. Depuis Windows, sans Mac** (chargement latéral) | Un PC Windows, un câble, un identifiant Apple gratuit | **7 jours**, à renouveler | Gratuit |
| **B. Avec un Mac et Xcode** | Un Mac, Xcode, un identifiant Apple gratuit | 7 jours (gratuit) ou 1 an (payant) | Gratuit ou 99 €/an |
| **C. TestFlight ou App Store** | Le programme Apple Developer | 90 jours par version TestFlight ; illimitée sur l'App Store | 99 €/an |

Pour un usage durable, le moyen **C** est conseillé. Les moyens **A** et **B**
avec un compte gratuit conviennent pour essayer.

> **Vos données survivent aux mises à jour.**
>
> - Réinstaller une nouvelle version par-dessus l'ancienne garde le catalogue
>   et les photos. Le dossier de l'app est conservé tant que l'identifiant
>   `fr.vifi31.phototheque` ne change pas.
> - **Supprimer l'app efface ses données.** Avant de la supprimer, faites une
>   *Sauvegarde complète* (Réglages) et copiez-la hors de l'appareil.
> - Un certificat gratuit qui expire n'efface rien : l'app refuse seulement de
>   s'ouvrir jusqu'au renouvellement.

---

## A. Depuis Windows, sans Mac

### 1. Récupérer l'application

Récupérez le fichier **`Phototheque-<version>-non-signee.ipa`** :

- page **Releases** du dépôt
  [Vifi31/Phototyh-que_IOS](https://github.com/Vifi31/Phototyh-que_IOS/releases) ;
- ou onglet **Actions**, dernière exécution réussie, artefact
  « Phototheque-iOS ».

Le fichier `SHA256SUMS` donne son empreinte. Pour la contrôler sous Windows :

```powershell
Get-FileHash .\Phototheque-0.1.0-non-signee.ipa -Algorithm SHA256
```

### 2. Préparer le PC

- Installez **Apple Devices** (Microsoft Store), ou iTunes. Il fournit le
  pilote qui permet au PC de reconnaître l'iPhone.
- Installez un outil de chargement latéral, par exemple **Sideloadly** ou
  **AltStore** pour Windows. Prenez-le **uniquement sur son site officiel**.
- Ces outils demandent votre identifiant Apple. Un identifiant dédié est
  préférable. Ils l'utilisent pour faire signer l'app par Apple à votre nom.

### 3. Préparer l'iPhone

- Branchez l'iPhone, déverrouillez-le, puis touchez *Se fier à cet ordinateur*.
- Activez le **Mode développeur** : *Réglages › Confidentialité et sécurité ›
  Mode développeur*. L'iPhone redémarre.

### 4. Installer

1. Dans l'outil, choisissez le fichier `.ipa` et votre identifiant Apple, puis
   lancez l'installation.
2. Sur l'iPhone, allez dans *Réglages › Général › VPN et gestion de
   l'appareil*. Touchez votre identifiant, puis *Faire confiance*.
3. Ouvrez **Photothèque**.

Avec un identifiant gratuit :

- l'app doit être **re-signée tous les 7 jours** (même outil, même `.ipa`), sans
  perte de données ;
- trois apps de ce type au plus peuvent être installées à la fois.

---

## B. Avec un Mac et Xcode

```bash
git clone https://github.com/Vifi31/Phototyh-que_IOS.git
cd Phototyh-que_IOS
brew install xcodegen
xcodegen generate
open Phototheque.xcodeproj
```

Dans Xcode :

1. Ouvrez la cible *Phototheque*, onglet *Signing & Capabilities*.
2. Choisissez votre *Team*. Un identifiant Apple ajouté dans *Xcode ›
   Settings › Accounts* suffit.
3. Si l'identifiant `fr.vifi31.phototheque` est refusé, changez-le.
4. Branchez l'iPhone, choisissez-le comme destination, puis faites ▶︎ *Run*.

---

## C. TestFlight ou App Store (programme Apple Developer)

1. Ouvrez le projet comme en **B**.
2. Faites *Product › Archive*, puis *Distribute App* et *App Store Connect*.
3. Dans App Store Connect, ajoutez les testeurs TestFlight, ou soumettez l'app
   à la revue.

Les champs déjà prêts :

- l'icône ;
- le nom affiché (Photothèque) ;
- le texte d'autorisation d'accès aux photos ;
- la déclaration de chiffrement : l'app n'utilise que le hachage SHA-256, ce
  qui est exempté.

---

## Après l'installation

- **Importer** : onglet *Photos*, bouton **+**, puis *Depuis Photos* ou *Depuis
  Fichiers*. Photothèque garde une copie de chaque photo. L'original reste
  intact.
- **Retrouver les fichiers** : app *Fichiers › Sur mon iPhone ›
  Photothèque*. Vous y trouvez `Photos/`, `Sauvegardes/`, `Exports/` et
  `catalogue.sqlite`. **Ne modifiez pas ces fichiers à la main.**
- **Sauvegarder** : *Réglages › Sauvegarde complète*, puis le bouton Partager
  de l'archive, vers iCloud Drive, un disque ou un ordinateur.
  - Les sauvegardes iCloud et iTunes de l'iPhone contiennent aussi le dossier
    de l'app.
  - Elles ne remplacent pas une copie que vous contrôlez vous-même.
- **Vérifier une sauvegarde** : balayez-la vers la gauche dans les Réglages,
  puis touchez *Vérifier*.
- **Restaurer** : *Réglages › Restaurer une sauvegarde…*.

## Désinstaller

Avant tout, faites une *Sauvegarde complète* et copiez-la hors de l'iPhone.

Ensuite, appui long sur l'icône, puis *Supprimer l'app*. Cela supprime aussi
le catalogue et les copies des photos.

Les originaux de l'app Photos ne sont pas touchés.
