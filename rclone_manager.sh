#!/bin/bash
# rclone_manager.sh - Secure rclone configuration and mount management
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RCLONE_BASE_DIR="${HOME}/.config/rclone-manager"
readonly DEFAULT_CONFIG_FILE="${RCLONE_BASE_DIR}/config/rclone.conf"
readonly RCLONE_MOUNT_DIR="${RCLONE_BASE_DIR}/mounts"
readonly RCLONE_CACHE_DIR="${RCLONE_BASE_DIR}/cache"
readonly RCLONE_LOG_DIR="${RCLONE_BASE_DIR}/logs"
readonly SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

# Possible existing config locations
readonly -a EXISTING_CONFIGS=(
    "${HOME}/.config/rclone/rclone.conf"
    "/opt/docker/jellyfin/rclone/config/rclone.conf"
    "${HOME}/.rclone.conf"
)

RCLONE_CONFIG_FILE="$DEFAULT_CONFIG_FILE"

readonly -a SUPPORTED_REMOTES=("gdriver" "onedrive" "dropbox" "backblaze")

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly -a TEMP_FILES=()
cleanup() {
    local exit_code=$?
    for temp_file in "${TEMP_FILES[@]}"; do
        [[ -f "$temp_file" ]] && rm -f "$temp_file"
    done
    exit $exit_code
}
trap cleanup EXIT INT TERM

log() {
    local level="$1"; shift
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $*" >&2 ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $*" >&2 ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $*" >&2 ;;
    esac
}

safe_read() {
    local prompt="$1" var_name="$2" timeout="${3:-30}"
    echo -n "$prompt"
    if ! read -r -t "$timeout" "$var_name"; then
        log "ERROR" "Input timeout or read failed"
        return 1
    fi
}

validate_remote_name() {
    local remote="$1"
    for supported in "${SUPPORTED_REMOTES[@]}"; do
        [[ "$remote" == "$supported" ]] && return 0
    done
    log "ERROR" "Unsupported remote type: $remote"
    return 1
}

validate_path() {
    local path="$1" base_dir="${2:-$RCLONE_BASE_DIR}"
    local resolved_path
    if ! resolved_path=$(realpath -m "$path" 2>/dev/null); then
        log "ERROR" "Invalid path: $path"
        return 1
    fi
    if [[ "$resolved_path" != "$base_dir"* ]] && [[ "$resolved_path" != "$HOME"* ]]; then
        log "ERROR" "Path not in allowed range: $resolved_path"
        return 1
    fi
    echo "$resolved_path"
}

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        log "ERROR" "Command not found: $cmd"
        return 1
    fi
}

safe_mkdir() {
    local dir="$1" mode="${2:-755}"
    if ! validate_path "$dir" >/dev/null; then
        log "ERROR" "Directory path validation failed: $dir"
        return 1
    fi
    local old_umask; old_umask=$(umask); umask 077
    [[ ! -d "$dir" ]] && mkdir -p "$dir"
    chmod "$mode" "$dir"
    umask "$old_umask"
}

show_main_menu() {
    clear
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}        rclone Cloud Storage Manager${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo "1) Initialize rclone environment"
    echo "2) Configure cloud remotes"
    echo "3) Mount cloud storage"
    echo "4) Unmount cloud storage"
    echo "5) Show mount status"
    echo "6) Manage systemd services"
    echo "7) View logs"
    echo "8) Test connections"
    echo "9) Cleanup cache"
    echo "10) Backup configuration"
    echo "0) Exit"
    echo ""
}

get_menu_choice() {
    local choice
    if ! read -r -t 30 choice; then
        log "ERROR" "Input timeout"
        return 1
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 0 ]] || [[ "$choice" -gt 10 ]]; then
        log "ERROR" "Invalid option: $choice"
        return 1
    fi
    echo "$choice"
}

detect_existing_config() {
    log "INFO" "Detecting existing rclone configurations..."
    
    for config_path in "${EXISTING_CONFIGS[@]}"; do
        if [[ -f "$config_path" ]] && [[ -s "$config_path" ]]; then
            log "INFO" "Found existing config: $config_path"
            
            # Test if config has any remotes
            local remotes
            remotes=$(rclone listremotes --config="$config_path" 2>/dev/null | wc -l)
            if [[ "$remotes" -gt 0 ]]; then
                echo "Found working config with $remotes remotes: $config_path"
                echo "Remotes:"
                rclone listremotes --config="$config_path" | while read -r remote; do
                    [[ -n "$remote" ]] && echo "  - ${remote%:}"
                done
                echo ""
                
                local choice
                if safe_read "Use this existing config? (y/n): " choice && [[ "$choice" == "y" ]]; then
                    RCLONE_CONFIG_FILE="$config_path"
                    log "INFO" "Using existing config: $RCLONE_CONFIG_FILE"
                    return 0
                fi
            fi
        fi
    done
    
    log "INFO" "No existing config selected, will use: $DEFAULT_CONFIG_FILE"
    return 1
}

check_existing_mounts() {
    log "INFO" "Checking for existing mounts..."
    
    # Check common mount points
    local -a common_mount_dirs=(
        "/mnt"
        "/media"
        "${HOME}/mounts"
        "/opt/docker/jellyfin/rclone"
    )
    
    for mount_dir in "${common_mount_dirs[@]}"; do
        if [[ -d "$mount_dir" ]]; then
            for remote in "${SUPPORTED_REMOTES[@]}"; do
                local potential_mount="$mount_dir/$remote"
                if [[ -d "$potential_mount" ]] && mountpoint -q "$potential_mount" 2>/dev/null; then
                    log "WARN" "Found existing mount: $potential_mount"
                    echo "Existing mount detected: $potential_mount"
                    
                    local choice
                    if safe_read "Unmount this before proceeding? (y/n): " choice && [[ "$choice" == "y" ]]; then
                        if fusermount -u "$potential_mount" 2>/dev/null; then
                            log "INFO" "Successfully unmounted: $potential_mount"
                        else
                            log "WARN" "Failed to unmount: $potential_mount"
                        fi
                    fi
                fi
            done
        fi
    done
}

init_environment() {
init_environment() {
    log "INFO" "Initializing rclone environment..."
    
    if ! check_command rclone; then
        log "ERROR" "rclone not installed. Install with: curl https://rclone.org/install.sh | sudo bash"
        return 1
    fi
    
    # Check for existing configurations first
    detect_existing_config
    
    # Check for existing mounts
    check_existing_mounts
    
    safe_mkdir "$RCLONE_BASE_DIR" 700
    safe_mkdir "${DEFAULT_CONFIG_FILE%/*}" 700
    safe_mkdir "$RCLONE_MOUNT_DIR" 755
    safe_mkdir "$RCLONE_CACHE_DIR" 700
    safe_mkdir "$RCLONE_LOG_DIR" 755
    safe_mkdir "$SYSTEMD_USER_DIR" 755
    
    for remote in "${SUPPORTED_REMOTES[@]}"; do
        safe_mkdir "$RCLONE_MOUNT_DIR/$remote" 755
    done
    
    # Only create new config if using default location and it doesn't exist
    if [[ "$RCLONE_CONFIG_FILE" == "$DEFAULT_CONFIG_FILE" ]] && [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
        touch "$RCLONE_CONFIG_FILE"
        chmod 600 "$RCLONE_CONFIG_FILE"
        log "INFO" "Created new config file: $RCLONE_CONFIG_FILE"
    fi
    
    systemctl --user daemon-reload &>/dev/null || true
    log "INFO" "Environment initialized successfully"
    log "INFO" "Using config file: $RCLONE_CONFIG_FILE"
}
}

configure_remote() {
    log "INFO" "Configuring cloud remotes..."
    
    if [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
        log "ERROR" "Config file not found: $RCLONE_CONFIG_FILE"
        log "INFO" "Run initialization first or check config file location"
        return 1
    fi
    
    if [[ -s "$RCLONE_CONFIG_FILE" ]]; then
        log "INFO" "Current remotes in $RCLONE_CONFIG_FILE:"
        rclone listremotes --config="$RCLONE_CONFIG_FILE" | while read -r remote; do
            [[ -n "$remote" ]] && echo "  - ${remote%:}"
        done
        echo ""
    fi
    
    local choice
    if ! safe_read "Add/modify remote configuration? (y/n): " choice; then
        return 1
    fi
    [[ "$choice" != "y" ]] && return 0
    
    if [[ -f "$RCLONE_CONFIG_FILE" ]]; then
        local backup_file="${RCLONE_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$RCLONE_CONFIG_FILE" "$backup_file" && log "INFO" "Config backed up to: $backup_file"
    fi
    
    if ! rclone config --config="$RCLONE_CONFIG_FILE"; then
        log "ERROR" "Configuration failed"
        return 1
    fi
    
    chmod 600 "$RCLONE_CONFIG_FILE"
    log "INFO" "Configuration completed"
}

mount_remote() {
    log "INFO" "Mounting cloud storage..."
    
    if [[ ! -f "$RCLONE_CONFIG_FILE" ]] || [[ ! -s "$RCLONE_CONFIG_FILE" ]]; then
        log "ERROR" "No rclone configuration found"
        return 1
    fi
    
    local -a available_remotes
    while IFS= read -r remote; do
        [[ -n "$remote" ]] && available_remotes+=("${remote%:}")
    done < <(rclone listremotes --config="$RCLONE_CONFIG_FILE")
    
    if [[ ${#available_remotes[@]} -eq 0 ]]; then
        log "ERROR" "No remotes configured"
        return 1
    fi
    
    echo "Available remotes:"
    for i in "${!available_remotes[@]}"; do
        echo "  $((i+1))) ${available_remotes[i]}"
    done
    
    local choice
    if ! safe_read "Select remote [1-${#available_remotes[@]}]: " choice; then
        return 1
    fi
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#available_remotes[@]} ]]; then
        log "ERROR" "Invalid selection: $choice"
        return 1
    fi
    
    local remote_name="${available_remotes[$((choice-1))]}"
    
    if ! validate_remote_name "$remote_name"; then
        return 1
    fi
    
    local mount_point="$RCLONE_MOUNT_DIR/$remote_name"
    
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log "WARN" "$remote_name already mounted"
        local remount_choice
        if safe_read "Remount? (y/n): " remount_choice && [[ "$remount_choice" == "y" ]]; then
            fusermount -u "$mount_point" 2>/dev/null || return 1
        else
            return 0
        fi
    fi
    
    log "INFO" "Testing connection..."
    if ! timeout 30 rclone lsd "${remote_name}:" --config="$RCLONE_CONFIG_FILE" &>/dev/null; then
        log "ERROR" "Cannot connect to: $remote_name"
        return 1
    fi
    
    safe_mkdir "$mount_point" 755
    create_mount_service "$remote_name" "$mount_point"
    
    if systemctl --user start "rclone-mount-${remote_name}.service"; then
        local timeout=30
        while [[ $timeout -gt 0 ]]; do
            if mountpoint -q "$mount_point" 2>/dev/null; then
                log "INFO" "$remote_name mounted successfully at: $mount_point"
                systemctl --user enable "rclone-mount-${remote_name}.service"
                return 0
            fi
            sleep 1; ((timeout--))
        done
        log "ERROR" "Mount timeout"
        systemctl --user stop "rclone-mount-${remote_name}.service"
        return 1
    else
        log "ERROR" "Service start failed"
        return 1
    fi
}

create_mount_service() {
    local remote_name="$1" mount_point="$2"
    local service_file="$SYSTEMD_USER_DIR/rclone-mount-${remote_name}.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=rclone mount for $remote_name
After=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p $mount_point
ExecStart=/usr/bin/rclone mount ${remote_name}: $mount_point \\
    --config $RCLONE_CONFIG_FILE \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 10G \\
    --vfs-cache-max-age 4h \\
    --buffer-size 256M \\
    --dir-cache-time 48h \\
    --umask 002 \\
    --log-level INFO \\
    --log-file $RCLONE_LOG_DIR/${remote_name}.log \\
    --cache-dir $RCLONE_CACHE_DIR
ExecStop=/bin/fusermount -u $mount_point
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
EOF
    
    chmod 644 "$service_file"
    systemctl --user daemon-reload
}

unmount_remote() {
    log "INFO" "Unmounting cloud storage..."
    
    local -a mounted_remotes
    for remote in "${SUPPORTED_REMOTES[@]}"; do
        local mount_point="$RCLONE_MOUNT_DIR/$remote"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            mounted_remotes+=("$remote")
        fi
    done
    
    if [[ ${#mounted_remotes[@]} -eq 0 ]]; then
        log "INFO" "No mounted remotes found"
        return 0
    fi
    
    echo "Mounted remotes:"
    for i in "${!mounted_remotes[@]}"; do
        echo "  $((i+1))) ${mounted_remotes[i]}"
    done
    echo "  $((${#mounted_remotes[@]}+1))) Unmount all"
    
    local choice
    if ! safe_read "Select [1-$((${#mounted_remotes[@]}+1))]: " choice; then
        return 1
    fi
    
    if [[ "$choice" -eq $((${#mounted_remotes[@]}+1)) ]]; then
        for remote in "${mounted_remotes[@]}"; do
            unmount_single_remote "$remote"
        done
    else
        local remote_name="${mounted_remotes[$((choice-1))]}"
        unmount_single_remote "$remote_name"
    fi
}

unmount_single_remote() {
    local remote_name="$1"
    local mount_point="$RCLONE_MOUNT_DIR/$remote_name"
    local service_name="rclone-mount-${remote_name}.service"
    
    systemctl --user stop "$service_name" 2>/dev/null || true
    systemctl --user disable "$service_name" 2>/dev/null || true
    
    if mountpoint -q "$mount_point" 2>/dev/null; then
        fusermount -u "$mount_point" 2>/dev/null || fusermount -uz "$mount_point" 2>/dev/null || true
    fi
    
    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        log "INFO" "$remote_name unmounted successfully"
    else
        log "ERROR" "Failed to unmount $remote_name"
        return 1
    fi
}

show_mount_status() {
    log "INFO" "Mount status:"
    
    for remote in "${SUPPORTED_REMOTES[@]}"; do
        local mount_point="$RCLONE_MOUNT_DIR/$remote"
        [[ ! -d "$mount_point" ]] && continue
        
        echo -n "$remote: "
        if mountpoint -q "$mount_point" 2>/dev/null; then
            echo -e "${GREEN}Mounted${NC}"
            local content_count
            content_count=$(ls -1 "$mount_point" 2>/dev/null | wc -l)
            echo "  Location: $mount_point"
            echo "  Items: $content_count"
        else
            echo -e "${RED}Not mounted${NC}"
        fi
    done
}

manage_services() {
    echo "Service management:"
    echo "1) Start all services"
    echo "2) Stop all services"
    echo "3) Restart all services"
    echo "4) Show service status"
    
    local choice
    if ! safe_read "Select [1-4]: " choice; then
        return 1
    fi
    
    case "$choice" in
        1) for remote in "${SUPPORTED_REMOTES[@]}"; do
               systemctl --user start "rclone-mount-${remote}.service" 2>/dev/null || true
           done ;;
        2) for remote in "${SUPPORTED_REMOTES[@]}"; do
               systemctl --user stop "rclone-mount-${remote}.service" 2>/dev/null || true
           done ;;
        3) for remote in "${SUPPORTED_REMOTES[@]}"; do
               systemctl --user restart "rclone-mount-${remote}.service" 2>/dev/null || true
           done ;;
        4) for remote in "${SUPPORTED_REMOTES[@]}"; do
               echo -n "$remote: "
               if systemctl --user is-active --quiet "rclone-mount-${remote}.service" 2>/dev/null; then
                   echo -e "${GREEN}Active${NC}"
               else
                   echo -e "${RED}Inactive${NC}"
               fi
           done ;;
    esac
}

view_logs() {
    if [[ ! -d "$RCLONE_LOG_DIR" ]]; then
        log "ERROR" "Log directory not found"
        return 1
    fi
    
    echo "Available logs:"
    local -a log_files=("$RCLONE_LOG_DIR"/*.log)
    
    if [[ ! -f "${log_files[0]}" ]]; then
        log "INFO" "No log files found"
        return 0
    fi
    
    for i in "${!log_files[@]}"; do
        echo "  $((i+1))) $(basename "${log_files[i]}")"
    done
    
    local choice
    if ! safe_read "Select log [1-${#log_files[@]}]: " choice; then
        return 1
    fi
    
    if [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#log_files[@]} ]]; then
        tail -f "${log_files[$((choice-1))]}"
    fi
}

test_connections() {
    log "INFO" "Testing connections..."
    
    if [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
        log "ERROR" "No configuration file found"
        return 1
    fi
    
    while read -r remote; do
        if [[ -n "$remote" ]]; then
            remote_clean="${remote%:}"
            echo -n "Testing $remote_clean: "
            if timeout 30 rclone lsd "$remote" --config="$RCLONE_CONFIG_FILE" &>/dev/null; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}FAILED${NC}"
            fi
        fi
    done < <(rclone listremotes --config="$RCLONE_CONFIG_FILE")
}

cleanup_cache() {
    if [[ -d "$RCLONE_CACHE_DIR" ]]; then
        local cache_size
        cache_size=$(du -sh "$RCLONE_CACHE_DIR" | cut -f1)
        log "INFO" "Current cache size: $cache_size"
        
        local choice
        if safe_read "Clear cache? (y/n): " choice && [[ "$choice" == "y" ]]; then
            rm -rf "${RCLONE_CACHE_DIR:?}"/*
            log "INFO" "Cache cleared"
        fi
    else
        log "INFO" "No cache directory found"
    fi
}

backup_config() {
    if [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
        log "ERROR" "No configuration to backup"
        return 1
    fi
    
    local backup_file="${RCLONE_BASE_DIR}/rclone-backup-$(date +%Y%m%d_%H%M%S).conf"
    if cp "$RCLONE_CONFIG_FILE" "$backup_file"; then
        chmod 600 "$backup_file"
        log "INFO" "Configuration backed up to: $backup_file"
    else
        log "ERROR" "Backup failed"
        return 1
    fi
}

main() {
    while true; do
        show_main_menu
        echo -n "Enter option [0-10]: "
        
        local choice
        if ! choice=$(get_menu_choice); then
            continue
        fi
        
        case $choice in
            1) init_environment ;;
            2) configure_remote ;;
            3) mount_remote ;;
            4) unmount_remote ;;
            5) show_mount_status ;;
            6) manage_services ;;
            7) view_logs ;;
            8) test_connections ;;
            9) cleanup_cache ;;
            10) backup_config ;;
            0) log "INFO" "Goodbye!"; exit 0 ;;
            *) log "ERROR" "Invalid option"; sleep 1 ;;
        esac
        
        echo ""; echo "Press Enter to continue..."
        read -r
    done
}

main "$@"
