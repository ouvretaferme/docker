#!/usr/bin/env bash
# Fabrique la copie anonymisée d'une sauvegarde de production, signée par la clé secrète de la
# personne qui lance et chiffrée pour chaque clé publique de anon/destinataires/, et la dépose dans le
# dossier des sauvegardes. Lancé à la main.
#
# Usage : ./export-anon.sh AAAA-MM-JJ
#         ./export-anon.sh --purger     supprime les bases anon_ laissées par un export interrompu
#
# La sauvegarde du jour doit être extraite dans tmp/ (import-backup.sh) : tmp/AAAA-MM-JJ.sql pour la
# base commune, tmp/structure_<id>.sql pour chaque structure. Le choix des structures et
# l'anonymisation appartiennent à src (data/anonymize:structures, data/anonymize) : ce script
# restaure, appelle, puis archive. Rien ne part si un contrôle refuse, et aucune base anon_ ni
# aucun fichier en clair ne reste, que l'export aboutisse ou non.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=anon/commun.sh
source "$SCRIPT_DIR/anon/commun.sh"

COMMON=anon_ouvretaferme

# Un seul export à la fois : deux exports partageraient les mêmes bases anon_.
LOCK="$ANON_WORK_PARENT/otf-anon-export.lock"

# Les appels qui ne lisent pas un fichier SQL lisent /dev/null, pour la raison dite dans commun.sh.

# Les bases que l'export restaure. Le motif ne touche ni aux bases anon_test_ des tests de src, ni aux
# bases anon_import_test_ d'une épreuve de l'import.
export_databases() {
	"${ANON_MYSQL[@]}" -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name = '$COMMON' OR schema_name LIKE 'anon\\_structure\\_%' ORDER BY schema_name" < /dev/null
}

drop_export_databases() {
	local database
	for database in $(export_databases); do
		drop_database "$database"
	done
}

if [ "${1:-}" = "--purger" ]; then
	step "Suppression des bases et des fichiers laissés par un export interrompu..."
	drop_export_databases
	find "$ANON_WORK_PARENT" -maxdepth 1 -name 'otf-anon-export.*' -type d -exec rm -rf {} +
	rm -rf "$LOCK"
	echo "   ✓ $(export_databases | wc -l | tr -d ' ') base anon_ restante"
	exit 0
fi

DATE="${1:-}"

if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
	refuse "Usage : $0 AAAA-MM-JJ (la date de la sauvegarde extraite dans $ANON_DUMPS)"
fi

DUMP_COMMON="$ANON_DUMPS/$DATE.sql"
ARCHIVE="$ANON_OUTPUT/otf-anon-$DATE.tar.gpg"
MANIFEST_OUTPUT="$ANON_OUTPUT/otf-anon-$DATE.manifeste.txt"

# ── Ménage, posé avant tout ce qui peut laisser une trace ─────────────────────

WORK=""
ARCHIVE_PART=""
DATABASES_OWNED=0
LOCK_OWNED=0

cleanup() {
	local status=$?
	set +e
	trap - INT TERM HUP
	if [ "$DATABASES_OWNED" = 1 ]; then
		drop_export_databases
		local left
		left=$(export_databases | wc -l | tr -d ' ')
		if [ "$left" != 0 ]; then
			echo "✗ $left base(s) anon_ n'ont pas pu être supprimées : relancer $0 --purger" >&2
			status=1
		fi
	fi
	if [ -n "$ARCHIVE_PART" ]; then
		rm -f "$ARCHIVE_PART"
	fi
	if [ -n "$WORK" ]; then
		rm -rf "$WORK"
	fi
	if [ "$LOCK_OWNED" = 1 ]; then
		rmdir "$LOCK"
	fi
	if [ "$status" != 0 ]; then
		echo "✗ Export arrêté au bout de $(elapsed) : rien n'est parti, les bases anon_ et les fichiers intermédiaires sont supprimés." >&2
	fi
	exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ── Vérifications, avant toute écriture ───────────────────────────────────────

step "Vérifications..."

mkdir "$LOCK" 2> /dev/null || refuse "Un autre export tourne, ou un export tué l'a laissé ($LOCK) : $0 --purger s'il n'en tourne aucun."
LOCK_OWNED=1

command -v gpg > /dev/null || refuse "gpg est absent de ce poste : l'archive ne peut pas être chiffrée."
command -v git > /dev/null || refuse "git est absent de ce poste : le manifeste ne peut pas dater le code de src."

[ -f "$DUMP_COMMON" ] || refuse "Sauvegarde introuvable : $DUMP_COMMON"
[ -d "$ANON_OUTPUT" ] || refuse "Dossier de dépôt introuvable : $ANON_OUTPUT (réglage ANON_OUTPUT de anon.conf)"
[ -w "$ANON_OUTPUT" ] || refuse "Dossier de dépôt en lecture seule : $ANON_OUTPUT"
[ -e "$ARCHIVE" ] && refuse "Une archive existe déjà pour cette sauvegarde : $ARCHIVE"

git -C "$ANON_SRC" rev-parse HEAD > /dev/null 2>&1 || refuse "Dépôt src illisible par git : $ANON_SRC (réglage ANON_SRC de anon.conf)"

RECIPIENTS=()
while IFS= read -r file; do
	RECIPIENTS+=("$file")
done < <(key_files "$ANON_RECIPIENTS")

[ "${#RECIPIENTS[@]}" -gt 0 ] || refuse "Aucun destinataire : déposer la clé publique gpg de chaque destinataire dans $ANON_RECIPIENTS"

# Un trousseau jetable, dans le dossier de travail : la lecture des clés et le chiffrement ne
# touchent pas à celui de la personne qui lance.
WORK=$(mktemp -d "$ANON_WORK_PARENT/otf-anon-export.XXXXXX")
chmod 700 "$WORK"
mkdir -m 700 "$WORK/gnupg" "$WORK/archive"

FINGERPRINTS=()
GPG_RECIPIENTS=()
for file in "${RECIPIENTS[@]}"; do
	fingerprint=$(key_fingerprint "$WORK/gnupg" "$file" E)
	FINGERPRINTS+=("$fingerprint")
	GPG_RECIPIENTS+=(--recipient-file "$file")
done

# La signature, seule étape qui lit le trousseau de la personne qui lance, s'éprouve sur un texte
# jetable : une clé absente, expirée, révoquée ou dont la phrase secrète n'est pas donnée se refuse
# ici et non après les heures de restauration. La vérification de cette signature donne l'empreinte
# de la clé principale, qui fixe la clé de la passe finale et va au manifeste.
# L'expansion protégée d'un tableau vide : bash 3.2 le dit non défini sous set -u.
SIGN_OPTIONS=()
if [ -n "$ANON_SIGNER" ]; then
	SIGN_OPTIONS=(--local-user "$ANON_SIGNER")
fi
printf 'otf-anon\n' | gpg --batch --yes ${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"} --output "$WORK/epreuve.sig" --sign 2> "$WORK/signature.txt" || refuse "Aucune clé secrète utilisable pour signer l'archive (réglage ANON_SIGNER de anon.conf, sinon la clé par défaut de gpg) : $(tr '\n' ' ' < "$WORK/signature.txt")"
SIGNERS=$(gpg --batch --status-fd 1 --verify "$WORK/epreuve.sig" 2> /dev/null | awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $12 }') || true
# Un local-user du gpg.conf de la personne s'ajoute à ANON_SIGNER sans rien dire : l'archive
# porterait deux signatures, que l'import refuse.
[ "$(grep -c . <<< "$SIGNERS" || true)" -le 1 ] || refuse "L'épreuve porte plusieurs signatures ($(tr '\n' ' ' <<< "$SIGNERS")) : retirer local-user du gpg.conf, ou désigner la clé par ANON_SIGNER seul."
SIGNER="$SIGNERS"
[[ "$SIGNER" =~ ^[0-9A-F]{40,64}$ ]] || refuse "La signature d'épreuve ne se vérifie pas dans le trousseau de ce poste : la clé publique de la clé qui signe y manque."

# La place : la base commune et toutes les structures extraites, ce qui majore celles que la liste
# retiendra, connue seulement une fois la base commune restaurée.
DUMPS_KB=$( (du -k "$DUMP_COMMON"; find "$ANON_DUMPS" -maxdepth 1 -type f -name 'structure_*.sql' -exec du -k {} +) | awk '{ total += $1 } END { print total }')
DATADIR_KB=$("${ANON_DATADIR_FREE[@]}" < /dev/null | awk 'NR == 2 { print $4 }')
[ -n "$DATADIR_KB" ] || refuse "Place libre de MySQL illisible (réglage ANON_DATADIR_FREE de anon.conf)."
[ "$DATADIR_KB" -ge $(( DUMPS_KB * ANON_DISK_FACTOR )) ] || refuse "Place insuffisante pour MySQL : $(gigabytes "$DATADIR_KB") libres, $(gigabytes $(( DUMPS_KB * ANON_DISK_FACTOR ))) demandés ($ANON_DISK_FACTOR fois les $(gigabytes "$DUMPS_KB") des sauvegardes)."
[ "$(free_kb "$WORK")" -ge "$DUMPS_KB" ] || refuse "Place insuffisante pour les fichiers intermédiaires dans $ANON_WORK_PARENT : $(gigabytes "$DUMPS_KB") demandés."
[ "$(free_kb "$ANON_OUTPUT")" -ge $(( DUMPS_KB / 2 )) ] || refuse "Place insuffisante dans $ANON_OUTPUT : $(gigabytes $(( DUMPS_KB / 2 ))) demandés."

# Une sauvegarde qui changerait de base par USE écrirait hors des bases anon_.
# Une sauvegarde plus récente que son archive a été réécrite après l'extraction, qui garde l'heure du
# dump : ce n'est plus la production du jour.
TAR_COMMON="$ANON_DUMPS/$DATE.tar.gz"
TAR_STRUCTURE="$ANON_DUMPS/$DATE-structure.tar.gz"
[ -f "$TAR_COMMON" ] || refuse "Archive de la sauvegarde introuvable : $TAR_COMMON"
[ -f "$TAR_STRUCTURE" ] || refuse "Archive de la sauvegarde introuvable : $TAR_STRUCTURE"
[ "$DUMP_COMMON" -nt "$TAR_COMMON" ] && refuse "$DUMP_COMMON est plus récent que $TAR_COMMON : il a été réécrit depuis l'extraction."

grep -m 1 -qE '^(USE|CREATE DATABASE) ' "$DUMP_COMMON" && refuse "$DUMP_COMMON change de base (USE ou CREATE DATABASE) : il ne se restaure pas sous un autre nom."

[ -z "$(export_databases)" ] || refuse "Des bases anon_ existent déjà ($(export_databases | tr '\n' ' ')) : un autre export tourne, ou un export interrompu les a laissées ($0 --purger)."

echo "   ✓ signataire $SIGNER, ${#RECIPIENTS[@]} destinataire(s), $(gigabytes "$DATADIR_KB") libres pour MySQL, $(gigabytes "$DUMPS_KB") de sauvegardes"

# ── Restauration ──────────────────────────────────────────────────────────────

DATABASES_OWNED=1

step "Restauration de la base commune ($DATE)..."
restore_database "$COMMON" < "$DUMP_COMMON"
echo "   ✓ $(elapsed)"

step "Liste des structures (data/anonymize:structures)..."
LIME_OUTPUT="$WORK/structures.txt"
if ! "${ANON_LIME[@]}" data/anonymize:structures < /dev/null > "$LIME_OUTPUT" 2>&1; then
	cat "$LIME_OUTPUT" >&2
	refuse "data/anonymize:structures a échoué."
fi
STRUCTURES=$(awk 'NF { line = $0 } END { print line }' "$LIME_OUTPUT")
[[ "$STRUCTURES" =~ ^[0-9]+( [0-9]+)*$ ]] || refuse "data/anonymize:structures n'a pas rendu une liste d'identifiants : « $STRUCTURES »"

MISSING=()
STALE=()
for id in $STRUCTURES; do
	file="$ANON_DUMPS/structure_$id.sql"
	if [ ! -f "$file" ]; then
		MISSING+=("$id")
	elif [ "$(date -r "$file" +%Y-%m-%d)" != "$DATE" ] || [ "$file" -nt "$TAR_STRUCTURE" ]; then
		STALE+=("$id")
	fi
done

[ "${#MISSING[@]}" = 0 ] || refuse "Structure(s) sans sauvegarde dans $ANON_DUMPS : ${MISSING[*]}"
[ "${#STALE[@]}" = 0 ] || refuse "Sauvegarde(s) réécrite(s) depuis l'extraction ou d'une autre date que le $DATE : structure ${STALE[*]} (extraire de nouveau $DATE-structure.tar.gz)"

count=0
total=$(echo "$STRUCTURES" | wc -w | tr -d ' ')
step "Restauration de $total structures..."
for id in $STRUCTURES; do
	file="$ANON_DUMPS/structure_$id.sql"
	grep -m 1 -qE '^(USE|CREATE DATABASE) ' "$file" && refuse "$file change de base (USE ou CREATE DATABASE) : il ne se restaure pas sous un autre nom."
	restore_database "anon_structure_$id" < "$file"
	count=$(( count + 1 ))
	if [ $(( count % 100 )) = 0 ]; then
		echo "   $count / $total"
	fi
done
echo "   ✓ $(elapsed)"

# ── Anonymisation et contrôles ────────────────────────────────────────────────

step "Anonymisation (data/anonymize)..."
CONTROLS="$WORK/controles.txt"
if ! "${ANON_LIME[@]}" data/anonymize < /dev/null > "$CONTROLS" 2>&1; then
	cat "$CONTROLS" >&2
	refuse "data/anonymize a refusé l'export."
fi
cat "$CONTROLS"
echo "   ✓ $(elapsed)"

# ── Archive ───────────────────────────────────────────────────────────────────

# Chaque base part sous le nom qu'elle prend en dev, sans nom de base dans son contenu : c'est
# l'import qui choisit la base cible.
step "Copie des bases anonymisées..."
for database in $(export_databases); do
	name="dev_${database#anon_}"
	"${ANON_MYSQLDUMP[@]}" --single-transaction --skip-comments --hex-blob --no-tablespaces --routines "$database" < /dev/null | gzip -6 > "$WORK/archive/$name.sql.gz"
done
echo "   ✓ $(find "$WORK/archive" -name '*.sql.gz' | wc -l | tr -d ' ') bases, $(elapsed)"

SRC_COMMIT=$(git -C "$ANON_SRC" rev-parse HEAD)
SRC_CHANGED=$(git -C "$ANON_SRC" status --porcelain | wc -l | tr -d ' ')

{
	echo "Copie anonymisée de Ouvretaferme"
	echo "format 2"
	echo "sauvegarde $DATE"
	echo "exportée $(date +%Y-%m-%dT%H:%M:%S%z)"
	echo "src $SRC_COMMIT ($SRC_CHANGED fichier(s) modifié(s) ou non suivi(s) hors de ce commit)"
	echo "structures $STRUCTURES"
	echo "signataire $SIGNER"
	for fingerprint in "${FINGERPRINTS[@]}"; do
		echo "destinataire $fingerprint"
	done
	for file in "$WORK/archive"/*.sql.gz; do
		echo "base $(basename "$file") $(sha256 "$file")"
	done
	echo
	echo "Sortie de data/anonymize :"
	cat "$CONTROLS"
} > "$WORK/archive/manifeste.txt"

# L'archive n'existe que chiffrée : tar l'écrit dans gpg, qui écrit un fichier provisoire renommé une
# fois complet. Les dumps sont déjà compressés. La passe signe et chiffre ensemble, dans le trousseau
# de la personne qui lance, seul à porter la clé secrète ; les destinataires viennent de leurs
# fichiers sans y être importés. --no-encrypt-to écarte ceux qu'un gpg.conf ajouterait hors du
# manifeste, --no-textmode la conversion des fins de ligne qu'il imposerait au tar. gpg peut redemander ici la phrase secrète de la clé.
step "Signature et chiffrement pour ${#RECIPIENTS[@]} destinataire(s)..."
ARCHIVE_PART="$ARCHIVE.part"
(cd "$WORK/archive" && echo manifeste.txt && ls -- *.sql.gz) > "$WORK/liste"
tar -C "$WORK/archive" -cf - -T "$WORK/liste" | gpg --batch --yes --trust-model always --no-encrypt-to --no-textmode --compress-algo none --local-user "$SIGNER" "${GPG_RECIPIENTS[@]}" --output "$ARCHIVE_PART" --sign --encrypt
cp "$WORK/archive/manifeste.txt" "$MANIFEST_OUTPUT"
mv "$ARCHIVE_PART" "$ARCHIVE"
ARCHIVE_PART=""

echo "   ✓ $ARCHIVE ($(du -h "$ARCHIVE" | cut -f 1)), manifeste à côté"
echo
echo "Export terminé en $(elapsed) : $(grep -c '^base ' "$MANIFEST_OUTPUT") bases, structures $STRUCTURES"
