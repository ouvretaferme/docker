#!/bin/bash

set -euo pipefail

# ─── Configuration Dropbox ────────────────────────────────────────────────────
# App Console : https://www.dropbox.com/developers/apps
# 1. Créer une app → Scoped access → Full Dropbox
# 2. Onglet Permissions → activer : files.metadata.read + files.content.read + sharing.read → Submit
# 3. Onglet Settings → "Generated access token" → copier dans .env
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

SHARED_LINK="https://www.dropbox.com/scl/fo/8iu1x3bqoc5yqy12nfdrs/ALahKNj0yx16P75TRk08-2Y?rlkey=p5z1gbl9f4gh29vsiv5jcwpo7"
BACKUP_DIR="$SCRIPT_DIR/../mysql/tmp"
MYSQL_CONTAINER="mysql-otf"
MYSQL_USER="root"
DB_OTF="dev_ouvretaferme"
DB_FARM="dev_farm_7"

if [ -z "$DROPBOX_TOKEN" ]; then
  echo "Erreur : DROPBOX_TOKEN non renseigné dans le script."
  exit 1
fi

# ─── 1. Détection du dernier backup daté ──────────────────────────────────────
echo "→ Récupération de la liste des backups Dropbox..."

FILES_JSON=$(curl -s -X POST "https://api.dropbox.com/2/files/list_folder" \
  -H "Authorization: Bearer $DROPBOX_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"path\": \"\", \"shared_link\": {\"url\": \"$SHARED_LINK\"}}")

LATEST=$(echo "$FILES_JSON" \
  | jq -r '.entries[].name' \
  | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.sql$' \
  | sort \
  | tail -1 || true)

if [ -z "$LATEST" ]; then
  echo "Erreur : aucun backup daté trouvé dans le dossier Dropbox."
  echo "$FILES_JSON"
  exit 1
fi

echo "  Dernier backup OTF  : $LATEST"
echo "  Backup farm         : farm_7.sql"

# ─── 2. Téléchargement dans docker/mysql/tmp ──────────────────────────────────
echo "→ Téléchargement des backups..."

for FILE in "$LATEST" "farm_7.sql"; do
  echo "  $FILE..."
  curl -s -X POST "https://content.dropboxapi.com/2/sharing/get_shared_link_file" \
    -H "Authorization: Bearer $DROPBOX_TOKEN" \
    -H "Dropbox-API-Arg: {\"url\": \"$SHARED_LINK\", \"path\": \"/$FILE\"}" \
    -o "$BACKUP_DIR/$FILE"
done

# ─── 3. Suppression et recréation des bases ───────────────────────────────────
echo "→ Suppression des bases de données..."

docker exec "$MYSQL_CONTAINER" mysql -u "$MYSQL_USER" -e "
  DROP DATABASE IF EXISTS \`$DB_OTF\`;
  DROP DATABASE IF EXISTS \`$DB_FARM\`;
  CREATE DATABASE \`$DB_OTF\`;
  CREATE DATABASE \`$DB_FARM\`;
"

# ─── 4. Import (fichiers montés dans le container via /tmp/mysql/) ─────────────
echo "→ Import de $DB_OTF..."
docker exec "$MYSQL_CONTAINER" bash -c "mysql -u $MYSQL_USER $DB_OTF < /tmp/mysql/$LATEST"

echo "→ Import de $DB_FARM..."
docker exec "$MYSQL_CONTAINER" bash -c "mysql -u $MYSQL_USER $DB_FARM < /tmp/mysql/farm_7.sql"

# ─── 5. Notification ──────────────────────────────────────────────────────────
notify-send "OTF Backup" "Import terminé avec succès ($LATEST)" --icon=dialog-information

echo "✓ Terminé."
