# Modele standard

Ce modele combine les trois formes de scope les plus utiles : `Domain`, `Wildcard` et `URL`.

Quand l'utiliser :
- pour un programme web classique
- quand tu connais un ou deux hosts exacts
- quand tu veux aussi autoriser un wildcard et quelques URL de depart utiles

Champs :
- `type` : obligatoire. Utilise `Domain` pour un host exact, `Wildcard` pour des sous-domaines, `URL` pour une URL de depart precise.
- `value` : obligatoire. Respecte le format exact :
  - `Domain` : `app.example.com`
  - `Wildcard` : `https://*.example.com` ou `*.example.com`
  - `URL` : `https://app.example.com/api/v1`
- `exclusions` : optionnel. Tableau de chaines simples comme `["dev", "staging"]`.

Workflow simple :
1. Garde uniquement les items autorises par le programme.
2. Ajuste les exclusions avec des tokens specifiques.
3. Sauvegarde le fichier.
4. Reviens au launcher puis choisis `Lancer avec ce fichier de scope`.
5. Le resultat sera ecrit dans le dossier de sortie indique par le launcher.
