# ScopeForge

ScopeForge est un mini-projet PowerShell 7 pour l'automatisation de la reconnaissance web bug bounty strictement limitée au scope fourni. Il orchestre `subfinder`, `gau`, `waybackurls`, `httpx`, `katana` et `hakrawler`, applique les exclusions avant probe/crawl, journalise les décisions de filtrage et exporte les résultats en JSON, CSV, Markdown et HTML.

## Fichiers

- `ScopeForge.ps1` : script principal contenant toutes les fonctions et l'entrée `Invoke-BugBountyRecon`
- `Launch-ScopeForge.ps1` : launcher principal, désormais orienté mode documents
- `Launch-ScopeForge.cmd` : lanceur Windows double-clic
- `Launch-ScopeForgeFromGitHub.ps1` : bootstrap GitHub autonome prévu pour être utilisé via `irm ... | iex`
- `examples/scope.json` : exemple de scope d'entrée

## Fonction principale

```powershell
Invoke-BugBountyRecon -ScopeFile ./examples/scope.json -Depth 3 -OutputDir ./output -ProgramName "khealth" -UniqueUserAgent "researcher-12345"
```

Le script peut être :

- exécuté directement
- dot-sourcé localement
- chargé à distance dans un bootstrap contrôlé, sans `Invoke-Expression` sur des entrées libres

## Utilisation rapide

```powershell
. ./ScopeForge.ps1
Invoke-BugBountyRecon -ScopeFile ./examples/scope.json -Depth 3 -OutputDir ./output -ProgramName "khealth" -UniqueUserAgent "researcher-12345"
```

Exécution directe :

```powershell
./ScopeForge.ps1 -ScopeFile ./examples/scope.json -Depth 3 -OutputDir ./output -ProgramName "khealth" -UniqueUserAgent "researcher-12345"
```

Lanceur local en mode documents :

```powershell
./Launch-ScopeForge.ps1
```

Sous Windows, tu peux aussi simplement double-cliquer :

```text
Launch-ScopeForge.cmd
```

Bootstrap GitHub après publication du dépôt :

```powershell
irm https://raw.githubusercontent.com/Z3PHIRE/ScopeForge/main/Launch-ScopeForgeFromGitHub.ps1 | iex
```

## Exemples de commandes

```powershell
./ScopeForge.ps1 -ScopeFile ./examples/scope.json -Depth 3 -OutputDir ./output -ProgramName "khealth" -UniqueUserAgent "researcher-12345"
```

```powershell
./ScopeForge.ps1 -ScopeFile ./examples/scope.json -Depth 2 -OutputDir ./output_https_only -ProgramName "khealth" -UniqueUserAgent "researcher-12345" -RespectSchemeOnly -Verbose
```

```powershell
./ScopeForge.ps1 -ScopeFile ./examples/scope.json -Depth 4 -OutputDir ./output_resume -ProgramName "khealth" -UniqueUserAgent "researcher-12345" -Resume -NoInstall -Quiet
```

```powershell
./ScopeForge.ps1 -ScopeFile ./examples/scope.json -Depth 2 -OutputDir ./output_api -ProgramName "khealth" -UniqueUserAgent "researcher-12345" -EnableHakrawler:$false -EnableWaybackUrls:$true
```

```powershell
./Launch-ScopeForge.ps1
```

```text
Launch-ScopeForge.cmd
```

```powershell
irm https://raw.githubusercontent.com/Z3PHIRE/ScopeForge/main/Launch-ScopeForgeFromGitHub.ps1 | iex
```

## Fichier de scope

Le moteur attend un tableau JSON strict. Chaque item contient :

- `type` : `URL`, `Domain` ou `Wildcard`
- `value` : la valeur exacte correspondant au type choisi
- `exclusions` : un tableau de tokens a exclure, souvent vide

Pour une compatibilite maximale, garde un JSON sans commentaires.

Exemple complet :

```json
[
  {
    "type": "URL",
    "value": "http://clinical-quality.khealth.com/api/v1",
    "exclusions": []
  },
  {
    "type": "Wildcard",
    "value": "https://*.khealth.com",
    "exclusions": ["dev", "stg", "staging"]
  },
  {
    "type": "Domain",
    "value": "www.kpharmacyllc.com",
    "exclusions": []
  }
]
```

Les modeles aides vivent aussi dans `scopes/templates/README.md`, avec un guide Markdown associe a chaque template.

### Comprendre les types de scope

- `Domain` : un hostname exact comme `app.example.com`
  Utilise-le quand le programme autorise un site ou sous-domaine precis.
- `Wildcard` : une famille de sous-domaines comme `https://*.example.com` ou `*.example.com`
  Utilise-le quand le programme autorise plusieurs sous-domaines sous une meme racine.
- `URL` : une URL de depart precise comme `https://api.example.com/v1`
  Utilise-la quand le programme mentionne explicitement une URL de depart, un portail ou une zone limitee a un chemin.

### Quand utiliser Domain / Wildcard / URL

- Choisis `Domain` si tu veux rester sur un host exact sans englober ses voisins.
- Choisis `Wildcard` si le scope officiel parle d'un ensemble de sous-domaines.
- Choisis `URL` si tu as besoin d'un point de depart tres precis ou d'une zone applicative clairement delimitee.
- Tu peux melanger les trois types dans un seul tableau JSON si le programme contient plusieurs cibles heterogenes.

### Construire un scope avec plusieurs cibles

Le fichier `01-scope.json` reste un seul tableau JSON. Tu peux donc combiner :

- plusieurs `Domain`
- un ou plusieurs `Wildcard`
- une ou plusieurs `URL`

Exemple mixte :

```json
[
  {
    "type": "Domain",
    "value": "app.example.com",
    "exclusions": []
  },
  {
    "type": "Wildcard",
    "value": "https://*.example.com",
    "exclusions": ["dev", "staging"]
  },
  {
    "type": "URL",
    "value": "https://api.example.com/v1",
    "exclusions": []
  }
]
```

### Exemples simples et exemples mixtes

Exemple minimal avec un seul `Domain` :

```json
[
  {
    "type": "Domain",
    "value": "app.example.com",
    "exclusions": []
  }
]
```

Exemple `Wildcard` avec exclusions :

```json
[
  {
    "type": "Wildcard",
    "value": "https://*.example.com",
    "exclusions": ["dev", "qa", "staging"]
  }
]
```

Exemple mixte `URL` + `Wildcard` + `Domain` :

```json
[
  {
    "type": "URL",
    "value": "https://portal.example.com/login",
    "exclusions": []
  },
  {
    "type": "Wildcard",
    "value": "https://*.example.com",
    "exclusions": ["dev", "sandbox"]
  },
  {
    "type": "Domain",
    "value": "api.example.net",
    "exclusions": []
  }
]
```

Exemples de choses a ne PAS mettre dans le scope :

```text
{ "type": "Domain", "value": "https://app.example.com", "exclusions": [] }
{ "type": "Wildcard", "value": "https://*.example.com/admin", "exclusions": [] }
{ "type": "CIDR", "value": "10.0.0.0/24", "exclusions": [] }
// commentaire JSON
```

Pourquoi :

- `Domain` ne doit pas contenir de scheme ni de chemin
- `Wildcard` ne doit pas contenir de chemin
- seuls `URL`, `Domain` et `Wildcard` sont acceptes
- garde un JSON strict sans commentaires pour une compatibilite maximale

### Comment relire son scope avant lancement

Avant de lancer :

1. verifie que le fichier est bien un tableau JSON
2. verifie que chaque item contient `type`, `value` et `exclusions`
3. verifie que chaque `Domain` est un hostname exact
4. verifie que chaque `Wildcard` est du type `*.example.com` ou `https://*.example.com`
5. verifie que chaque `URL` est absolue en `http://` ou `https://`
6. relis les exclusions pour eviter les tokens trop larges
7. supprime tout exemple qui ne correspond pas au scope reel

## Sorties générées

Le dossier `output/` contient :

- `logs/main.log`
- `logs/errors.log`
- `logs/exclusions.log`
- `logs/tools.log`
- `raw/subfinder_raw.txt`
- `raw/gau_raw.txt`
- `raw/waybackurls_raw.txt`
- `raw/httpx_raw.jsonl`
- `raw/katana_raw.jsonl`
- `raw/hakrawler_raw.txt`
- `normalized/scope_normalized.json`
- `normalized/hosts_all.json`
- `normalized/hosts_all.csv`
- `normalized/hosts_live.json`
- `normalized/live_targets.json`
- `normalized/live_targets.csv`
- `normalized/urls_discovered.json`
- `normalized/urls_discovered.csv`
- `normalized/interesting_urls.json`
- `normalized/interesting_urls.csv`
- `normalized/interesting_families.json`
- `normalized/endpoints_unique.txt`
- `reports/summary.json`
- `reports/summary.csv`
- `reports/report.html`
- `reports/triage.md`

## Paramètres principaux

- `-ScopeFile` : chemin du JSON de scope
- `-Depth` : profondeur de crawl `katana`
- `-OutputDir` : dossier de sortie
- `-ProgramName` : nom du programme ou de la cible dans les exports
- `-UniqueUserAgent` : User-Agent global personnalisé
- `-Threads` : niveau de parallélisme transmis à `httpx` et `katana`
- `-TimeoutSeconds` : timeout des outils externes
- `-EnableGau` : active ou désactive `gau`
- `-EnableWaybackUrls` : active ou désactive `waybackurls`
- `-EnableHakrawler` : active ou désactive `hakrawler`
- `-NoInstall` : désactive le bootstrap automatique des outils
- `-Quiet` : réduit la sortie terminal
- `-Verbose` : active les détails supplémentaires
- `-IncludeApex` : inclut l'apex pour les wildcards
- `-RespectSchemeOnly` : force le respect strict du schéma explicite
- `-ExportHtml`, `-ExportCsv`, `-ExportJson` : contrôle des exports de rapport
- `-Resume` : réutilise les sorties normalisées d'une exécution précédente quand le scope est identique
- Dans `02-run-settings.json`, les champs booléens doivent être des valeurs JSON `true` / `false` sans guillemets.

## Lanceur visuel

`Launch-ScopeForge.ps1` ouvre maintenant par défaut un flux base sur des documents a remplir :

- creation d'un dossier de session avec :
  - `00-START-HERE.txt`
  - `01-scope.json`
  - `02-run-settings.json`
- ouverture automatique de ces documents dans un editeur local
- validation automatique apres sauvegarde et fermeture
- demarrage automatique du run quand les fichiers sont valides
- ouverture automatique du rapport HTML a la fin par defaut
- tableau de bord terminal compact avec familles, priorites, categories interessantes, endpoints proteges et exports
- aucune dependance visuelle distante : le mode documents repose uniquement sur des fichiers locaux et l'editeur de la machine

Le but est simple :

1. le script ouvre les documents
2. tu remplis `01-scope.json`
3. tu ajustes `02-run-settings.json`
4. tu sauvegardes, tu fermes
5. ScopeForge lance la collecte et ouvre le rapport final

Si tu preferes l'ancien assistant en console, tu peux toujours forcer ce mode :

```powershell
./Launch-ScopeForge.ps1 -ConsoleMode
```

### Creer et remplir un fichier de scope

Le launcher sait maintenant t'aider a travailler "comme avant" avec de vrais fichiers a editer manuellement :

1. lance `./Launch-ScopeForge.ps1`
2. choisis `Creer un nouveau fichier de scope a remplir`
3. choisis un modele `minimal`, `standard` ou `avance`
4. choisis le dossier cible, en general `scopes/incoming`
5. accepte l'ouverture automatique du fichier dans ton editeur
6. remplis le JSON, sauvegarde, puis reviens au launcher
7. choisis `Lancer avec ce fichier de scope`
8. lis le resume avant lancement, puis confirme si tout est correct

Apres creation, le launcher indique clairement :

- le nom du fichier cree
- son chemin complet
- s'il a ete ouvert ou non
- quel guide explique comment le remplir
- dans quel dossier le prochain output sera ecrit
- quelle est la prochaine action attendue

### Organisation des fichiers

Les fichiers utiles sont separes par role :

- `scopes/incoming` : nouveaux fichiers de scope a verifier ou completer
- `scopes/active` : fichiers de scope deja prets a etre reutilises
- `scopes/archived` : anciens scopes que tu veux garder sans les laisser actifs
- `scopes/templates` : modeles JSON et guides Markdown pour les remplir
- `state/recent-scopes.json` : index des derniers fichiers de scope utilises
- `output/` ou le `outputDir` choisi : resultats d'un run termine

Le launcher continue aussi a creer un workspace de session pour le mode documents avec :

- `00-START-HERE.txt`
- `01-scope.json`
- `02-run-settings.json`

Si tu pars d'un fichier gere dans `scopes/active` ou `scopes/incoming`, le launcher peut l'ouvrir directement au lieu de le recopier dans un dossier temporaire.

### Choisir entre modele minimal, standard et avance

- `01-minimal-scope.json` : un seul item `Domain`. C'est le plus simple pour verifier ton workflow.
- `02-standard-scope.json` : un exemple equilibre avec `Domain`, `Wildcard` et `URL`. C'est le bon choix par defaut.
- `03-advanced-scope.json` : un squelette plus complet pour plusieurs hosts, URL de depart et exclusions.

Les guides associes sont :

- `scopes/templates/01-minimal-scope.help.md`
- `scopes/templates/02-standard-scope.help.md`
- `scopes/templates/03-advanced-scope.help.md`

Le guide general est :

- `scopes/templates/README.md`

### Comprendre 02-run-settings.json

Le fichier `02-run-settings.json` n'ajoute pas de fonctionnalite magique. Il sert seulement a regler le run.

Reglages qui affectent surtout la vitesse :

- `depth`
- `threads`
- `timeoutSeconds`
- `resume`

Reglages qui affectent surtout la couverture :

- `enableGau`
- `enableWaybackUrls`
- `enableHakrawler`
- `includeApex`
- `respectSchemeOnly`

Reglages qui augmentent surtout le volume de sortie :

- `depth`
- `enableGau`
- `enableWaybackUrls`
- `enableHakrawler`

Reglages prudents par defaut :

- `preset = balanced`
- `profile = webapp`
- `includeApex = false`
- `respectSchemeOnly = false`
- `resume = false`

Les champs booleens doivent rester en JSON natif `true` / `false` sans guillemets.

Dictionnaires / wordlists :

- statut actuel : non prouve / non pris en charge dans cette version
- aucun champ dedie n'est documente ni valide aujourd'hui
- n'ajoute pas de cle custom dans `02-run-settings.json`
- le resume avant lancement rappelle explicitement ce statut

### Resume avant lancement

Juste avant le run, le launcher affiche un resume lisible avec :

- le nombre d'entrees `Domain`
- le nombre d'entrees `Wildcard`
- le nombre d'entrees `URL`
- le nombre total d'exclusions
- le dossier de sortie selectionne
- l'etat de `resume`
- les sources optionnelles actives
- une duree approximative de type `Tres court` a `Tres long`

Cette duree reste indicative. Elle sert seulement a aider l'utilisateur a juger si le run sera plutot leger ou plus long.

### Retrouver les anciens fichiers deja utilises

Apres un run lance avec succes depuis le launcher, le fichier de scope est memorise dans `state/recent-scopes.json` avec :

- `display_name`
- `scope_path`
- `last_output_dir`
- `last_used_utc`
- `exists`
- `note`

Le menu `Afficher les fichiers de scope deja utilises` montre :

- si le fichier existe encore : `OK`
- si le fichier a ete deplace ou supprime : `INTROUVABLE`
- le dernier dossier de sortie connu, meme si le fichier n'existe plus

Cela permet de relancer plus tard le meme fichier de scope, ou au minimum de retrouver le dernier dossier de sortie associe.

### Sessions sauvegardees

Le launcher conserve aussi des sessions reutilisables dans `sessions/`.

Une session sauvegardee garde au minimum :

- le nom de session
- le fichier `00-START-HERE.txt`
- le `01-scope.json` associe
- le `02-run-settings.json` associe
- le dernier dossier de sortie connu
- le dernier dossier de logs connu
- le niveau de verbosite choisi

Le menu `Gerer les sessions enregistrees` permet ensuite de :

- rouvrir une session
- revoir ou modifier ses fichiers
- la relancer plus tard
- la dupliquer dans un nouveau dossier
- la supprimer avec confirmation
- ouvrir le dossier de session, le dernier dossier de sortie ou le dernier dossier de logs

Le launcher retient aussi la derniere session selectionnee si elle existe encore au prochain demarrage.

### Logs et niveaux de verbosite

Avant le lancement, le launcher laisse choisir un mode de logs en francais clair :

- `disabled` : pas de journal launcher supplementaire
- `normal` : journal utile pour suivre le run sans bruit excessif
- `verbose` : plus de details sur les choix du launcher et les validations
- `debug` : verbosite elevee pour le diagnostic et le depannage

Les logs du launcher et les metadonnees de session sont ranges dans le dossier de logs de la session. Le resume avant lancement affiche toujours :

- le dossier de logs planifie
- le niveau de verbosite choisi
- le dossier de sortie

En mode `debug`, le launcher journalise davantage :

- les chemins retenus
- les verifications effectuees
- le flux de creation de session
- le passage des parametres vers le moteur
- les erreurs et avertissements captures

Le mode `debug` reste optionnel pour eviter de surcharger les runs standards.

### Relancer, modifier ou supprimer une session

Workflow conseille pour reprendre un ancien travail :

1. lance `./Launch-ScopeForge.ps1`
2. ouvre `Gerer les sessions enregistrees`
3. selectionne la session voulue
4. choisis ensuite l'action utile :
   - relancer
   - modifier les fichiers
   - ouvrir le dossier
   - dupliquer
   - supprimer avec confirmation

La suppression n'est jamais silencieuse. Si tu supprimes une session, le launcher demande une confirmation explicite avant d'effacer son dossier.

### Lire le resume avant lancement

Le panneau de resume avant lancement sert de check-list rapide. Il rappelle en un seul endroit :

- la session active
- le fichier de scope actif
- le `02-run-settings.json` actif
- le dossier de sortie
- le dossier de logs
- le mode de logs
- la composition du scope
- les sources actives
- `resume` active ou non
- une estimation de duree approximative

Lis ce panneau juste avant de confirmer le run. Si une valeur te surprend, reviens en arriere et corrige les fichiers avant de lancer.

### Limites connues de l'interface

Cette interface reste volontairement simple et robuste :

- le mode principal est un mode console enrichi, pas un vrai GUI
- le mode visuel optionnel depend de `Out-GridView` sous Windows quand il est disponible
- il n'y a pas de vrai hover souris ni de boutons cliquables integres dans une console PowerShell classique
- les logs et chemins sont gardes visibles, mais le launcher ne remplace pas un outil de suivi de session complet
- les dictionnaires / wordlists custom ne sont pas pris en charge tant qu'un support reel n'est pas prouve dans le moteur

### Exemples de workflow

Workflow simple "comme avant" :

1. creer un fichier
2. l'ouvrir
3. le remplir manuellement
4. le sauvegarder
5. lancer le run
6. le relancer plus tard depuis les scopes recents

Si une validation echoue, le launcher rouvre les documents pour correction au lieu de lancer un run invalide.

### Ce que changent les presets

- `safe` : privilégie une exécution prudente, avec peu de threads, profondeur réduite et respect strict du schéma.
- `balanced` : profil recommandé pour un programme standard avec mélange de découverte d'assets et crawl raisonnable.
- `deep` : profil plus ambitieux pour les scopes plus larges, avec plus de threads, plus de profondeur et reprise activée.

### Ce que changent les profils de cible

- `webapp` : vise surtout les surfaces login, admin, upload, dashboard et routes applicatives. Active `gau`, `waybackurls` et `hakrawler`.
- `api` : réduit le crawl profond et favorise la validation d'URLs déjà connues, utile pour Swagger, OpenAPI, GraphQL et REST versionné. Active `gau` et `waybackurls`, mais laisse `hakrawler` désactivé par défaut.
- `wide-assets` : privilégie la couverture de nombreux hôtes, utile pour les programmes contenant plusieurs wildcards ou beaucoup d'assets. Active `gau` et `waybackurls`, garde `hakrawler` désactivé par défaut pour limiter le coût par host.

Le bootstrap GitHub `Launch-ScopeForgeFromGitHub.ps1` telecharge les fichiers necessaires, les deblocque sous Windows si besoin, puis relance `Launch-ScopeForge.ps1` via `pwsh -ExecutionPolicy Bypass` pour eviter les erreurs d'`ExecutionPolicy` rencontrees depuis Windows PowerShell.

Les anciens fichiers `Launch-OpsForge*` peuvent rester comme compatibilite transitoire, mais le workflow recommande est maintenant 100% `ScopeForge`.

## Hypothèses et limites

- Le script est conçu pour des actions passives ou semi-passives autorisées : parsing de scope, découverte passive, validation HTTP et crawl HTTP(S) strictement borné.
- Les exclusions sont appliquées avant probe et crawl. Pour la découverte passive `subfinder`, le script interroge la racine du wildcard puis filtre immédiatement les résultats avant toute validation active.
- Si `gau` et/ou `waybackurls` sont disponibles, le script récupère aussi des URLs historiques, puis les refiltre strictement selon le scope, le wildcard réel, le schéma et les exclusions avant toute validation active.
- Si `hakrawler` est disponible, il est utilisé en passe complémentaire après `katana`, toujours refiltré par le moteur in-scope/exclusions avant fusion finale.
- Le bootstrap télécharge les dernières releases GitHub officielles dans `output/tools/` sans modifier arbitrairement le système.
- Les options `httpx` et `katana` sont activées en fonction des flags détectés localement. Une version très ancienne d'un outil peut réduire certains enrichissements.
- `katana` est borné par les regex in-scope et le filtrage post-traitement. Si un programme a des contraintes supplémentaires, adapte `Depth`, `Threads`, `TimeoutSeconds` et les exclusions.
- La section `interesting_urls` repose sur des heuristiques de priorisation, pas sur une détection de vulnérabilité.
- `reports/triage.md` et `normalized/interesting_families.json` sont pensés pour le triage manuel rapide par familles et priorités.

## Aide au triage

La sortie finale met désormais l'accent sur le triage manuel :

- `normalized/interesting_urls.json` et `normalized/interesting_urls.csv` : URLs les plus prometteuses selon des heuristiques de surface
- `normalized/interesting_families.json` : regroupement par famille principale avec score max, priorités et exemples d'URLs
- `reports/triage.md` : résumé Markdown rapide à relire ou partager
- `reports/report.html` : sections dédiées `Interesting Families`, `Interesting Pages`, `Protected Endpoints` et `Spotlight` par famille

Les heuristiques mettent en avant par exemple :

- auth/login/signup/session
- admin/dashboard/panel/portal
- swagger/openapi/graphql/api-docs
- upload/import/export/download
- debug/error/logs/trace
- config/env/backup

Le triage calcule ensuite pour chaque URL :

- une `PrimaryFamily` pour prioriser le type de surface à revoir
- une `Priority` (`Critical`, `High`, `Medium`, `Low`) basée sur le score heuristique
- une liste de `Categories` et `Reasons` pour comprendre pourquoi la page remonte

## Comment adapter les filtres d'exclusion

Les exclusions sont des sous-chaînes insensibles à la casse. Si un item contient :

```json
"exclusions": ["dev", "stg", "staging"]
```

alors tout hostname, URL ou chemin contenant ces chaînes est rejeté et journalisé dans `logs/exclusions.log`.

Exemples :

- `https://dev.khealth.com`
- `https://api.khealth.com/staging/users`
- `https://foo.khealth.com/v1/stg/report`

Pour durcir les filtres, ajoute d'autres tokens par item de scope, par exemple :

```json
"exclusions": ["dev", "stg", "staging", "internal", "qa", "sandbox"]
```

## Comment ajouter d'autres outils plus tard

Le script est structuré pour être étendu proprement :

- ajoute une fonction dédiée, par exemple `Invoke-GauCollection`
- vérifie l'outil dans `Ensure-ReconTools`
- exécute l'outil via `Invoke-ExternalCommand`
- normalise ses résultats avant `Merge-ReconResults`
- ajoute ses exports dans `Export-ReconReport` si nécessaire

Les intégrations actuelles fournissent déjà trois modèles utiles :

- `gau` pour l'historique d'URLs avec option sous-domaines
- `waybackurls` pour une seconde source d'archives web
- `hakrawler` pour un crawl complémentaire léger fusionné ensuite avec `katana`

L'approche recommandée est de conserver un pipeline explicite :

1. génération de cibles
2. validation in-scope
3. collecte additionnelle
4. fusion normalisée
5. export

## Smoke test local

```powershell
pwsh -NoLogo -NoProfile -Command ". ./ScopeForge.ps1; Get-Command Invoke-BugBountyRecon"
```

```powershell
pwsh -NoLogo -NoProfile -Command ". ./Launch-ScopeForge.ps1; Get-Command Start-ScopeForgeLauncher"
```

## Rappel sécurité

Ce projet est prévu pour du bug bounty autorisé uniquement. Il n'effectue ni bruteforce, ni exploitation, ni bypass, ni action destructive.
