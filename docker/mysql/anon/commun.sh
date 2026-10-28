# shellcheck shell=bash
# Réglages et fonctions communs à export-anon.sh et import-anon.sh, lus par `source`.
#
# Chaque réglage a sa valeur par défaut ici, pour l'installation Docker du dépôt. Le fichier
# mysql/anon.conf, ignoré par git, les surcharge sur un poste : même syntaxe, une affectation bash
# par ligne. La variable d'environnement ANON_CONF désigne un autre fichier, pour une épreuve.

# Le client mysql, lancé avec l'entrée standard ouverte. Une restauration n'écrit pas le journal
# binaire : il doublerait la place prise par une copie jetable.
ANON_MYSQL=(docker exec -i mysql-otf mysql -uroot "--init-command=SET SESSION sql_log_bin = 0")
ANON_MYSQLDUMP=(docker exec -i mysql-otf mysqldump -uroot)

# La place libre là où MySQL range ses bases, au format de `df -Pk`.
ANON_DATADIR_FREE=(docker exec mysql-otf df -Pk /var/lib/mysql)

# Le point d'entrée en ligne de commande de src, en environnement de dev.
ANON_LIME=(docker exec -i -w /var/www/otf php-fpm-otf php framework/lime.php -e dev)

ANON_REDIS_FLUSH=(docker exec redis-otf redis-cli flushall)

# Le dépôt src lu côté hôte, pour le commit du manifeste : git est absent du conteneur.
ANON_SRC="$SCRIPT_DIR/../../src"

# Les sauvegardes de production extraites par import-backup.sh.
ANON_DUMPS="$SCRIPT_DIR/tmp"

# Un fichier de clé publique gpg par destinataire.
ANON_RECIPIENTS="$SCRIPT_DIR/anon/destinataires"

# La clé secrète qui signe l'archive à l'export, désignée comme pour gpg --local-user (empreinte de
# préférence). Vide, c'est la clé par défaut du trousseau de la personne qui lance.
ANON_SIGNER=

# Un fichier de clé publique gpg par personne dont l'import accepte la signature.
ANON_SIGNERS="$SCRIPT_DIR/anon/signataires"

# Le dossier où l'archive chiffrée est déposée.
ANON_OUTPUT="$HOME/Dropbox/SAS OTF/Tech/Backups"

# Le dossier sous lequel se créent les fichiers intermédiaires en clair, supprimés en fin de script.
ANON_WORK_PARENT="${TMPDIR:-/tmp}"

# La place demandée là où MySQL range ses bases, en multiple de la taille des sauvegardes restaurées :
# tables, index et réécritures de l'anonymisation.
ANON_DISK_FACTOR=3

# Le début du nom des bases que l'import écrit : dev_ pour un vrai import, anon_import_test_ pour une
# épreuve.
ANON_IMPORT_PREFIX=dev_

# Le mot de passe de dev posé à l'import sur les comptes administrateurs. Vide, il est demandé au
# lancement.
ANON_DEV_PASSWORD=

ANON_CONF="${ANON_CONF:-$SCRIPT_DIR/anon.conf}"

if [ -f "$ANON_CONF" ]; then
	# shellcheck source=/dev/null
	source "$ANON_CONF"
fi

refuse() {
	echo "✗ $*" >&2
	exit 1
}

step() {
	echo "→ $*"
}

# L'empreinte SHA-256 d'un fichier, par l'outil présent sur le poste.
sha256() {
	if command -v sha256sum > /dev/null; then
		sha256sum "$1" | cut -d ' ' -f 1
	else
		shasum -a 256 "$1" | cut -d ' ' -f 1
	fi
}

# La place libre d'un dossier de l'hôte, en kilo-octets.
free_kb() {
	df -Pk "$1" | awk 'NR == 2 { print $4 }'
}

# Une taille en kilo-octets, lue en gigaoctets.
gigabytes() {
	awk -v kb="$1" 'BEGIN { printf "%.1f Go", kb / 1048576 }'
}

# Toute commande mysql qui ne lit pas un fichier SQL lit /dev/null : `docker exec -i` transmet
# l'entrée standard au conteneur même quand la commande ne la lit pas, et avalerait le début du
# fichier qu'une restauration s'apprête à lire.

# Les bases dont le nom commence par le préfixe donné, une par ligne. Le préfixe ne porte que des
# minuscules, des chiffres et des soulignés, dont chacun s'échappe pour LIKE.
databases_like() {
	local pattern="${1//_/\\_}%"
	"${ANON_MYSQL[@]}" -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE '$pattern' ORDER BY schema_name" < /dev/null
}

drop_database() {
	"${ANON_MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`$1\`" < /dev/null
}

# Restaure un fichier SQL, lu sur l'entrée standard, dans une base créée pour lui.
restore_database() {
	"${ANON_MYSQL[@]}" -e "CREATE DATABASE \`$1\`" < /dev/null
	"${ANON_MYSQL[@]}" "$1"
}

# Les fichiers de clé d'un dossier, un par ligne, hors README et fichiers cachés (.gitkeep).
key_files() {
	local file
	for file in "$1"/*; do
		case "$(basename "$file")" in
			README*|.*) ;;
			*) if [ -f "$file" ]; then echo "$file"; fi ;;
		esac
	done
}

# L'empreinte de la clé principale d'un fichier de clé publique, lue par le trousseau jetable $1 sans
# rien y importer. Le fichier porte une seule clé principale, utilisable pour $3 : E pour chiffrer,
# S pour signer.
key_fingerprint() {
	local homedir=$1 file=$2 capability=$3 keys primaries
	keys=$(gpg --homedir "$homedir" --batch --with-colons --show-keys "$file" 2> /dev/null) || refuse "$(basename "$file") n'est pas une clé publique gpg lisible."
	primaries=$(grep -c '^pub:' <<< "$keys" || true)
	[ "$primaries" = 1 ] || refuse "$(basename "$file") porte $primaries clé(s) principale(s) : une seule par fichier, un fichier par personne."
	grep -q "$capability" <<< "$(awk -F: '$1 == "pub" { print $12 }' <<< "$keys")" || refuse "$(basename "$file") n'a aucune clé utilisable pour $(case "$capability" in E) echo chiffrer ;; S) echo signer ;; esac)."
	awk -F: '$1 == "fpr" { print $10; exit }' <<< "$keys"
}

# Durée écoulée depuis le début du script, en minutes et secondes.
elapsed() {
	local seconds=$(( $(date +%s) - ANON_STARTED ))
	printf '%dmin%02ds' $(( seconds / 60 )) $(( seconds % 60 ))
}

ANON_STARTED=$(date +%s)
