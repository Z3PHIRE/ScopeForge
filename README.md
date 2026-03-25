# ScopeForge

ScopeForge est un mini-projet PowerShell 7 pour l'automatisation de la reconnaissance web bug bounty strictement limitée au scope fourni. Il orchestre `subfinder`, `gau`, `httpx` et `katana`, applique les exclusions avant probe/crawl, journalise les décisions de filtrage et exporte les résultats en JSON, CSV, Markdown et HTML.

## Fichiers

- `ScopeForge.ps1` : script principal contenant toutes les fonctions et l'entrée `Invoke-BugBountyRecon`
- `Launch-ScopeForge.ps1` : assistant terminal local avec presets, profils, collage direct du scope et résumé final
- `Launch-OpsForgeFromGitHub.ps1` : bootstrap GitHub prévu pour être utilisé via `irm ... | iex`
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

Lanceur interactif local :

```powershell
./Launch-ScopeForge.ps1
```

Bootstrap GitHub après publication du dépôt :

```powershell
irm https://raw.githubusercontent.com/Z3PHIRE/OpsForge/main/Launch-OpsForgeFromGitHub.ps1 | iex
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
./Launch-ScopeForge.ps1
```

```powershell
irm https://raw.githubusercontent.com/Z3PHIRE/OpsForge/main/Launch-OpsForgeFromGitHub.ps1 | iex
```

## Fichier de scope

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

## Sorties générées

Le dossier `output/` contient :

- `logs/main.log`
- `logs/errors.log`
- `logs/exclusions.log`
- `logs/tools.log`
- `raw/subfinder_raw.txt`
- `raw/gau_raw.txt`
- `raw/httpx_raw.jsonl`
- `raw/katana_raw.jsonl`
- `normalized/scope_normalized.json`
- `normalized/hosts_all.json`
- `normalized/hosts_live.json`
- `normalized/live_targets.json`
- `normalized/live_targets.csv`
- `normalized/urls_discovered.json`
- `normalized/urls_discovered.csv`
- `normalized/interesting_urls.json`
- `normalized/interesting_urls.csv`
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
- `-NoInstall` : désactive le bootstrap automatique des outils
- `-Quiet` : réduit la sortie terminal
- `-Verbose` : active les détails supplémentaires
- `-IncludeApex` : inclut l'apex pour les wildcards
- `-RespectSchemeOnly` : force le respect strict du schéma explicite
- `-ExportHtml`, `-ExportCsv`, `-ExportJson` : contrôle des exports de rapport
- `-Resume` : réutilise les sorties normalisées d'une exécution précédente quand le scope est identique

## Lanceur visuel

`Launch-ScopeForge.ps1` ajoute un flux plus simple pour lancer la reconnaissance :

- presets `safe`, `balanced`, `deep`
- profils de cible `webapp`, `api`, `wide-assets`
- choix du mode d'entrée : fichier JSON, collage direct du JSON, assistant guidé
- aperçu du scope normalisé avant exécution
- génération automatique d'un `User-Agent` unique si besoin
- saisie interactive de la profondeur, du dossier de sortie, des threads et du timeout
- récapitulatif avant exécution
- tableau de bord final avec catégories intéressantes, endpoints protégés et exports
- menu post-run pour relire les URLs les plus prometteuses directement dans le terminal

### Ce que changent les presets

- `safe` : privilégie une exécution prudente, avec peu de threads, profondeur réduite et respect strict du schéma.
- `balanced` : profil recommandé pour un programme standard avec mélange de découverte d'assets et crawl raisonnable.
- `deep` : profil plus ambitieux pour les scopes plus larges, avec plus de threads, plus de profondeur et reprise activée.

### Ce que changent les profils de cible

- `webapp` : vise surtout les surfaces login, admin, upload, dashboard et routes applicatives.
- `api` : réduit le crawl profond et favorise la validation d'URLs déjà connues, utile pour Swagger, OpenAPI, GraphQL et REST versionné.
- `wide-assets` : privilégie la couverture de nombreux hôtes, utile pour les programmes contenant plusieurs wildcards ou beaucoup d'assets.

Le bootstrap GitHub `Launch-OpsForgeFromGitHub.ps1` télécharge les fichiers nécessaires dans un dossier temporaire puis exécute le lanceur localement sans `Invoke-Expression` supplémentaire dans le script bootstrap lui-même.

## Hypothèses et limites

- Le script est conçu pour des actions passives ou semi-passives autorisées : parsing de scope, découverte passive, validation HTTP et crawl HTTP(S) strictement borné.
- Les exclusions sont appliquées avant probe et crawl. Pour la découverte passive `subfinder`, le script interroge la racine du wildcard puis filtre immédiatement les résultats avant toute validation active.
- Si `gau` est disponible, le script récupère aussi des URLs historiques, puis les refiltre strictement selon le scope, le wildcard réel, le schéma et les exclusions avant toute validation active.
- Le bootstrap télécharge les dernières releases GitHub officielles dans `output/tools/` sans modifier arbitrairement le système.
- Les options `httpx` et `katana` sont activées en fonction des flags détectés localement. Une version très ancienne d'un outil peut réduire certains enrichissements.
- `katana` est borné par les regex in-scope et le filtrage post-traitement. Si un programme a des contraintes supplémentaires, adapte `Depth`, `Threads`, `TimeoutSeconds` et les exclusions.
- La section `interesting_urls` repose sur des heuristiques de priorisation, pas sur une détection de vulnérabilité.
- `reports/triage.md` est un export de synthèse destiné au triage manuel rapide.

## Aide au triage

La sortie finale met désormais l'accent sur le triage manuel :

- `normalized/interesting_urls.json` et `normalized/interesting_urls.csv` : URLs les plus prometteuses selon des heuristiques de surface
- `reports/triage.md` : résumé Markdown rapide à relire ou partager
- `reports/report.html` : sections dédiées `Interesting Pages`, `Protected Endpoints` et `Spotlight` par catégorie

Les heuristiques mettent en avant par exemple :

- auth/login/signup/session
- admin/dashboard/panel/portal
- swagger/openapi/graphql/api-docs
- upload/import/export/download
- debug/error/logs/trace
- config/env/backup

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
