#!/bin/bash
# Enhanced rclone Cloud Storage Manager v3.0
# Modern interactive interface with improved user experience

#set -euo pipefail

# ============================================================================
# Terminal Setup and Constants
# ============================================================================

# Ensure proper terminal behavior
[[ -t 0 ]] && [[ -t 1 ]] && stty sane 2>/dev/null || true

# Script information
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="3.0.0"
readonly SCRIPT_NAME="rclone Cloud Storage Manager"

# Directories
readonly SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

# Supported remote types
readonly -a SUPPORTED_REMOTES=("gdrive" "onedrive" "dropbox" "backblaze" "box" "mega" "pcloud")

# Colors and formatting
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
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly MAGENTA=''
    readonly CYAN=''
    readonly WHITE=''
    readonly BOLD=''
    readonly DIM=''
    readonly RESET=''
    readonly CLEAR_LINE=''
fi

# Icons
readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="✗"
readonly ICON_WARNING="⚠"
readonly ICON_INFO="ℹ"
readonly ICON_MOUNTED="◉"
readonly ICON_UNMOUNTED="○"
readonly ICON_ARROW="→"

# Global state variables
declare -g RCLONE_BIN_PATH=""
declare -g TERMINAL_WIDTH=80

# ============================================================================
# Core Utility Functions
# ============================================================================

# Get terminal width
update_terminal_width() {
    if command -v tput &>/dev/null; then
        TERMINAL_WIDTH=$(tput cols 2>/dev/null || echo 80)
    else
        TERMINAL_WIDTH=80
    fi
    [[ $TERMINAL_WIDTH -lt 60 ]] && TERMINAL_WIDTH=60
}

# Print centered text
print_centered() {
    local text="$1"
    local width="${2:-$TERMINAL_WIDTH}"
    local text_length=${#text}
    local padding=$(( (width - text_length) / 2 ))
    [[ $padding -lt 0 ]] && padding=0
    printf "%*s%s\n" $padding "" "$text"
}

# Print a horizontal line
print_line() {
    local char="${1:-─}"
    local width="${2:-$TERMINAL_WIDTH}"
    printf '%*s\n' "$width" '' | tr ' ' "$char"
}

# Print formatted header
print_header() {
    local title="$1"
    update_terminal_width
    echo
    print_line "═"
    print_centered "${BOLD}${BLUE}$title${RESET}"
    print_line "═"
    echo
}

# Print section header
print_section() {
    local title="$1"
    echo
    echo -e "${CYAN}${BOLD}$title${RESET}"
    print_line "─" 40
}

# Logging with improved formatting
log() {
    local level="$1"
    shift
    local timestamp=$(date '+%H:%M:%S')
    
    case "$level" in
        "SUCCESS")
            echo -e "${GREEN}${ICON_SUCCESS}${RESET} $*" >&2
            ;;
        "ERROR")
            echo -e "${RED}${ICON_ERROR} [$timestamp]${RESET} $*" >&2
            ;;
        "WARNING")
            echo -e "${YELLOW}${ICON_WARNING} [$timestamp]${RESET} $*" >&2
            ;;
        "INFO")
            echo -e "${CYAN}${ICON_INFO}${RESET} $*" >&2
            ;;
        "DEBUG")
            [[ "${DEBUG:-0}" == "1" ]] && echo -e "${DIM}[DEBUG $timestamp]${RESET} $*" >&2
            ;;
    esac
}

# Show spinner for long operations
spinner() {
    local pid=$1
    local message="${2:-Processing...}"
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    # Hide cursor
    tput civis 2>/dev/null || true
    
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr:i++%${#spinstr}:1}
        printf "${CLEAR_LINE}${CYAN}%s${RESET} %s" "$temp" "$message"
        sleep 0.1
    done
    
    # Restore cursor
    tput cnorm 2>/dev/null || true
    
    # Check if process succeeded
    wait "$pid"
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        printf "${CLEAR_LINE}${GREEN}${ICON_SUCCESS}${RESET} %s\n" "$message"
    else
        printf "${CLEAR_LINE}${RED}${ICON_ERROR}${RESET} %s\n" "$message"
    fi
    
    return $exit_code
}

# Progress bar
show_progress() {
    local current=$1
    local total=$2
    local message="${3:-Progress}"
    local width=40
    
    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    printf "${CLEAR_LINE}%s [" "$message"
    printf "%${filled}s" '' | tr ' ' '█'
    printf "%${empty}s" '' | tr ' ' '░'
    printf "] %3d%%\r" "$percent"
    
    [[ $current -eq $total ]] && echo
}

# ============================================================================
# Interactive Input Functions
# ============================================================================

# Select menu using arrow keys
select_option() {
    local prompt="$1"
    shift
    local options=("$@")
    local selected=0
    local key=""
    
    # Hide cursor
    tput civis 2>/dev/null || true
    
    # Clear any pending input
    while read -r -t 0.001; do :; done
    
    while true; do
        # Clear previous menu
        [[ $selected -gt 0 ]] && printf "\033[%dA" "${#options[@]}"
        
        # Display options
        for i in "${!options[@]}"; do
            if [[ $i -eq $selected ]]; then
                echo -e "${CYAN}${ICON_ARROW}${RESET} ${BOLD}${options[i]}${RESET}"
            else
                echo -e "  ${options[i]}"
            fi
        done
        
        # Read key input
        IFS= read -rsn1 key
        
        # Handle arrow keys (escape sequences)
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            case $key in
                '[A') # Up arrow
                    ((selected--))
                    [[ $selected -lt 0 ]] && selected=$((${#options[@]} - 1))
                    ;;
                '[B') # Down arrow
                    ((selected++))
                    [[ $selected -ge ${#options[@]} ]] && selected=0
                    ;;
            esac
        elif [[ $key == '' ]]; then # Enter key
            break
        fi
    done
    
    # Restore cursor
    tput cnorm 2>/dev/null || true
    
    return $selected
}

# Get user input with validation
get_input() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    local validation_func="${4:-}"
    
    while true; do
        if [[ -n "$default" ]]; then
            printf "%s [%s]: " "$prompt" "$default"
        else
            printf "%s: " "$prompt"
        fi
        
        local input
        IFS= read -r input
        
        # Use default if empty
        [[ -z "$input" ]] && input="$default"
        
        # Skip if still empty and no default
        if [[ -z "$input" ]] && [[ -z "$default" ]]; then
            log "WARNING" "Input cannot be empty"
            continue
        fi
        
        # Validate if function provided
        if [[ -n "$validation_func" ]]; then
            if ! $validation_func "$input"; then
                continue
            fi
        fi
        
        # Set the variable
        printf -v "$var_name" "%s" "$input"
        return 0
    done
}

# Confirm action with y/n
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    
    while true; do
        printf "%s (y/n) [%s]: " "$prompt" "$default"
        
        local answer
        IFS= read -r answer
        
        # Use default if empty
        [[ -z "$answer" ]] && answer="$default"
        
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) log "WARNING" "Please answer 'y' or 'n'" ;;
        esac
    done
}

# Pause and wait for user
pause() {
    local message="${1:-Press any key to continue...}"
    echo
    printf "${DIM}%s${RESET}" "$message"
    read -rsn1
    echo
}

# ============================================================================
# System Detection and Validation
# ============================================================================

# Find rclone binary
find_rclone_binary() {
    local search_paths=(
        "/usr/bin/rclone"
        "/usr/local/bin/rclone"
        "${HOME}/.local/bin/rclone"
        "${HOME}/bin/rclone"
    )
    
    # Check if in PATH first
    if command -v rclone &>/dev/null; then
        RCLONE_BIN_PATH=$(command -v rclone)
        log "DEBUG" "Found rclone in PATH: $RCLONE_BIN_PATH"
        return 0
    fi
    
    # Check specific paths
    for path in "${search_paths[@]}"; do
        if [[ -x "$path" ]]; then
            RCLONE_BIN_PATH="$path"
            log "DEBUG" "Found rclone at: $RCLONE_BIN_PATH"
            return 0
        fi
    done
    
    log "DEBUG" "rclone not found in system"
    return 1
}

# Check command availability
check_command() {
    local cmd="$1"
    local package="${2:-$cmd}"
    
    if ! command -v "$cmd" &>/dev/null; then
        log "WARNING" "Command not found: $cmd (install package: $package)"
        return 1
    fi
    return 0
}

# Validate path is safe
validate_path() {
    local path="$1"
    
    # Check for dangerous patterns
    if [[ "$path" =~ \.\. ]] || [[ "$path" =~ [[:space:]] ]]; then
        log "ERROR" "Invalid path: contains dangerous characters"
        return 1
    fi
    
    # Resolve to absolute path
    local abs_path
    abs_path=$(realpath -m "$path" 2>/dev/null) || {
        log "ERROR" "Cannot resolve path: $path"
        return 1
    }
    
    echo "$abs_path"
    return 0
}

# ============================================================================
# Directory and Permission Management
# ============================================================================

# Detect user permissions and set directories
detect_permissions() {
    local user=$(whoami)
    log "INFO" "Detecting permissions for user: $user"

    # 统一配置目录（保持在用户目录）
    export RCLONE_CONFIG_FILE="${HOME}/.config/rclone/rclone.conf"

    # 统一所有运行目录到 /mnt 下
    export RCLONE_MOUNT_DIR="/mnt/rclone_mounts"
    export RCLONE_CACHE_DIR="/mnt/rclone_cache"
    export RCLONE_LOG_DIR="/mnt/rclone_logs"

    # 保证 /mnt 及子目录可用（自动 sudo 授权给当前用户）
    ensure_dir_with_sudo "/mnt"
    ensure_dir_with_sudo "$RCLONE_MOUNT_DIR"
    ensure_dir_with_sudo "$RCLONE_CACHE_DIR"
    ensure_dir_with_sudo "$RCLONE_LOG_DIR"

    # 配置文件夹如不存在也创建（不需要 sudo）
    if [[ ! -d "${HOME}/.config/rclone" ]]; then
        log "WARNING" "配置目录 ${HOME}/.config/rclone 不存在，自动创建"
        mkdir -p "${HOME}/.config/rclone" || { log "ERROR" "创建失败"; exit 1; }
    fi
    # 配置文件
    if [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
        log "WARNING" "未检测到 rclone.conf，首次使用需通过 rclone config 配置"
    fi
}

# Create directory with proper permissions
create_directory() {
    local dir="$1"
    local mode="${2:-755}"
    local description="${3:-directory}"
    
    if [[ -d "$dir" ]]; then
        if [[ -w "$dir" ]]; then
            return 0
        else
            log "ERROR" "No write permission for $description: $dir"
            return 1
        fi
    fi
    
    log "INFO" "Creating $description: $dir"
    if mkdir -p "$dir" 2>/dev/null && chmod "$mode" "$dir" 2>/dev/null; then
        return 0
    else
        log "ERROR" "Failed to create $description: $dir"
        return 1
    fi
}

# ============================================================================
# Installation Functions
# ============================================================================

# Install rclone
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
        0) # Official installer
            log "INFO" "Using official rclone installer..."
            (
                curl -s https://rclone.org/install.sh | sudo bash
            ) &
            spinner $! "Installing rclone"
            ;;
        1) # Package manager
            if command -v apt-get &>/dev/null; then
                log "INFO" "Installing via apt-get..."
                (
                    sudo apt-get update && sudo apt-get install -y rclone
                ) &
                spinner $! "Installing rclone"
            elif command -v yum &>/dev/null; then
                log "INFO" "Installing via yum..."
                (
                    sudo yum install -y rclone
                ) &
                spinner $! "Installing rclone"
            else
                log "ERROR" "No supported package manager found"
                return 1
            fi
            ;;
        2) # Manual download
            log "INFO" "Downloading rclone to user directory..."
            local install_dir="${HOME}/.local/bin"
            create_directory "$install_dir" 755 "user bin directory"
            
            (
                cd /tmp
                curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip
                unzip -q rclone-current-linux-amd64.zip
                cp rclone-*/rclone "$install_dir/"
                chmod +x "$install_dir/rclone"
                rm -rf rclone-*
            ) &
            spinner $! "Downloading and installing rclone"
            
            # Add to PATH if needed
            if ! grep -q "$install_dir" "${HOME}/.bashrc" 2>/dev/null; then
                echo "export PATH=\"$install_dir:\$PATH\"" >> "${HOME}/.bashrc"
                log "INFO" "Added $install_dir to PATH in .bashrc"
            fi
            ;;
        3) # Skip
            log "WARNING" "Skipping rclone installation"
            return 1
            ;;
    esac
    
    # Verify installation
    if find_rclone_binary; then
        log "SUCCESS" "rclone installed successfully at: $RCLONE_BIN_PATH"
        return 0
    else
        log "ERROR" "rclone installation failed"
        return 1
    fi
}

# ============================================================================
# Configuration Management
# ============================================================================

# Configure remote storage
configure_remote() {
    print_header "Cloud Storage Configuration"
    
    if [[ -z "$RCLONE_BIN_PATH" ]]; then
        log "ERROR" "rclone not found. Please install it first."
        pause
        return 1
    fi
    
    # Show current remotes
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
        # Backup existing config
        if [[ -f "$RCLONE_CONFIG_FILE" ]] && [[ -s "$RCLONE_CONFIG_FILE" ]]; then
            local backup="${RCLONE_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$RCLONE_CONFIG_FILE" "$backup"
            log "INFO" "Configuration backed up to: $backup"
        fi
        
        # Run rclone config
        "$RCLONE_BIN_PATH" config --config="$RCLONE_CONFIG_FILE"
        
        # Set proper permissions
        chmod 600 "$RCLONE_CONFIG_FILE"
        log "SUCCESS" "Configuration updated"
    fi
}

# ============================================================================
# Mount Management
# ============================================================================

# Mount a remote
mount_remote() {
    print_header "Mount Cloud Storage"
    
    if [[ -z "$RCLONE_BIN_PATH" ]]; then
        log "ERROR" "rclone not found"
        pause
        return 1
    fi
    
    # Get available remotes
    local remotes
    remotes=$("$RCLONE_BIN_PATH" listremotes --config="$RCLONE_CONFIG_FILE" 2>/dev/null | sed 's/:$//')
    
    if [[ -z "$remotes" ]]; then
        log "ERROR" "No remotes configured"
        pause
        return 1
    fi
    
    # Create menu options
    local remote_array=()
    while IFS= read -r remote; do
        remote_array+=("$remote")
    done <<< "$remotes"
    remote_array+=("Cancel")
    
    echo "Select remote to mount:"
    select_option "Choose remote" "${remote_array[@]}"
    local choice=$?
    
    # Check if cancelled
    if [[ $choice -eq ${#remote_array[@]}-1 ]]; then
        return 0
    fi
    
    local remote_name="${remote_array[$choice]}"
    local mount_point="$RCLONE_MOUNT_DIR/$remote_name"
    
    # Check if already mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log "WARNING" "$remote_name is already mounted"
        if confirm "Remount?"; then
            unmount_single "$remote_name"
        else
            return 0
        fi
    fi
    
    # Test connection
    log "INFO" "Testing connection to $remote_name..."
    if ! "$RCLONE_BIN_PATH" lsd "${remote_name}:" --config="$RCLONE_CONFIG_FILE" &>/dev/null; then
        log "ERROR" "Cannot connect to $remote_name"
        pause
        return 1
    fi
    log "SUCCESS" "Connection successful"
    
    # Create mount point
    create_directory "$mount_point" 755 "mount point"
    
    # Create systemd service
    create_systemd_service "$remote_name" "$mount_point"
    
    # Start service
    log "INFO" "Starting mount service..."
    if systemctl --user start "rclone-mount-${remote_name}.service"; then
        # Wait for mount
        local timeout=30
        while [[ $timeout -gt 0 ]]; do
            if mountpoint -q "$mount_point" 2>/dev/null; then
                log "SUCCESS" "$remote_name mounted at: $mount_point"
                systemctl --user enable "rclone-mount-${remote_name}.service" 2>/dev/null
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

# Create systemd service file
create_systemd_service() {
    local remote="$1"
    local mount_point="$2"
    local service_file="$SYSTEMD_USER_DIR/rclone-mount-${remote}.service"
    
    create_directory "$SYSTEMD_USER_DIR" 755 "systemd directory"
    
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

# Unmount a single remote
unmount_single() {
    local remote="$1"
    local mount_point="$RCLONE_MOUNT_DIR/$remote"
    local service="rclone-mount-${remote}.service"
    
    log "INFO" "Unmounting $remote..."
    
    # Stop service
    systemctl --user stop "$service" 2>/dev/null || true
    systemctl --user disable "$service" 2>/dev/null || true
    
    # Force unmount if needed
    if mountpoint -q "$mount_point" 2>/dev/null; then
        fusermount -u "$mount_point" 2>/dev/null || fusermount -uz "$mount_point" 2>/dev/null || true
    fi
    
    # Verify
    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        log "SUCCESS" "$remote unmounted"
        return 0
    else
        log "ERROR" "Failed to unmount $remote"
        return 1
    fi
}

# Unmount interface
unmount_remote() {
    print_header "Unmount Cloud Storage"
    
    # Find mounted remotes
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
    
    # Create menu
    local options=("${mounted[@]}")
    options+=("Unmount all" "Cancel")
    
    echo "Select remote to unmount:"
    select_option "Choose remote" "${options[@]}"
    local choice=$?
    
    # Handle choice
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

# ============================================================================
# Status and Information
# ============================================================================

# Show detailed status
show_status() {
    print_header "System Status"
    
    # System info
    print_section "System Information"
    echo -e "  User: ${BOLD}$(whoami)${RESET}"
    echo -e "  rclone: ${RCLONE_BIN_PATH:-${RED}Not found${RESET}}"
    echo -e "  Config: $RCLONE_CONFIG_FILE"
    echo -e "  Mounts: $RCLONE_MOUNT_DIR"
    
    # Remote status
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
                    
                    # Show size if available
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
    
    # Service status
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

# ============================================================================
# Main Functions
# ============================================================================

# Initialize environment
initialize_environment() {
    print_header "Environment Initialization"
    
    # check fuse allow_other
    check_fuse_allow_other

    # Detect permissions
    detect_permissions
    
    # Find or install rclone
    if ! find_rclone_binary; then
        log "WARNING" "rclone not found"
        if confirm "Install rclone now?"; then
            install_rclone
        fi
    fi
    
    # Create directories
    print_section "Creating Directories"
    
    local dirs=(
        "$(dirname "$RCLONE_CONFIG_FILE"):700:config"
        "$RCLONE_MOUNT_DIR:755:mount"
        "$RCLONE_CACHE_DIR:700:cache"
        "$RCLONE_LOG_DIR:755:logs"
    )
    
    for dir_spec in "${dirs[@]}"; do
        IFS=: read -r dir mode desc <<< "$dir_spec"
        create_directory "$dir" "$mode" "$desc directory"
    done
    
    # Create config file if needed
    if [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
        touch "$RCLONE_CONFIG_FILE"
        chmod 600 "$RCLONE_CONFIG_FILE"
        log "SUCCESS" "Created config file: $RCLONE_CONFIG_FILE"
    fi
    
    # Reload systemd
    systemctl --user daemon-reload 2>/dev/null || true
    
    log "SUCCESS" "Environment initialized"
    pause
}

check_fuse_allow_other() {
    if [[ ! -f /etc/fuse.conf ]]; then
        log "WARNING" "/etc/fuse.conf 不存在，部分 FUSE 挂载可能失败。"
        return 1
    fi

    if grep -q "^user_allow_other" /etc/fuse.conf; then
        log "INFO" "/etc/fuse.conf 已正确设置 user_allow_other"
        return 0
    else
        log "WARNING" "/etc/fuse.conf 未设置 user_allow_other，建议添加以支持 --allow-other"
        echo
        echo "如需自动设置，请输入管理员密码："
        if confirm "是否自动为你添加 user_allow_other 到 /etc/fuse.conf？"; then
            echo | sudo tee -a /etc/fuse.conf > /dev/null  # 保证有换行
            echo "user_allow_other" | sudo tee -a /etc/fuse.conf
            log "SUCCESS" "已添加 user_allow_other 到 /etc/fuse.conf"
            return 0
        else
            echo -e "\n请手动执行：\n${YELLOW}echo 'user_allow_other' | sudo tee -a /etc/fuse.conf${RESET}\n"
            pause
            return 1
        fi
    fi
}

# Show main menu
show_main_menu() {
    while true; do
        print_header "$SCRIPT_NAME v$SCRIPT_VERSION"
        
        local menu_items=(
            "Initialize Environment"
            "Configure Cloud Storage"
            "Mount Cloud Storage"
            "Unmount Cloud Storage"
            "Show System Status"
            "View Logs"
            "Clean Cache"
            "Exit"
        )
        
        select_option "Main Menu" "${menu_items[@]}"
        local choice=$?
        
        case $choice in
            0) initialize_environment ;;
            1) configure_remote ;;
            2) mount_remote ;;
            3) unmount_remote ;;
            4) show_status ;;
            5) view_logs ;;
            6) clean_cache ;;
            7) exit 0 ;;
        esac
    done
}

# View logs
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
    
    # Create menu
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
    
    # View options
    local view_options=(
        "Last 50 lines"
        "Last 100 lines"
        "Follow live"
        "View all"
        "Cancel"
    )
    
    echo
    echo "How to view the log?"
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

# Clean cache
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

# ============================================================================
# Entry Point
# ============================================================================
ensure_dir_with_sudo() {
    local dir="$1"
    local who="$USER"

    # 检查 sudo 可用
    if ! command -v sudo >/dev/null 2>&1; then
        log "ERROR" "本功能需要 sudo，但未检测到 sudo 命令。"
        exit 1
    fi

    # 目录已存在
    if [[ -d "$dir" ]]; then
        if [[ -w "$dir" ]]; then
            log "INFO" "目录 $dir 已存在且有写权限"
            return 0
        else
            log "WARNING" "目录 $dir 存在但无写权限，尝试用 sudo 提升权限（chown/chmod）"
            echo "⏳ sudo chown $who:$who $dir"
            if sudo chown "$who":"$who" "$dir"; then
                log "INFO" "归属更改成功"
            else
                log "ERROR" "chown 失败，检查目录权限或父目录"
                exit 1
            fi
            echo "⏳ sudo chmod 775 $dir"
            if sudo chmod 775 "$dir"; then
                log "INFO" "权限更改成功"
            else
                log "ERROR" "chmod 失败，检查目录权限或父目录"
                exit 1
            fi
            if [[ -w "$dir" ]]; then
                log "SUCCESS" "sudo 权限提升成功，$dir 现可写"
            else
                log "ERROR" "sudo 权限提升后依然无写权限"
                exit 1
            fi
        fi
    else
        log "INFO" "目录 $dir 不存在，将用 sudo 新建并授权"
        echo "⏳ sudo mkdir -p $dir"
        if sudo mkdir -p "$dir"; then
            log "INFO" "目录新建成功"
        else
            log "ERROR" "mkdir 失败，可能父目录无权限"
            exit 1
        fi
        echo "⏳ sudo chown $who:$who $dir"
        if sudo chown "$who":"$who" "$dir"; then
            log "INFO" "归属更改成功"
        else
            log "ERROR" "chown 失败"
            exit 1
        fi
        echo "⏳ sudo chmod 775 $dir"
        if sudo chmod 775 "$dir"; then
            log "INFO" "权限更改成功"
        else
            log "ERROR" "chmod 失败"
            exit 1
        fi
        if [[ -d "$dir" && -w "$dir" ]]; then
            log "SUCCESS" "sudo 创建并授权 $dir 成功"
        else
            log "ERROR" "目录已创建但依然无写权限"
            exit 1
        fi
    fi
}

main() {
    # Check terminal
    if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
        echo "Error: This script requires an interactive terminal" >&2
        exit 1
    fi
    
    # Trap signals
    trap 'echo -e "\n${RED}Interrupted${RESET}"; exit 130' INT TERM
    
    # Show menu
    show_main_menu
}

# Run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi