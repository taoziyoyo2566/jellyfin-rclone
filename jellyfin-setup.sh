#!/bin/bash
# jellyfin-setup.sh
# One-click setup for Jellyfin docker environment (with full checks and friendly prompts)

set -euo pipefail

# -----------------------------
# Initial variable definitions
# -----------------------------
DEFAULT_JELLYFIN_DIR="/opt/docker/jellyfin"
SRC_DIR="$(cd "$(dirname "$0")"; pwd)"
JELLYFIN_DIR=""
CONTAINER_NAME="jellyfin"

# -----------------------------
# Check rsync installed
# -----------------------------
if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync not found, trying to install..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y rsync
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y rsync
    else
        echo "ERROR: rsync not found and no supported package manager available. Please install rsync manually."
        exit 1
    fi
fi

# -----------------------------
# Handle existing Jellyfin container
# -----------------------------
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "A container named '${CONTAINER_NAME}' already exists."
    read -p "Do you want to remove it and start a new one? (y/N): " yn
    yn=${yn:-N}
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        docker rm -f "${CONTAINER_NAME}"
    else
        echo "Setup aborted."
        exit 1
    fi
fi

# -----------------------------
# Step 1: Prompt for directory
# -----------------------------
while true; do
    echo "Jellyfin deploy directory (default: $DEFAULT_JELLYFIN_DIR, or q to quit):"
    read -r input_dir

    if [[ "$input_dir" =~ ^[Qq]$ ]]; then
        echo "Setup aborted."
        exit 0
    fi

    if [[ -z "$input_dir" ]]; then
        JELLYFIN_DIR="$DEFAULT_JELLYFIN_DIR"
    else
        JELLYFIN_DIR="$input_dir"
    fi

    # Confirm directory with user before continuing
    echo "Target directory is: $JELLYFIN_DIR"
    read -p "Continue? (Y/n): " confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        break
    fi
done

# -----------------------------
# Step 2: Create directory & fix permissions
# -----------------------------
echo "Creating Jellyfin working directory: $JELLYFIN_DIR"
sudo mkdir -p "$JELLYFIN_DIR"

for subdir in config cache; do
    if [ -d "$JELLYFIN_DIR/$subdir" ]; then
        sudo mkdir -p "$JELLYFIN_DIR/$subdir"
        sudo chown -R "$USER":"$USER" "$JELLYFIN_DIR/$subdir"
        sudo chmod -R 755 "$JELLYFIN_DIR/$subdir"
    fi
done

# -----------------------------
# Step 3: Copy project files
# -----------------------------
echo "Copying project files to $JELLYFIN_DIR ..."
rsync -a --exclude 'jellyfin-setup.sh' --exclude '*.log' "$SRC_DIR/" "$JELLYFIN_DIR/"
echo "Project files copied."

# -----------------------------
# Step 4: Choose docker-compose file
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
        elif [[ "$REPLY" =~ ^[Qq]$ ]]; then
            echo "Setup aborted."
            exit 0
        fi
    done
fi

# -----------------------------
# Step 5: Start Jellyfin via docker compose
# -----------------------------
echo "Starting Jellyfin via: docker compose -f $COMPOSE_FILE up -d"
docker compose -f "$COMPOSE_FILE" up -d

# -----------------------------
# Step 6: Health check loop
# -----------------------------
echo "Checking Jellyfin container status..."

max_wait=50
waited=0
success=0

for i in {1..10}; do
    sleep 5
    waited=$((i*5))
    STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "notfound")
    HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "none")
    if [[ "$STATUS" == "running" && ( "$HEALTH" == "healthy" || "$HEALTH" == "none" ) ]]; then
        echo "Jellyfin container is running (health: $HEALTH)."
        success=1
        break
    elif [[ "$STATUS" == "exited" || "$STATUS" == "dead" || "$STATUS" == "notfound" ]]; then
        echo "Jellyfin failed to start (status: $STATUS). Recent logs:"
        docker logs --tail 30 "$CONTAINER_NAME"
        exit 1
    fi
done

if [[ $success -eq 0 ]]; then
    echo "Jellyfin is not healthy after $max_wait seconds, please check logs."
    docker logs --tail 30 "$CONTAINER_NAME"
    exit 1
fi

# -----------------------------
# Step 7: Extra permission check for /config
# -----------------------------
if docker logs --tail 30 "$CONTAINER_NAME" 2>&1 | grep -q 'Access to the path .* is denied'; then
    echo "Error: Permission problem detected in Jellyfin logs!"
    echo "Please fix permissions on the /config directory."
    echo "For example, run:"
    echo "  sudo chown -R 1000:1000 $JELLYFIN_DIR/config"
    echo "  sudo chmod -R 755 $JELLYFIN_DIR/config"
    exit 1
fi

echo "Jellyfin setup completed successfully!"
echo "You can check logs with: docker logs -f $CONTAINER_NAME"