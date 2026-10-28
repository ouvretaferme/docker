# Copie anonymisée des sauvegardes

Une personne qui développe sur Ouvretaferme sans avoir le droit de lire les données des structures
travaille sur une copie anonymisée de la production. Seules la structure 7 et les fiches des
comptes administrateurs y restent en clair. La copie
est fabriquée à la main, à partir d'une sauvegarde déjà extraite par `import-backup.sh`, puis
signée par la personne qui l'exporte et chiffrée pour chaque destinataire.

Les règles d'anonymisation et le choix des structures sont dans le dépôt src
(`internal/data/Anonymize.s.php`, `internal/data/anonymize-structures.txt`, commandes
`data/anonymize:structures` et `data/anonymize`). Les deux scripts de ce dossier ne font que
restaurer, appeler ces commandes, archiver, signer et chiffrer.

## Réglages

Les valeurs par défaut sont dans `commun.sh` et valent pour l'installation Docker. Un poste les
surcharge dans `docker/mysql/anon.conf`, ignoré par git, une affectation bash par ligne, par exemple :

```bash
ANON_OUTPUT="$HOME/Dropbox/SAS OTF/Tech/Backups"
ANON_SIGNER="<empreinte de la clé qui signe les exports>"
ANON_DEV_PASSWORD="un mot de passe de dev"
```

Sans Docker, on y remplace aussi les commandes `ANON_MYSQL`, `ANON_MYSQLDUMP`,
`ANON_DATADIR_FREE`, `ANON_LIME` et `ANON_REDIS_FLUSH`.

## Ajouter sa clé publique

1. Créer une paire de clés gpg si on n'en a pas : `gpg --full-generate-key`.
2. Exporter la clé publique : `gpg --armor --export <empreinte> > prenom.asc`.
3. La transmettre à la personne qui fait les exports, qui la dépose dans
   `docker/mysql/anon/destinataires/`, un fichier par personne. Ce dossier est ignoré par git.

L'export chiffre pour toutes les clés du dossier et refuse de partir s'il est vide. Le manifeste
garde l'empreinte de chaque clé, jamais le nom ni l'adresse qu'elle porte. Retirer une personne,
c'est retirer son fichier : les archives suivantes ne lui sont plus lisibles.

## Signer et faire reconnaître sa signature

L'export signe l'archive avec la clé secrète de la personne qui le lance : celle que désigne
`ANON_SIGNER` dans `anon.conf`, sinon la clé par défaut de son gpg. Sans clé secrète utilisable, il
refuse avant toute restauration, comme si l'épreuve porte deux signatures (un `local-user` du
`gpg.conf` s'ajoute à `ANON_SIGNER`). Le manifeste garde l'empreinte de la clé qui signe, jamais son nom.

Chaque poste qui importe dépose dans `docker/mysql/anon/signataires/` la clé publique de chaque
personne dont il accepte les exports, un fichier par personne, exporté comme ci-dessus. Ce dossier est
ignoré par git. Une archive non signée, dont la signature ne se vérifie pas, ou signée par une clé
absente de ce dossier est refusée, et rien n'est importé. Une clé expirée ou révoquée se retire du
dossier : l'import refuse de partir tant qu'elle y est. L'import demande GnuPG 2.1.10 ou plus récent.

## Lancer l'export

Sur le poste qui reçoit les sauvegardes de production, après `import-backup.sh` :

```bash
./export-anon.sh 2026-10-26
```

La date est celle de la sauvegarde extraite dans `docker/mysql/tmp/`. Chaque fichier restauré doit
être resté tel que l'extraction l'a posé : un fichier plus récent que `<date>-structure.tar.gz`, ou
d'un autre jour que la sauvegarde, a été réécrit depuis (par un dump de la dev par exemple), et
l'export le refuse. Le script vérifie d'abord gpg,
les clés, la signature d'un texte d'épreuve, la place libre et le dossier de dépôt, puis restaure la base commune et les structures
retenues dans des bases `anon_`, les anonymise, et s'arrête si un contrôle refuse. L'archive
`otf-anon-<date>.tar.gpg` et son manifeste sont déposés dans le dossier `ANON_OUTPUT`. gpg peut
demander la phrase secrète de la clé qui signe au début, puis de nouveau à la fin si elle n'est plus
en mémoire. Les bases
`anon_` et les fichiers en clair sont supprimés à la fin, que l'export aboutisse ou non.

Si un export a été tué sans pouvoir faire son ménage, `./export-anon.sh --purger` supprime les bases
`anon_`, les fichiers de travail et le verrou qu'il a laissés.

## Lancer l'import

Sur le poste de la personne destinataire, avec sa clé privée dans son trousseau gpg :

```bash
./import-anon.sh ~/chemin/vers/otf-anon-2026-10-26.tar.gpg
```

Le script déchiffre l'archive, vérifie sa signature contre les clés de `signataires/`, puis chaque
base contre le manifeste. Il remplace `dev_ouvretaferme` et toutes les `dev_structure_*` du poste
(il demande confirmation), puis vide Redis. La copie ne
contient aucune empreinte de mot de passe : le mot de passe de dev (`ANON_DEV_PASSWORD`, demandé
s'il n'est pas réglé) est posé sur le compte de chaque administrateur listé dans
`\user\UserSetting::$admin` du `secret.c.php` du poste. Seuls ces comptes peuvent se connecter.

Le manifeste donne le commit de src qui a fait l'export. Si src a avancé depuis, les migrations de la
base commune arrivées entre les deux se jouent après l'import.
