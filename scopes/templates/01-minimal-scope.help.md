# Modele minimal

Ce modele sert a demarrer avec un seul item de scope simple et exact.

Quand l'utiliser :
- pour un premier test du launcher
- pour une cible avec un seul hostname exact
- pour verifier rapidement que le workflow fonctionne

Champs :
- `type` : obligatoire. Valeurs autorisees : `URL`, `Domain`, `Wildcard`.
- `value` : obligatoire. Ici, un hostname exact comme `app.example.com`.
- `exclusions` : optionnel. Tableau de tokens a exclure.

Workflow simple :
1. Remplace `app.example.com` par le vrai hostname autorise.
2. Laisse `exclusions` vide si tu n'as aucun sous-scope a retirer.
3. Sauvegarde le fichier.
4. Relance le launcher puis choisis `Lancer avec ce fichier de scope`.
