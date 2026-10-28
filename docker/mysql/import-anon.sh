#!/usr/bin/env bash
# Importe en dev une copie anonymisée fabriquée par export-anon.sh, déchiffrée par la clé gpg de la
# personne qui lance. Rien n'est importé si l'archive n'est pas signée par une clé de
# anon/signataires/. Aucun accès réseau.
#
# Usage : ./import-anon.sh chemin/vers/otf-anon-AAAA-MM-JJ.tar.gpg
#
# Les bases dev_ouvretaferme et dev_structure_<id> de ce poste sont remplacées, toutes les
# dev_structure_* existantes supprimées d'abord. Le mot de passe de dev (réglage ANON_DEV_PASSWORD de
# anon.conf, demandé sinon) est posé sur le compte de chaque administrateur de
# \user\UserSetting::$admin, lu dans le secret.c.php de ce poste : la copie n'emporte aucune
# empreinte de mot de passe. Redis est vidé, ses caches désignant des lignes de l'ancienne base.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=anon/commun.sh
source "$SCRIPT_DIR/anon/commun.sh"

ARCHIVE="${1:-}"
PREFIX="$ANON_IMPORT_PREFIX"

[ -n "$ARCHIVE" ] || refuse "Usage : $0 chemin/vers/otf-anon-AAAA-MM-JJ.tar.gpg"
[ -f "$ARCHIVE" ] || refuse "Archive introuvable : $ARCHIVE"

# dev_ pour un vrai import, anon_import_test_ pour une épreuve : rien d'autre, pour qu'une erreur de
# réglage n'écrase ni une base de production ni les bases d'un export en cours.
[[ "$PREFIX" =~ ^(dev_|anon_import_test_([a-z0-9]+_)?)$ ]] || refuse "Préfixe de bases refusé : « $PREFIX » (dev_, ou anon_import_test_ pour une épreuve)"

command -v gpg > /dev/null || refuse "gpg est absent de ce poste : l'archive ne peut pas être déchiffrée."
gpg --dump-options | grep -qx -- '--unwrap' || refuse "Ce gpg ne connaît pas --unwrap, qui sépare le déchiffrement de la vérification de la signature : mettre GnuPG à jour."

SIGNER_FILES=()
while IFS= read -r file; do
	SIGNER_FILES+=("$file")
done < <(key_files "$ANON_SIGNERS")

[ "${#SIGNER_FILES[@]}" -gt 0 ] || refuse "Aucun signataire : déposer dans $ANON_SIGNERS la clé publique gpg de chaque personne dont les exports sont acceptés."

WORK=""

cleanup() {
	local status=$?
	set +e
	if [ -n "$WORK" ]; then
		rm -rf "$WORK"
	fi
	if [ "$status" != 0 ]; then
		echo "✗ Import arrêté au bout de $(elapsed) ; les fichiers déchiffrés sont supprimés." >&2
	fi
	exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

WORK=$(mktemp -d "$ANON_WORK_PARENT/otf-anon.XXXXXX")
chmod 700 "$WORK"
mkdir -m 700 "$WORK/gnupg" "$WORK/archive"

# Un trousseau jetable qui ne contient que les signataires : la signature se vérifie là, jamais
# contre le trousseau de la personne qui lance, où une autre clé pourrait la valider.
SIGNER_FINGERPRINTS=""
for file in "${SIGNER_FILES[@]}"; do
	fingerprint=$(key_fingerprint "$WORK/gnupg" "$file" S)
	SIGNER_FINGERPRINTS+="$fingerprint"$'\n'
	gpg --homedir "$WORK/gnupg" --batch --quiet --import "$file" 2> /dev/null || refuse "$(basename "$file") ne s'importe pas dans le trousseau jetable."
done

# ── Mot de passe et confirmation, avant le long travail ───────────────────────

PASSWORD="$ANON_DEV_PASSWORD"

if [ -z "$PASSWORD" ]; then
	[ -t 0 ] || refuse "Mot de passe de dev absent : le régler dans anon.conf (ANON_DEV_PASSWORD), ou lancer depuis un terminal."
	read -r -s -p "Mot de passe de dev des comptes administrateurs : " PASSWORD
	echo
	read -r -s -p "Le même, une seconde fois : " PASSWORD_AGAIN
	echo
	[ "$PASSWORD" = "$PASSWORD_AGAIN" ] || refuse "Les deux mots de passe diffèrent."
fi

if [ -n "$(databases_like "${PREFIX}ouvretaferme")" ]; then
	[ -t 0 ] || refuse "${PREFIX}ouvretaferme existe : l'import la remplace, ce qui se confirme depuis un terminal."
	read -r -p "${PREFIX}ouvretaferme et les ${PREFIX}structure_* de ce poste vont être remplacées. Taper oui pour continuer : " ANSWER
	[ "$ANSWER" = oui ] || refuse "Import abandonné, rien n'a changé."
fi

# ── Déchiffrement, signature et manifeste ─────────────────────────────────────

# Le trousseau de la personne qui lance retire le chiffrement, celui des signataires vérifie ce qui
# reste. Le verdict se lit dans le statut machine de gpg, dont le texte affiché change avec la langue
# et la version.
step "Déchiffrement..."
gpg --no-auto-key-retrieve --output "$WORK/signee.gpg" --unwrap --decrypt "$ARCHIVE" || refuse "Archive indéchiffrable : altérée, tronquée, ou chiffrée sans la clé de ce poste. Rien n'est importé."

step "Vérification de la signature..."
if gpg --homedir "$WORK/gnupg" --batch --trust-model always --no-auto-key-retrieve --status-file "$WORK/signature.txt" --output "$WORK/archive.tar" --decrypt "$WORK/signee.gpg" 2> /dev/null; then
	VERIFIED=0
else
	VERIFIED=$?
fi
rm "$WORK/signee.gpg"
STATUS=$(grep '^\[GNUPG:\] ' "$WORK/signature.txt" | cut -d ' ' -f 2- || true)

SIGNATURES=$(grep -c '^NEWSIG' <<< "$STATUS" || true)
[ "$SIGNATURES" != 0 ] || refuse "Archive non signée : export-anon.sh signe chaque archive. Rien n'est importé."
[ "$SIGNATURES" = 1 ] || refuse "L'archive porte $SIGNATURES signatures, export-anon.sh n'en pose qu'une. Rien n'est importé."
if grep -q '^BADSIG ' <<< "$STATUS"; then
	refuse "Signature invalide : l'archive a été modifiée après avoir été signée. Rien n'est importé."
fi
if grep -q '^ERRSIG ' <<< "$STATUS"; then
	refuse "Signataire inconnu : la clé $(awk '$1 == "ERRSIG" { print ($8 != "" ? $8 : $2); exit }' <<< "$STATUS") n'est pas dans $ANON_SIGNERS. Rien n'est importé."
fi
grep -q '^GOODSIG ' <<< "$STATUS" || refuse "La signature est celle d'une clé expirée ou révoquée. Rien n'est importé."
SIGNED_BY=$(awk '$1 == "VALIDSIG" { print $11; exit }' <<< "$STATUS")
[ -n "$SIGNED_BY" ] && grep -qx "$SIGNED_BY" <<< "$SIGNER_FINGERPRINTS" || refuse "Signataire inconnu : ${SIGNED_BY:-aucune empreinte} n'est pas dans $ANON_SIGNERS. Rien n'est importé."
[ "$VERIFIED" = 0 ] || refuse "gpg a signalé une erreur en lisant l'archive signée (code $VERIFIED). Rien n'est importé."
echo "   ✓ signée par $SIGNED_BY"

# Seuls les noms qu'écrit export-anon.sh s'extraient : aucun chemin ne sort du dossier de travail.
while IFS= read -r name; do
	[[ "$name" =~ ^(manifeste\.txt|dev_ouvretaferme\.sql\.gz|dev_structure_[0-9]+\.sql\.gz)$ ]] || refuse "Nom inattendu dans l'archive : « $name »"
done < <(tar -tf "$WORK/archive.tar")

tar -C "$WORK/archive" -xf "$WORK/archive.tar"
rm "$WORK/archive.tar"

MANIFEST="$WORK/archive/manifeste.txt"
[ -f "$MANIFEST" ] || refuse "L'archive n'a pas de manifeste."

# L'en-tête du manifeste s'arrête à la première ligne vide ; la sortie des contrôles suit.
HEADER=$(awk 'NF == 0 { exit } { print }' "$MANIFEST")

grep -qx 'format 2' <<< "$HEADER" || refuse "Format de manifeste inconnu : cette archive vient d'une autre version de export-anon.sh."
grep -qx "signataire $SIGNED_BY" <<< "$HEADER" || refuse "Le manifeste ne nomme pas la clé qui a signé l'archive."

LISTED=$(awk '$1 == "base" { print $2 }' <<< "$HEADER")
grep -qx 'dev_ouvretaferme.sql.gz' <<< "$LISTED" || refuse "Le manifeste ne liste pas la base commune."

while read -r _ name expected; do
	[ -f "$WORK/archive/$name" ] || refuse "$name est listé au manifeste et absent de l'archive."
	[ "$(sha256 "$WORK/archive/$name")" = "$expected" ] || refuse "$name ne correspond pas à son empreinte du manifeste."
done < <(awk '$1 == "base"' <<< "$HEADER")

for file in "$WORK/archive"/*.sql.gz; do
	grep -qx "$(basename "$file")" <<< "$LISTED" || refuse "$(basename "$file") est dans l'archive sans être listé au manifeste."
done

echo "   ✓ $(wc -l <<< "$LISTED" | tr -d ' ') bases vérifiées, $(grep '^sauvegarde ' <<< "$HEADER")"

# ── Import ────────────────────────────────────────────────────────────────────

step "Suppression des ${PREFIX}structure_* de ce poste..."
for database in $(databases_like "${PREFIX}structure_"); do
	drop_database "$database"
done
echo "   ✓"

step "Import de la base commune..."
drop_database "${PREFIX}ouvretaferme"
gunzip -c "$WORK/archive/dev_ouvretaferme.sql.gz" | restore_database "${PREFIX}ouvretaferme"
rm "$WORK/archive/dev_ouvretaferme.sql.gz"
echo "   ✓ $(elapsed)"

total=$(grep -c '^dev_structure_' <<< "$LISTED" || true)
count=0
step "Import de $total structures..."
for file in "$WORK/archive"/dev_structure_*.sql.gz; do
	[ -f "$file" ] || continue
	name=$(basename "$file" .sql.gz)
	gunzip -c "$file" | restore_database "${PREFIX}${name#dev_}"
	rm "$file"
	count=$(( count + 1 ))
	if [ $(( count % 100 )) = 0 ]; then
		echo "   $count / $total"
	fi
done
echo "   ✓ $(elapsed)"

# ── Comptes administrateurs ───────────────────────────────────────────────────

# Le mot de passe passe par l'entrée standard, jamais par la ligne de commande, que ps affiche. La
# base cible se déclare au cadriciel le temps de l'écriture, comme pour une épreuve sur une copie. Il
# se contrôle et se hache par SignUpLib::matchBasicPassword(), comme à l'inscription.
step "Mot de passe de dev des administrateurs..."
IFS= read -r -d '' PHP <<'PHP' || true
$base = '__BASE__';
$password = rtrim(stream_get_contents(STDIN), "\n");
if(\user\UserSetting::$admin === []) {
	echo "Aucun administrateur dans \\user\\UserSetting::\$admin sur ce poste (secret.c.php).\n";
	exit(1);
}
\Database::addBase($base, \Database::getServerByBase(\Database::getBase('user')));
\ModuleModel::redirectModules(['user\\UserAuth' => $base]);
$cUserAuth = \user\UserAuth::model()
	->select('id', 'user')
	->whereUser('IN', \user\UserSetting::$admin)
	->whereType(\user\UserAuth::BASIC)
	->getCollection();
$fw = new \FailWatch();
foreach($cUserAuth as $eUserAuth) {
	$eUser = new \user\User(['id' => $eUserAuth['user']['id'], 'auth' => $eUserAuth]);
	\user\SignUpLib::matchBasicPassword('create', $eUser, ['password' => $password]);
}
// Sans page autour, rien n'imprime le refus : il s'écrit ici.
$fw->validate(onKo: function(\FailWatch $fw) {
	echo $fw."\n";
	exit(1);
});
// SignUpLib::updatePassword() écrit aussi les sessions, les défis et les connexions automatiques, hors
// de la seule table redirigée vers la copie : l'écriture se fait ligne à ligne sur le modèle.
foreach($cUserAuth as $eUserAuth) {
	\user\UserAuth::model()->select('password')->update($eUserAuth);
}
\ModuleModel::redirectModules([]);
echo 'ANON_ADMINS '.count(\user\UserSetting::$admin).' '.$cUserAuth->count()."\n";
PHP
PHP="${PHP//__BASE__/${PREFIX}ouvretaferme}"

# La sortie de lime se garde en entier : une exception y écrit sa trace, et un refus son message.
LIME_OUTPUT="$WORK/mot-de-passe.txt"
if ! printf '%s\n' "$PASSWORD" | "${ANON_LIME[@]}" -r "$PHP" > "$LIME_OUTPUT" 2>&1; then
	cat "$LIME_OUTPUT" >&2
	refuse "Le mot de passe de dev n'a pas pu être posé ; les bases sont importées, relancer l'import après correction."
fi

read -r _ ADMINS UPDATED <<< "$(grep '^ANON_ADMINS ' "$LIME_OUTPUT")"
echo "   ✓ $UPDATED compte(s) sur $ADMINS administrateur(s) de ce poste"
[ "$UPDATED" -gt 0 ] || echo "   ⚠ Aucun administrateur de ce poste n'a de compte dans la copie : son identifiant doit figurer dans \\user\\UserSetting::\$admin en production." >&2

# ── Caches ────────────────────────────────────────────────────────────────────

if [ "$PREFIX" = dev_ ]; then
	step "Vidage de Redis..."
	"${ANON_REDIS_FLUSH[@]}" < /dev/null > /dev/null
	echo "   ✓"
fi

echo
echo "Import terminé en $(elapsed) dans ${PREFIX}ouvretaferme et $count ${PREFIX}structure_*."
grep -E '^(sauvegarde|src) ' <<< "$HEADER"
