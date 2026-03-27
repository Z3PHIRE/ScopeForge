# Modeles de fichiers de scope

Ces fichiers servent de base pour creer un scope editable a la main.

Regles importantes :
- Le moteur attend un tableau JSON strict.
- Chaque item doit contenir `type` et `value`.
- `exclusions` doit etre un tableau de chaines.
- Les commentaires JSON ne sont pas supportes de maniere fiable. Garde un JSON simple et utilise les fichiers `.md` pour l'aide.

Modeles disponibles :
- `01-minimal-scope.json` : un seul item simple pour demarrer vite.
- `02-standard-scope.json` : un exemple equilibre avec `Domain`, `Wildcard` et `URL`.
- `03-advanced-scope.json` : un squelette plus riche pour les programmes avec plusieurs surfaces.

Guides associes :
- `01-minimal-scope.help.md`
- `02-standard-scope.help.md`
- `03-advanced-scope.help.md`

Workflow conseille :
1. Lance `./Launch-ScopeForge.ps1`.
2. Choisis `Creer un nouveau fichier de scope a remplir`.
3. Selectionne le modele minimal, standard ou avance.
4. Ouvre le fichier cree dans ton editeur.
5. Remplis le fichier puis sauvegarde-le.
6. Reviens au launcher et choisis `Lancer avec ce fichier de scope`.
7. Reviens au launcher puis choisis `Lancer avec ce fichier de scope`.
8. Apres un premier run reussi, reutilise-le plus tard depuis `Afficher les fichiers de scope deja utilises`.

Comprendre rapidement les types :
- `Domain` : un hostname exact comme `app.example.com`
- `Wildcard` : plusieurs sous-domaines comme `https://*.example.com`
- `URL` : une URL de depart precise comme `https://api.example.com/v1`

Exemple minimal :

```json
[
  {
    "type": "Domain",
    "value": "app.example.com",
    "exclusions": []
  }
]
```

Exemple wildcard avec exclusions :

```json
[
  {
    "type": "Wildcard",
    "value": "https://*.example.com",
    "exclusions": ["dev", "staging"]
  }
]
```

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

Ce qu'il ne faut pas mettre :

```text
{ "type": "Domain", "value": "https://app.example.com", "exclusions": [] }
{ "type": "Wildcard", "value": "https://*.example.com/admin", "exclusions": [] }
{ "type": "CIDR", "value": "10.0.0.0/24", "exclusions": [] }
// commentaire JSON
```
