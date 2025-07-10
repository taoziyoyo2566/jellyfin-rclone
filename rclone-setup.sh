#!/bin/bash
# rclone Cloud Storage Manager - Modern Interactive CLI
# Version: 3.1.0
# Language: English only

###############################################################################
# Terminal/Color Setup & Constants
###############################################################################

[[ -t 0 ]] && [[ -t 1 ]] && stty sane 2>/dev/null || true

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="3.1.0"
readonly SCRIPT_NAME="rclone Cloud Storage Manager"
readonly SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

readonly -a SUPPORTED_REMOTES=("gdrive" "onedrive" "dropbox" "backblaze" "box" "mega" "pcloud")

if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly MAGENTA='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly WHITE='\033[0;37m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
    readonly RESET='\033[0m'
    readonly CLEAR_LINE='\033[2K\r'
else
    readonly RED=''; readonly GREEN=''; readonly YELLOW=''
    readonly BLUE=''; readonly MAGENTA=''; readonly CYAN=''
    readonly WHITE=''; readonly BOLD=''; readonly DIM=''
    readonly RESET=''; readonly CLEAR_LINE=''
fi

readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="✗"
readonly ICON_WARNING="⚠"
readonly ICON_INFO="ℹ"
readonly ICON_MOUNTED="◉"
readonly ICON_UNMOUNTED="○"
readonly ICON_ARROW="→"

declare -g RCLONE_BIN_PATH=""
declare -g TERMINAL_WIDTH=80

###############################################################################
# Utility Functions (logging, menu, formatting)
###############################################################################

update_terminal_width() {
    if command -v tput &>/dev/null; then
        TERMINAL_WIDTH=$(tput cols 2>/dev/null || echo 80)
    else
        TERMINAL_WIDTH=80
    fi
    [[ $TERMINAL_WIDTH -lt 60 ]] && TERMINAL_WIDTH=60
}

print_centered() {
    local text="$1"
    local width="${2:-$TERMINAL_WIDTH}"
    local text_length=${#text}
    local padding=$(( (width - text_length) / 2 ))
    [[ $padding -lt 0 ]] && padding=0
    printf "%*s%s\n" $padding "" "$text"
}

print_line() {
    local char="${1:-─}"
    local width="${2:-$TERMINAL_WIDTH}"
    printf '%*s\n' "$width" '' | tr ' ' "$char"
}

print_header() {
    local title="$1"
    update_terminal_width
    echo
    print_line "="
    print_centered "${BOLD}${BLUE}$title${RESET}"
    print_line "="
    echo
}

print_section() {
    local title="$1"
    echo
    echo -e "${CYAN}${BOLD}$title${RESET}"
    print_line "-" 40
}

log() {
    local level="$1"
    shift
    local timestamp=$(date '+%H:%M:%S')
    case "$level" in
        "SUCCESS") echo -e "${GREEN}${ICON_SUCCESS}${RESET} $*" >&2 ;;
        "ERROR")   echo -e "${RED}${ICON_ERROR} [$timestamp]${RESET} $*" >&2 ;;
        "WARNING") echo -e "${YELLOW}${ICON_WARNING} [$timestamp]${RESET} $*" >&2 ;;
        "INFO")    echo -e "${CYAN}${ICON_INFO}${RESET} $*" >&2 ;;
        "DEBUG")   [[ "${DEBUG:-0}" == "1" ]] && echo -e "${DIM}[DEBUG $timestamp]${RESET} $*" >&2 ;;
    esac
}

pause() {
    local message="${1:-Press any key to continue...}"
    echo
    printf "${DIM}%s${RESET}" "$message"
    read -rsn1
    echo
}

select_option() {
    local prompt="$1"
    shift
    local options=("$@")
    local selected=0
    local key=""
    tput civis 2>/dev/null || true
    while read -r -t 0.001; do :; done
    while true; do
        [[ $selected -gt 0 ]] && printf "\033[%dA" "${#options[@]}"
        for i in "${!options[@]}"; do
            if [[ $i -eq $selected ]]; then
                echo -e "${CYAN}${ICON_ARROW}${RESET} ${BOLD}${options[i]}${RESET}"
            else
                echo -e "  ${options[i]}"
            fi
        done
        IFS= read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case $key in
                '[A') ((selected--)); [[ $selected -lt 0 ]] && selected=$((${#options[@]} - 1)) ;;
                '[B') ((selected++)); [[ $selected -ge ${#options[@]} ]] && selected=0 ;;
            esac
        elif [[ $key == '' ]]; then
            break
        fi
    done
    tput cnorm 2>/dev/null || true
    return $selected
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    while true; do
        printf "%s (y/n) [%s]: " "$prompt" "$default"
        local answer; IFS= read -r answer
        [[ -z "$answer" ]] && answer="$default"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) log "WARNING" "Please answer 'y' or 'n'" ;;
        esac
    done
}

###############################################################################
# System Detection and Permission Management
###############################################################################

find_rclone_binary() {
    local search_paths=(
        "/usr/bin/rclone" "/usr/local/bin/rclone"
        "${HOME}/.local/bin/rclone" "${HOME}/bin/rclone"
    )
    if command -v rclone &>/dev/null; then
        RCLONE_BIN_PATH=$(command -v rclone)
        log "DEBUG" "Found rclone in PATH: $RCLONE_BIN_PATH"
        return 0
    fi
    for path in "${search_paths[@]}"; do
        if [[ -x "$path" ]]; then
            RCLONE_BIN_PATH="$path"
            log "DEBUG" "Found rclone at: $RCLONE_BIN_PATH"
            return 0
        fi
    done
    log "DEBUG" "rclone not found"
    return 1
}

ensure_dir_with_sudo() {
    local dir="$1"
    local who="$USER"
    if ! command -v sudo >/dev/null 2>&1; then
        log "ERROR" "sudo is required but not found."
        exit 1
    fi
    if [[ -d "$dir" ]]; then
        if [[ -w "$dir" ]]; then
            log "INFO" "Directory $dir exists and is writable"
            return 0
        else
            log "WARNING" "Directory $dir is not writable, fixing permissions with sudo"
            sudo chown "$who":"$who" "$dir" || { log "ERROR" "chown failed"; exit 1; }
            sudo chmod 775 "$dir" || { log "ERROR" "chmod failed"; exit 1; }
        fi
    else
        log "INFO" "Directory $dir does not exist, creating with sudo"
        sudo mkdir -p "$dir" || { log "ERROR" "mkdir failed"; exit 1; }
        sudo chown "$who":"$who" "$dir" || { log "ERROR" "chown failed"; exit 1; }
        sudo chmod 775 "$dir" || { log "ERROR" "chmod failed"; exit 1; }
    fi
    [[ -w "$dir" ]] || { log "ERROR" "Directory $dir still not writable after sudo"; exit 1; }
    log "SUCCESS" "Directory $dir is ready"
}

detect_permissions() {
    local user=$(whoami)
    log "INFO" "Detecting permissions for user: $user"
    export RCLONE_CONFIG_FILE="${HOME}/.config/rclone/rclone.conf"
    export RCLONE_MOUNT_DIR="/mnt/rclone"
    export RCLONE_CACHE_DIR="${HOME}/.config/rclone/rclone_cache"
    export RCLONE_LOG_DIR="${HOME}/.config/rclone/rclone_logs"
    ensure_dir_with_sudo "/mnt"
    ensure_dir_with_sudo "$RCLONE_MOUNT_DIR"
    ensure_dir_with_sudo "$RCLONE_CACHE_DIR"
    ensure_dir_with_sudo "$RCLONE_LOG_DIR"
    if [[ ! -d "${HOME}/.config/rclone" ]]; then
        log "WARNING" "Config directory ${HOME}/.config/rclone does not exist, creating"
        mkdir -p "${HOME}/.config/rclone" || { log "ERROR" "Failed to create"; exit 1; }
    fi
    if [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
        log "WARNING" "rclone.conf not found, please run rclone config for first use"
    fi
}

###############################################################################
# Installation, Configuration, Help
###############################################################################

install_rclone() {
    print_section "rclone Installation"
    local install_methods=(
        "Official installer (recommended)"
        "Package manager (apt/yum)"
        "Manual download to user directory"
        "Skip installation"
    )
    echo "Select installation method:"
    select_option "Choose installation method" "${install_methods[@]}"
    local choice=$?
    case $choice in
        0) log "INFO" "Using official rclone installer..."
           curl -s https://rclone.org/install.sh | sudo bash ;;
        1) if command -v apt-get &>/dev/null; then
                log "INFO" "Installing via apt-get..."
                sudo apt-get update && sudo apt-get install -y rclone
           elif command -v yum &>/dev/null; then
                sudo yum install -y rclone
           else
                log "ERROR" "No supported package manager found"
                return 1
           fi ;;
        2) log "INFO" "Downloading rclone to user directory..."
           local install_dir="${HOME}/.local/bin"
           mkdir -p "$install_dir"
           cd /tmp
           curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip
           unzip -q rclone-current-linux-amd64.zip
           cp rclone-*/rclone "$install_dir/"
           chmod +x "$install_dir/rclone"
           rm -rf rclone-*
           [[ ":$PATH:" != *":$install_dir:"* ]] && echo "export PATH=\"$install_dir:\$PATH\"" >> "${HOME}/.bashrc"
           ;;
        3) log "WARNING" "Skipping rclone installation"; return 1 ;;
    esac
    if find_rclone_binary; then
        log "SUCCESS" "rclone installed successfully at: $RCLONE_BIN_PATH"
        return 0
    else
        log "ERROR" "rclone installation failed"
        return 1
    fi
}

show_help() {
    cat << 'EOF'
Rclone Cloud Storage Manager - Help Guide
=========================================
QUICK START:
1. Choose "0) Initialize Environment" to check/install dependencies and set up environment.
2. Choose "1) Configure Cloud Storage" to set up your rclone remotes.
3. Choose "3) Mount Cloud Storage" to mount remote drive to local directory.
4. Choose "4) Unmount Cloud Storage" when finished.

MENU OPTIONS:
  0) Initialize Environment       - Setup and check permissions, directories, rclone.
  1) Configure Cloud Storage      - Run rclone config wizard for remote setup.
  2) List Remotes                 - List all configured cloud remotes.
  3) Mount Cloud Storage          - Mount a configured remote.
  4) Unmount Cloud Storage        - Unmount a mounted remote.
  5) Show System Status           - View mount and service status.
  6) View Logs                    - Browse and view mount log files.
  7) Clean Cache                  - Remove cached files.

  h) Show this help message
  q) Exit

TROUBLESHOOTING:
- Use "5) Show System Status" to check if remotes are mounted properly.
- If mounts fail, check /etc/fuse.conf for 'user_allow_other' setting.
- Use "6) View Logs" to debug errors.

For detailed documentation, see: https://rclone.org/docs/
EOF
    pause
}

###############################################################################
# Core Features
###############################################################################

initialize_environment() {
    print_header "Environment Initialization"
    detect_permissions
    install_fuse3 || { log "ERROR" "FUSE 3 (fusermount3) is required. Exiting."; pause; return 1; }
    configure_fuse_allow_other
    if ! find_rclone_binary; then
        log "WARNING" "rclone not found"
        if confirm "Install rclone now?"; then
            install_rclone
        else
            log "ERROR" "rclone is required for this script."
            pause
            return 1
        fi
    fi
    log "SUCCESS" "Environment initialized"
    pause
}
install_fuse3() {
    log "INFO" "Checking fusermount3 (FUSE 3) ..."
    if command -v fusermount3 &>/dev/null; then
        log "SUCCESS" "fusermount3 is already installed."
        return 0
    fi

    log "WARNING" "fusermount3 not found. Trying to install FUSE 3..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y fuse3
    elif command -v yum &>/dev/null; then
        sudo yum install -y fuse3
    elif command -v pacman &>/dev/null; then
        sudo pacman -Sy --noconfirm fuse3
    else
        log "ERROR" "No supported package manager found! Please install FUSE 3 (fusermount3) manually."
        return 1
    fi

    if command -v fusermount3 &>/dev/null; then
        log "SUCCESS" "fusermount3 installed successfully."
        return 0
    else
        log "ERROR" "Failed to install fusermount3. Please check your package manager or install FUSE 3 manually."
        return 1
    fi
}

configure_fuse_allow_other() {
    local fuse_conf="/etc/fuse.conf"
    if [[ ! -f "$fuse_conf" ]]; then
        log "WARNING" "$fuse_conf not found, creating..."
        echo "user_allow_other" | sudo tee "$fuse_conf" >/dev/null
        sudo chmod 644 "$fuse_conf"
    elif ! grep -q "^user_allow_other" "$fuse_conf"; then
        log "INFO" "Enabling 'user_allow_other' in $fuse_conf"
        echo "user_allow_other" | sudo tee -a "$fuse_conf" >/dev/null
    else
        log "SUCCESS" "'user_allow_other' already set in $fuse_conf"
    fi
}

configure_remote() {
    print_header "Cloud Storage Configuration"
    if [[ -z "$RCLONE_BIN_PATH" ]]; then
        log "ERROR" "rclone not found. Please install it first."
        pause
        return 1
    fi
    local remotes
    remotes=$("$RCLONE_BIN_PATH" listremotes --config="$RCLONE_CONFIG_FILE" 2>/dev/null | sed 's/:$//')
    if [[ -n "$remotes" ]]; then
        print_section "Current Remotes"
        while IFS= read -r remote; do
            echo -e "  ${ICON_MOUNTED} ${BOLD}$remote${RESET}"
        done <<< "$remotes"
        echo
    else
        log "INFO" "No remotes configured yet"
    fi
    if confirm "Open rclone configuration wizard?"; then
        if [[ -f "$RCLONE_CONFIG_FILE" ]] && [[ -s "$RCLONE_CONFIG_FILE" ]]; then
            local backup="${RCLONE_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$RCLONE_CONFIG_FILE" "$backup"
            log "INFO" "Configuration backed up to: $backup"
        fi
        "$RCLONE_BIN_PATH" config --config="$RCLONE_CONFIG_FILE"
        chmod 600 "$RCLONE_CONFIG_FILE"
        log "SUCCESS" "Configuration updated"
    fi
    pause
}

list_remotes() {
    print_header "List Remotes"
    if [[ -z "$RCLONE_BIN_PATH" ]]; then
        log "ERROR" "rclone not found."
        pause
        return 1
    fi
    local remotes
    remotes=$("$RCLONE_BIN_PATH" listremotes --config="$RCLONE_CONFIG_FILE" 2>/dev/null | sed 's/:$//')
    if [[ -z "$remotes" ]]; then
        log "INFO" "No remotes configured."
    else
        print_section "Configured Remotes"
        while IFS= read -r remote; do
            echo -e "  ${ICON_MOUNTED} ${BOLD}$remote${RESET}"
        done <<< "$remotes"
    fi
    pause
}

mount_remote() {
    print_header "Mount Cloud Storage"
    if [[ -z "$RCLONE_BIN_PATH" ]]; then
        log "ERROR" "rclone not found"
        pause
        return 1
    fi
    local remotes
    remotes=$("$RCLONE_BIN_PATH" listremotes --config="$RCLONE_CONFIG_FILE" 2>/dev/null | sed 's/:$//')
    if [[ -z "$remotes" ]]; then
        log "ERROR" "No remotes configured"
        pause
        return 1
    fi
    local remote_array=()
    while IFS= read -r remote; do
        remote_array+=("$remote")
    done <<< "$remotes"
    remote_array+=("Cancel")
    echo "Select remote to mount:"
    select_option "Choose remote" "${remote_array[@]}"
    local choice=$?
    if [[ $choice -eq ${#remote_array[@]}-1 ]]; then
        return 0
    fi
    local remote_name="${remote_array[$choice]}"
    local mount_point="$RCLONE_MOUNT_DIR/$remote_name"
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log "WARNING" "$remote_name is already mounted"
        if confirm "Remount?"; then
            unmount_single "$remote_name"
        else
            return 0
        fi
    fi
    log "INFO" "Testing connection to $remote_name..."
    if ! "$RCLONE_BIN_PATH" lsd "${remote_name}:" --config="$RCLONE_CONFIG_FILE" &>/dev/null; then
        log "ERROR" "Cannot connect to $remote_name"
        pause
        return 1
    fi
    log "SUCCESS" "Connection successful"
    mkdir -p "$mount_point"
    create_systemd_service "$remote_name" "$mount_point"
    log "INFO" "Starting mount service..."
    if systemctl --user start "rclone-mount-${remote_name}.service"; then
        local timeout=30
        while [[ $timeout -gt 0 ]]; do
            if mountpoint -q "$mount_point" 2>/dev/null; then
                log "SUCCESS" "$remote_name mounted at: $mount_point"
                systemctl --user enable "rclone-mount-${remote_name}.service" 2>/dev/null
                pause
                return 0
            fi
            sleep 1
            ((timeout--))
        done
        log "ERROR" "Mount timeout"
        systemctl --user stop "rclone-mount-${remote_name}.service"
    else
        log "ERROR" "Failed to start mount service"
    fi
    pause
    return 1
}

create_systemd_service() {
    local remote="$1"
    local mount_point="$2"
    local service_file="$SYSTEMD_USER_DIR/rclone-mount-${remote}.service"
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "$service_file" << EOF
[Unit]
Description=rclone mount for $remote
After=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p $mount_point
ExecStart=$RCLONE_BIN_PATH mount ${remote}: $mount_point \\
    --config $RCLONE_CONFIG_FILE \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 10G \\
    --vfs-cache-max-age 4h \\
    --buffer-size 256M \\
    --dir-cache-time 48h \\
    --poll-interval 15s \\
    --umask 002 \\
    --allow-other \\
    --log-level INFO \\
    --log-file $RCLONE_LOG_DIR/${remote}.log \\
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

unmount_single() {
    local remote="$1"
    local mount_point="$RCLONE_MOUNT_DIR/$remote"
    local service="rclone-mount-${remote}.service"
    log "INFO" "Unmounting $remote..."
    systemctl --user stop "$service" 2>/dev/null || true
    systemctl --user disable "$service" 2>/dev/null || true
    if mountpoint -q "$mount_point" 2>/dev/null; then
        fusermount -u "$mount_point" 2>/dev/null || fusermount -uz "$mount_point" 2>/dev/null || true
    fi
    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        log "SUCCESS" "$remote unmounted"
        return 0
    else
        log "ERROR" "Failed to unmount $remote"
        return 1
    fi
}

unmount_remote() {
    print_header "Unmount Cloud Storage"
    local mounted=()
    if [[ -d "$RCLONE_MOUNT_DIR" ]]; then
        for mount_dir in "$RCLONE_MOUNT_DIR"/*; do
            if [[ -d "$mount_dir" ]] && mountpoint -q "$mount_dir" 2>/dev/null; then
                mounted+=("$(basename "$mount_dir")")
            fi
        done
    fi
    if [[ ${#mounted[@]} -eq 0 ]]; then
        log "INFO" "No mounted remotes found"
        pause
        return 0
    fi
    local options=("${mounted[@]}")
    options+=("Unmount all" "Cancel")
    echo "Select remote to unmount:"
    select_option "Choose remote" "${options[@]}"
    local choice=$?
    if [[ $choice -eq ${#options[@]}-1 ]]; then # Cancel
        return 0
    elif [[ $choice -eq ${#options[@]}-2 ]]; then # Unmount all
        if confirm "Unmount all remotes?"; then
            for remote in "${mounted[@]}"; do
                unmount_single "$remote"
            done
        fi
    else
        unmount_single "${mounted[$choice]}"
    fi
    pause
}

show_status() {
    print_header "System Status"
    print_section "System Information"
    echo -e "  User: ${BOLD}$(whoami)${RESET}"
    echo -e "  rclone: ${RCLONE_BIN_PATH:-${RED}Not found${RESET}}"
    echo -e "  Config: $RCLONE_CONFIG_FILE"
    echo -e "  Mounts: $RCLONE_MOUNT_DIR"
    print_section "Remote Status"
    if [[ -n "$RCLONE_BIN_PATH" ]] && [[ -f "$RCLONE_CONFIG_FILE" ]]; then
        local remotes
        remotes=$("$RCLONE_BIN_PATH" listremotes --config="$RCLONE_CONFIG_FILE" 2>/dev/null | sed 's/:$//')
        if [[ -z "$remotes" ]]; then
            echo "  No remotes configured"
        else
            while IFS= read -r remote; do
                local mount_point="$RCLONE_MOUNT_DIR/$remote"
                if mountpoint -q "$mount_point" 2>/dev/null; then
                    echo -e "  ${GREEN}${ICON_MOUNTED}${RESET} ${BOLD}$remote${RESET} → $mount_point"
                    local size
                    size=$(df -h "$mount_point" 2>/dev/null | awk 'NR==2 {print $2}')
                    [[ -n "$size" ]] && echo -e "     Size: $size"
                else
                    echo -e "  ${DIM}${ICON_UNMOUNTED} $remote${RESET}"
                fi
            done <<< "$remotes"
        fi
    else
        echo "  Cannot read remote status"
    fi
    print_section "Service Status"
    local services
    services=$(systemctl --user list-unit-files --no-legend 2>/dev/null | grep "^rclone-mount-" | awk '{print $1}')
    if [[ -z "$services" ]]; then
        echo "  No services configured"
    else
        while IFS= read -r service; do
            local remote="${service#rclone-mount-}"
            remote="${remote%.service}"
            if systemctl --user is-active --quiet "$service" 2>/dev/null; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${RESET} $remote"
            else
                echo -e "  ${RED}${ICON_ERROR}${RESET} $remote"
            fi
        done <<< "$services"
    fi
    pause
}

view_logs() {
    print_header "View Logs"
    if [[ ! -d "$RCLONE_LOG_DIR" ]]; then
        log "ERROR" "Log directory not found: $RCLONE_LOG_DIR"
        pause
        return 1
    fi
    local logs=("$RCLONE_LOG_DIR"/*.log)
    if [[ ! -e "${logs[0]}" ]]; then
        log "INFO" "No log files found"
        pause
        return 0
    fi
    local options=()
    for log in "${logs[@]}"; do
        local name=$(basename "$log")
        local size=$(du -h "$log" | cut -f1)
        options+=("$name ($size)")
    done
    options+=("Cancel")
    echo "Select log file to view:"
    select_option "Choose log" "${options[@]}"
    local choice=$?
    if [[ $choice -eq ${#options[@]}-1 ]]; then
        return 0
    fi
    local selected_log="${logs[$choice]}"
    local view_options=(
        "Last 50 lines"
        "Last 100 lines"
        "Follow live"
        "View all"
        "Cancel"
    )
    echo; echo "How to view the log?"
    select_option "View method" "${view_options[@]}"
    local view_choice=$?
    case $view_choice in
        0) tail -n 50 "$selected_log" | less ;;
        1) tail -n 100 "$selected_log" | less ;;
        2) tail -f "$selected_log" ;;
        3) less "$selected_log" ;;
        4) return 0 ;;
    esac
}

clean_cache() {
    print_header "Clean Cache"
    if [[ ! -d "$RCLONE_CACHE_DIR" ]]; then
        log "INFO" "Cache directory not found"
        pause
        return 0
    fi
    local size
    size=$(du -sh "$RCLONE_CACHE_DIR" 2>/dev/null | cut -f1)
    print_section "Cache Information"
    echo "  Location: $RCLONE_CACHE_DIR"
    echo "  Size: ${size:-unknown}"
    echo
    if confirm "Clean cache now?"; then
        log "INFO" "Cleaning cache..."
        if rm -rf "${RCLONE_CACHE_DIR:?}"/*; then
            log "SUCCESS" "Cache cleaned"
        else
            log "ERROR" "Failed to clean cache"
        fi
    fi
    pause
}

###############################################################################
# Main Menu
###############################################################################

show_main_menu() {
    while true; do
        print_header "$SCRIPT_NAME v$SCRIPT_VERSION"
        echo " SETUP & INFO:"
        echo "  0) Initialize Environment"
        echo "  1) Configure Cloud Storage"
        echo "  2) List Remotes"
        echo
        echo " MOUNT MANAGEMENT:"
        echo "  3) Mount Cloud Storage"
        echo "  4) Unmount Cloud Storage"
        echo
        echo " SERVICE & STATUS:"
        echo "  5) Show System Status"
        echo "  6) View Logs"
        echo "  7) Clean Cache"
        echo
        echo " HELP & EXIT:"
        echo "  h) Show Help"
        echo "  q) Exit"
        echo "============================================"
        read -p "Choose option: " choice
        case "$choice" in
            0) initialize_environment ;;
            1) configure_remote ;;
            2) list_remotes ;;
            3) mount_remote ;;
            4) unmount_remote ;;
            5) show_status ;;
            6) view_logs ;;
            7) clean_cache ;;
            h|H) show_help ;;
            q|Q) exit 0 ;;
            *) log "ERROR" "Invalid option. Please try again." ;;
        esac
        echo
        read -p "Press Enter to continue..."
    done
}

###############################################################################
# Entry Point
###############################################################################

main() {
    if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
        echo "Error: This script requires an interactive terminal" >&2
        exit 1
    fi
    trap 'echo -e "\n${RED}Interrupted${RESET}"; exit 130' INT TERM
    show_main_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi