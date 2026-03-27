# Modele avance

Ce modele sert a preparer un scope plus riche avec plusieurs hosts exacts, plusieurs URL de depart et un wildcard complete par des exclusions.

Quand l'utiliser :
- pour un programme avec plusieurs applications
- pour separer clairement web, API et points d'entree utiles
- quand tu veux un fichier plus complet avant le premier run

Champs :
- `type` : obligatoire. Toujours `URL`, `Domain` ou `Wildcard`.
- `value` : obligatoire. Doit respecter le format attendu par le parseur.
- `exclusions` : optionnel. Tableau de chaines; evite les tokens trop larges qui excluent trop de choses.

Points d'attention :
- `*.example.com` n'inclut pas automatiquement `example.com`. Ajoute un item `Domain` si besoin.
- Les commentaires JSON ne sont pas supportes de maniere fiable. Garde un JSON strict.
- Les champs supplementaires dans le JSON n'ont pas d'effet. N'ajoute pas de metadonnees dans le scope.

Workflow simple :
1. Remplace tous les exemples par les vraies valeurs autorisees.
2. Supprime les lignes inutiles plutot que de les commenter.
3. Sauvegarde le fichier.
4. Reviens au launcher puis choisis `Lancer avec ce fichier de scope`.
5. Apres un premier run reussi, tu pourras aussi le retrouver dans `Afficher les fichiers de scope deja utilises`.
