#!/bin/bash
# jellyfin-setup.sh
# One-click setup for Jellyfin docker environment

set -euo pipefail

# -----------------------------
# Default config
# -----------------------------
DEFAULT_JELLYFIN_DIR="/opt/docker/jellyfin"
SRC_DIR="$(cd "$(dirname "$0")"; pwd)"
JELLYFIN_DIR=""

# -----------------------------
# Step 1: Prompt for directory
# -----------------------------
echo "Jellyfin deploy directory (default: $DEFAULT_JELLYFIN_DIR):"
read -r input_dir

if [[ -z "$input_dir" ]]; then
    JELLYFIN_DIR="$DEFAULT_JELLYFIN_DIR"
else
    JELLYFIN_DIR="$input_dir"
fi

# Make sure directory exists and is writable
echo "Creating Jellyfin working directory: $JELLYFIN_DIR"
sudo mkdir -p "$JELLYFIN_DIR"
sudo chown "$USER":"$USER" "$JELLYFIN_DIR"
sudo chmod 755 "$JELLYFIN_DIR"

# -----------------------------
# Step 2: Copy project files
# -----------------------------
echo "Copying project files to $JELLYFIN_DIR ..."
# rsync preserves structure and is safer than cp -r
rsync -a --exclude 'jellyfin-setup.sh' --exclude '*.log' "$SRC_DIR/" "$JELLYFIN_DIR/"

echo "Project files copied."

# -----------------------------
# Step 3: Docker Compose up
# -----------------------------
cd "$JELLYFIN_DIR"
compose_files=($(ls docker-compose*.yml 2>/dev/null))
if [[ ${#compose_files[@]} -eq 0 ]]; then
    echo "No docker-compose files found in $JELLYFIN_DIR"
    exit 1
elif [[ ${#compose_files[@]} -eq 1 ]]; then
    COMPOSE_FILE="${compose_files[0]}"
    echo "Using compose file: $COMPOSE_FILE"
else
    echo "Multiple compose files found:"
    select fname in "${compose_files[@]}"; do
        if [[ -n "$fname" ]]; then
            COMPOSE_FILE="$fname"
            break
        fi
    done
fi
echo "Starting Jellyfin via: docker compose -f $COMPOSE_FILE up -d"
docker compose -f "$COMPOSE_FILE" up -d

# -----------------------------
# Step 4: Check Jellyfin status
# -----------------------------
echo "Checking Jellyfin container status..."

JELLYFIN_CONTAINER=$(docker ps --filter "name=jellyfin" --format "{{.Names}}")

if [[ -z "$JELLYFIN_CONTAINER" ]]; then
    echo "Jellyfin container is not running!"
    exit 1
else
    echo "Jellyfin container '$JELLYFIN_CONTAINER' is running."
    echo "Logs (last 20 lines):"
    docker logs --tail 20 "$JELLYFIN_CONTAINER"
    echo "You can check status: docker logs -f $JELLYFIN_CONTAINER"
    echo "If first launch, wait 1~2 minutes for Jellyfin to initialize."
fi

echo "Jellyfin setup completed successfully!"