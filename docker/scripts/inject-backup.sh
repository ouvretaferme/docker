#!/bin/bash

set -euo pipefail

# ─── Configuration Dropbox ────────────────────────────────────────────────────
# App Console : https://www.dropbox.com/developers/apps
# 1. Créer une app → Scoped access → Full Dropbox
# 2. Onglet Permissions → activer : files.metadata.read + files.content.read + sharing.read → Submit
# 3. Onglet Settings → récupérer App key + App secret et les mettres dans le .env
# 4. Lancer une première fois : ./inject-backup.sh --auth  pour obtenir le refresh token
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_DOWNLOAD=false
AUTH_MODE=false
for arg in "$@"; do
  case $arg in
    --skip-download|-s) SKIP_DOWNLOAD=true ;;
    --auth) AUTH_MODE=true ;;
  esac
done

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

# ─── Auth initiale (une seule fois) ───────────────────────────────────────────
if [ "$AUTH_MODE" = true ]; then
  if [ -z "${DROPBOX_APP_KEY:-}" ] || [ -z "${DROPBOX_APP_SECRET:-}" ]; then
    echo "Erreur : DROPBOX_APP_KEY et DROPBOX_APP_SECRET doivent être renseignés dans .env"
    exit 1
  fi
  echo "→ Ouvre cette URL dans ton navigateur et autorise l'app :"
  echo ""
  echo "  https://www.dropbox.com/oauth2/authorize?client_id=$DROPBOX_APP_KEY&response_type=code&token_access_type=offline"
  echo ""
  read -rp "Colle le code reçu ici : " AUTH_CODE
  RESPONSE=$(curl -s -X POST https://api.dropbox.com/oauth2/token \
    -d "code=$AUTH_CODE" \
    -d "grant_type=authorization_code" \
    -d "client_id=$DROPBOX_APP_KEY" \
    -d "client_secret=$DROPBOX_APP_SECRET")
  REFRESH_TOKEN=$(echo "$RESPONSE" | jq -r '.refresh_token')
  if [ -z "$REFRESH_TOKEN" ] || [ "$REFRESH_TOKEN" = "null" ]; then
    echo "Erreur lors de la récupération du refresh token :"
    echo "$RESPONSE"
    exit 1
  fi
  echo ""
  echo "✓ Ajoute cette ligne dans ton .env :"
  echo ""
  echo "  DROPBOX_REFRESH_TOKEN=$REFRESH_TOKEN"
  exit 0
fi

# ─── Renouvellement automatique de l'access token ─────────────────────────────
if [ "$SKIP_DOWNLOAD" = false ]; then
  if [ -z "${DROPBOX_APP_KEY:-}" ] || [ -z "${DROPBOX_APP_SECRET:-}" ] || [ -z "${DROPBOX_REFRESH_TOKEN:-}" ]; then
    echo "Erreur : DROPBOX_APP_KEY, DROPBOX_APP_SECRET et DROPBOX_REFRESH_TOKEN doivent être renseignés dans .env"
    echo "Lance d'abord : ./inject-backup.sh --auth"
    exit 1
  fi
  TOKEN_RESPONSE=$(curl -s -X POST https://api.dropbox.com/oauth2/token \
    -d "grant_type=refresh_token" \
    -d "refresh_token=$DROPBOX_REFRESH_TOKEN" \
    -d "client_id=$DROPBOX_APP_KEY" \
    -d "client_secret=$DROPBOX_APP_SECRET")
  DROPBOX_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
  if [ -z "$DROPBOX_TOKEN" ] || [ "$DROPBOX_TOKEN" = "null" ]; then
    echo "Erreur lors du renouvellement du token :"
    echo "$TOKEN_RESPONSE"
    exit 1
  fi
fi

if [ "$SKIP_DOWNLOAD" = true ]; then
  echo "→ Téléchargement ignoré (--skip-download)"
  LATEST=$(ls "$BACKUP_DIR"/*.sql 2>/dev/null | grep -E '[0-9]{4}-[0-9]{2}-[0-9]{2}\.sql$' | sort | tail -1 | xargs basename || true)
  if [ -z "$LATEST" ]; then
    echo "Erreur : aucun backup local trouvé dans $BACKUP_DIR"
    exit 1
  fi
  echo "  Backup local OTF    : $LATEST"
  echo "  Backup farm         : farm_7.sql"
else
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
fi

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
