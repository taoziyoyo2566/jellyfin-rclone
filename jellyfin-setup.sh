#!/bin/bash
# jellyfin_setup_menu.sh - Jellyfin + rclone + Cloudflare Tunnel setup script
# Part 1: Basic framework and initialization functions (steps 1-4)

# Project basic configuration
PROJECT_DIR="/opt/docker/jellyfin"
RCLONE_DIR="$PROJECT_DIR/rclone"
RCLONE_CONFIG_DIR="$RCLONE_DIR/config"
RCLONE_CONFIG_FILE="$RCLONE_CONFIG_DIR/rclone.conf"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
CURRENT_MODE_FILE="$PROJECT_DIR/.current_mode"
ENV_FILE="$PROJECT_DIR/.env"

# Docker Compose files
COMPOSE_INITIAL="$PROJECT_DIR/docker-compose.initial.yml"
COMPOSE_TUNNEL="$PROJECT_DIR/docker-compose.tunnel.yml"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Simple logging function
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$PROJECT_DIR/setup.log" 2>/dev/null || echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$PROJECT_DIR/setup.log" 2>/dev/null || echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$PROJECT_DIR/setup.log" 2>/dev/null || echo -e "${RED}[ERROR]${NC} $*"
}

# Show header
show_header() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}  Jellyfin + rclone + Cloudflare Tunnel Setup${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
}

# Show main menu
show_main_menu() {
    echo -e "${YELLOW}Please select an operation:${NC}"
    echo ""
    echo "  === Initialization ==="
    echo "  1) Create directory structure and set permissions"
    echo "  2) Install required software (rclone, cloudflared, docker)"
    echo ""
    echo "  === Storage Configuration ==="
    echo "  3) Configure rclone"
    echo "  4) Mount cloud storage"
    echo ""
    echo "  === Jellyfin Deployment ==="
    echo "  5) Deploy Jellyfin (initial mode)"
    echo "  6) Configure Cloudflare Tunnel"
    echo "  7) Switch to Tunnel mode"
    echo ""
    echo "  === Management Tools ==="
    echo "  8) View service status"
    echo "  9) Troubleshooting tools"
    echo "  10) Stop/delete services"
    echo ""
    echo "  0) Exit"
    echo ""
    echo -n "Enter option [0-10]: "
}

# Check if running as root user
check_user() {
    if [[ $EUID -eq 0 ]]; then
        log_warn "Detected root user"
        echo "It's recommended to run as a regular user, script will request sudo when needed"
        echo -n "Continue? (y/n): "
        read -r choice
        if [[ "$choice" != "y" ]]; then
            exit 1
        fi
    fi
}

# Get current running mode
get_current_mode() {
    if [ -f "$CURRENT_MODE_FILE" ]; then
        cat "$CURRENT_MODE_FILE"
    else
        echo "none"
    fi
}

# Set current running mode - FIXED: Use secure temp file
set_current_mode() {
    local old_umask=$(umask)
    umask 077  # Secure umask for temp file
    local temp_file=$(mktemp)
    echo "$1" > "$temp_file"
    mv "$temp_file" "$CURRENT_MODE_FILE"
    chmod 600 "$CURRENT_MODE_FILE"
    umask "$old_umask"
}

# Load environment variables
load_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
}

# Check if docker-compose files exist
check_compose_files() {
    local missing_files=()
    
    if [ ! -f "$COMPOSE_INITIAL" ]; then
        missing_files+=("docker-compose.initial.yml")
    fi
    
    if [ ! -f "$COMPOSE_TUNNEL" ]; then
        missing_files+=("docker-compose.tunnel.yml")
    fi
    
    if [ ${#missing_files[@]} -ne 0 ]; then
        log_error "Missing Docker Compose files:"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
        echo ""
        echo "Please ensure the following files exist in the project directory:"
        echo "  - $COMPOSE_INITIAL"
        echo "  - $COMPOSE_TUNNEL"
        echo ""
        echo "You can get these files from the project repository or create them manually."
        return 1
    fi
    
    return 0
}

# 1. Create directory structure and set permissions - FIXED
create_directory_structure() {
    log_info "=== Create directory structure and set permissions ==="
    echo ""
    
    # Check if already exists
    if [ -d "$PROJECT_DIR" ]; then
        log_warn "Project directory already exists: $PROJECT_DIR"
        echo -n "Reinitialize directory structure? (y/n): "
        read -r choice
        if [[ "$choice" != "y" ]]; then
            echo "Keeping existing directory structure"
            # Still need to check docker-compose files
            if ! check_compose_files; then
                log_error "Please prepare docker-compose files first"
                # Automatically detect and copy docker-compose files if available
                copy_compose_files
            fi
            echo ""
            echo "Press Enter to return to main menu..."
            read
            return 0
        fi
    fi
    
    echo "Creating project directory structure..."
    
    # Create main directories
    sudo mkdir -p "$PROJECT_DIR"
    sudo mkdir -p "$RCLONE_DIR"
    sudo mkdir -p "$RCLONE_CONFIG_DIR"
    sudo mkdir -p "$SCRIPTS_DIR/backup"
    
    # Create mount point directories
    sudo mkdir -p "$RCLONE_DIR/gdriver"
    sudo mkdir -p "$RCLONE_DIR/onedrive"
    sudo mkdir -p "$RCLONE_DIR/backblaze"
    
    # Create local media directory (optional)
    echo -n "Create local media directory ~/media? (y/n): "
    read -r choice
    if [[ "$choice" == "y" ]]; then
        mkdir -p ~/media/{movies,tvshows,music,photos}
        log_info "Local media directory created"
    fi
    
    # Set permissions - FIXED: Don't use recursive on sensitive dirs
    echo "Setting directory permissions..."
    sudo chown -R $(id -u):$(id -g) "$PROJECT_DIR"
    sudo chmod 755 "$PROJECT_DIR"
    sudo chmod 755 "$RCLONE_DIR"
    sudo chmod 755 "$SCRIPTS_DIR"
    sudo chmod -R 755 "$SCRIPTS_DIR/backup"
    sudo chmod 755 "$RCLONE_DIR/gdriver"
    sudo chmod 755 "$RCLONE_DIR/onedrive" 
    sudo chmod 755 "$RCLONE_DIR/backblaze"
    # Config directory gets restrictive permissions
    sudo chmod 700 "$RCLONE_CONFIG_DIR"
    
    # Create environment variables file - FIXED: Secure creation
    if [ ! -f "$ENV_FILE" ]; then
        log_info "Creating environment variables file..."
        local old_umask=$(umask)
        umask 077  # Secure umask
        cat > "$ENV_FILE" << EOF
# Jellyfin project environment configuration
# Generated: $(date)

# Basic configuration
PROJECT_DIR=$PROJECT_DIR
RCLONE_CONFIG=$RCLONE_CONFIG_FILE
USER_UID=$(id -u)
USER_GID=$(id -g)
USER_NAME=$(whoami)

# Jellyfin configuration
TIMEZONE=Asia/Shanghai
JELLYFIN_DOMAIN=media.taoziyoyo.com
JELLYFIN_HTTP_PORT=8096
JELLYFIN_HTTPS_PORT=8920

# Resource limits
JELLYFIN_CPU_LIMIT=2
JELLYFIN_MEMORY_LIMIT=2G

# rclone mount configuration
RCLONE_CACHE_DIR=/tmp/rclone-cache
RCLONE_CACHE_MAX_SIZE=10G
RCLONE_CACHE_MAX_AGE=4h
EOF
        chmod 600 "$ENV_FILE"
        umask "$old_umask"
        log_info "Environment variables file created: $ENV_FILE"
    else
        echo "Environment variables file already exists"
    fi
    
    # Create .current_mode file
    if [ ! -f "$CURRENT_MODE_FILE" ]; then
        set_current_mode "none"
    fi
    
    # Remind user to prepare docker-compose files
    echo ""
    log_warn "Important reminder:"
    echo "Please ensure the following Docker Compose files are placed in the project directory:"
    echo "  1. $COMPOSE_INITIAL"
    echo "  2. $COMPOSE_TUNNEL"
    echo ""
    
    # Check docker-compose files
    if check_compose_files; then
        log_info "Docker Compose files check passed!"
    else
        log_error "Please prepare docker-compose files before continuing"
    fi
    
    # Show creation results
    echo ""
    log_info "Directory structure creation completed!"
    echo "Project root directory: $PROJECT_DIR"
    echo "Directory structure:"
    echo "  $PROJECT_DIR/"
    echo "  ├── docker-compose.initial.yml"
    echo "  ├── docker-compose.tunnel.yml"
    echo "  ├── .env (permissions: 600)"
    echo "  ├── .current_mode (permissions: 600)"
    echo "  ├── rclone/"
    echo "  │   ├── config/ (permissions: 700)"
    echo "  │   │   └── rclone.conf"
    echo "  │   ├── gdriver/"
    echo "  │   ├── onedrive/"
    echo "  │   └── backblaze/"
    echo "  └── scripts/"
    echo "      └── backup/"
    
    echo ""
    echo "Press Enter to return to main menu..."
    read
}

copy_compose_files() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local copied=0

    for fname in docker-compose.initial.yml docker-compose.tunnel.yml; do
        if [ ! -f "$PROJECT_DIR/$fname" ]; then
            if [ -f "$script_dir/$fname" ]; then
                cp "$script_dir/$fname" "$PROJECT_DIR/$fname"
                log_info "Automatically copied $fname to $PROJECT_DIR"
                copied=1
            fi
        fi
    done

    if [ $copied -eq 0 ]; then
        log_warn "No docker-compose configuration files found to copy."
        echo "Please ensure:"
        echo "  - $PROJECT_DIR/docker-compose.initial.yml"
        echo "  - $PROJECT_DIR/docker-compose.tunnel.yml"
        echo "are present. You can copy them from the script directory or project repository."
    fi
}

# 2. Install required software
install_required_software() {
    log_info "=== Install required software ==="
    echo ""
    
    # Detect system type
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        log_error "Cannot detect system type"
        return 1
    fi
    
    log_info "Detected system: $OS"
    echo ""
    
    # Install Docker
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        case $OS in
            ubuntu|debian)
                curl -fsSL https://get.docker.com | sudo bash
                ;;
            centos|rhel|fedora)
                sudo yum install -y yum-utils
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                sudo yum install -y docker-ce docker-ce-cli containerd.io
                ;;
            *)
                log_error "Unsupported system: $OS"
                echo "Please install Docker manually"
                ;;
        esac
        
        # Start Docker
        sudo systemctl enable docker
        sudo systemctl start docker
        
        # Add current user to docker group
        sudo usermod -aG docker $(whoami)
        log_warn "User added to docker group, may need to re-login to take effect"
    else
        log_info "Docker already installed"
    fi
    
    # Install Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        echo "Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    else
        log_info "Docker Compose already installed"
    fi
    
    # Install rclone
    if ! command -v rclone &> /dev/null; then
        echo "Installing rclone..."
        curl https://rclone.org/install.sh | sudo bash
    else
        log_info "rclone already installed, version: $(rclone version | head -1)"
    fi
    
    # Install cloudflared
    if ! command -v cloudflared &> /dev/null; then
        echo "Installing cloudflared..."
        
        # Download based on system architecture
        ARCH=$(uname -m)
        case $ARCH in
            x86_64)
                CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
                ;;
            aarch64|arm64)
                CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
                ;;
            armv7l)
                CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
                ;;
            *)
                log_error "Unsupported system architecture: $ARCH"
                return 1
                ;;
        esac
        
        sudo wget -O /usr/local/bin/cloudflared "$CLOUDFLARED_URL"
        sudo chmod +x /usr/local/bin/cloudflared
    else
        log_info "cloudflared already installed"
    fi
    
    # Install other necessary tools
    echo "Installing other necessary tools..."
    case $OS in
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y curl wget tree htop fuse
            ;;
        centos|rhel|fedora)
            sudo yum install -y curl wget tree htop fuse
            ;;
    esac
    
    # Handle fusermount3 symlink
    if ! command -v fusermount3 &> /dev/null && command -v fusermount &> /dev/null; then
        echo "Creating fusermount3 symlink..."
        sudo ln -sf /usr/bin/fusermount /usr/bin/fusermount3
        log_info "fusermount3 symlink created"
    fi
    
    echo ""
    log_info "Software installation completed!"
    echo "Installed:"
    echo "  - Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
    echo "  - Docker Compose: $(docker-compose --version 2>/dev/null || echo 'Not installed')"
    echo "  - rclone: $(rclone --version 2>/dev/null | head -1 || echo 'Not installed')"
    echo "  - cloudflared: $(cloudflared --version 2>/dev/null || echo 'Not installed')"
    
    echo ""
    echo "Press Enter to return to main menu..."
    read
}

# 3. Configure rclone - FIXED: Secure config file creation
configure_rclone() {
    log_info "=== Configure rclone ==="
    echo ""
    
    # Check configuration directory
    if [ ! -d "$RCLONE_CONFIG_DIR" ]; then
        log_error "Configuration directory does not exist, please run step 1 first"
        echo "Press Enter to return to main menu..."
        read
        return 1
    fi
    
    # Check existing configuration
    if [ -f "$RCLONE_CONFIG_FILE" ]; then
        log_warn "Found existing rclone configuration"
        echo "Configuration file path: $RCLONE_CONFIG_FILE"
        echo "Configured remote storage:"
        rclone listremotes --config="$RCLONE_CONFIG_FILE"
        echo ""
        echo -n "Add new remote storage or modify existing configuration? (y/n): "
        read -r choice
        if [[ "$choice" != "y" ]]; then
            echo "Keeping existing configuration"
            echo "Press Enter to return to main menu..."
            read
            return 0
        fi
    else
        echo "Configuration file will be created at: $RCLONE_CONFIG_FILE"
        # FIXED: Pre-create config file with secure permissions
        local old_umask=$(umask)
        umask 077
        touch "$RCLONE_CONFIG_FILE"
        chmod 600 "$RCLONE_CONFIG_FILE"
        umask "$old_umask"
    fi
    
    echo ""
    echo "Starting rclone configuration..."
    echo ""
    echo "Recommended remote storage configurations:"
    echo "  1. Google Drive - suggested name: gdriver"
    echo "  2. OneDrive - suggested name: onedrive"
    echo "  3. Backblaze B2 - suggested name: backblaze (optional)"
    echo ""
    log_warn "Note: Please use the suggested naming when configuring"
    echo ""
    echo "Press Enter to start configuration..."
    read
    
    # Run rclone configuration, explicitly specify configuration file path
    rclone config --config="$RCLONE_CONFIG_FILE"
    
    # Ensure configuration file permissions are correct
    if [ -f "$RCLONE_CONFIG_FILE" ]; then
        chmod 600 "$RCLONE_CONFIG_FILE"
    fi
    
    # Verify configuration
    echo ""
    echo "Verifying configuration..."
    if [ -f "$RCLONE_CONFIG_FILE" ]; then
        log_info "Configuration file saved"
        echo "Configured remote storage:"
        rclone listremotes --config="$RCLONE_CONFIG_FILE"
        
        # Test connections
        echo ""
        echo "Testing remote connections..."
        for remote in $(rclone listremotes --config="$RCLONE_CONFIG_FILE" | sed 's/://'); do
            echo -n "Testing $remote: "
            if rclone lsd "${remote}:" --config="$RCLONE_CONFIG_FILE" &>/dev/null; then
                echo -e "${GREEN}Connection successful${NC}"
            else
                echo -e "${RED}Connection failed${NC}"
            fi
        done
    else
        log_error "Configuration file creation failed"
    fi
    
    echo ""
    echo "Press Enter to return to main menu..."
    read
}

# 4. Mount cloud storage menu
mount_cloud_storage_menu() {
    while true; do
        clear
        log_info "=== Mount cloud storage ==="
        echo ""
        echo "  1) Mount Google Drive"
        echo "  2) Mount OneDrive"
        echo "  3) Mount Backblaze"
        echo "  4) View mount status"
        echo "  5) Unmount all mounts"
        echo "  0) Return to main menu"
        echo ""
        echo -n "Please select [0-5]: "
        read -r choice
        
        case $choice in
            1)
                mount_storage "gdriver" "Google Drive"
                ;;
            2)
                mount_storage "onedrive" "OneDrive"
                ;;
            3)
                mount_storage "backblaze" "Backblaze"
                ;;
            4)
                show_mount_status
                ;;
            5)
                unmount_all_storage
                ;;
            0)
                return 0
                ;;
            *)
                log_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Generic mount function - FIXED: Secure mount point creation
mount_storage() {
    local remote_name=$1
    local display_name=$2
    local mount_point="$RCLONE_DIR/$remote_name"
    
    log_info "=== Mount $display_name ==="
    echo ""
    
    # Check and fix fusermount3 issue
    if ! command -v fusermount3 &> /dev/null; then
        log_warn "Detected missing fusermount3"
        
        # Check if fusermount exists
        if command -v fusermount &> /dev/null; then
            echo "Creating fusermount3 symlink..."
            sudo ln -sf /usr/bin/fusermount /usr/bin/fusermount3
            log_info "fusermount3 symlink created"
        else
            log_error "fusermount not found in system"
            echo "Please install fuse first: sudo apt-get install fuse"
            echo "Press Enter to continue..."
            read
            return 1
        fi
    fi
    
    # Check configuration
    if ! rclone listremotes --config="$RCLONE_CONFIG_FILE" 2>/dev/null | grep -q "^${remote_name}:"; then
        log_error "$remote_name configuration not found"
        echo "Please configure $remote_name in rclone first"
        echo "Press Enter to continue..."
        read
        return 1
    fi
    
    # Test remote connection
    echo "Testing remote connection..."
    if ! rclone lsd "${remote_name}:" --config="$RCLONE_CONFIG_FILE" &>/dev/null; then
        log_error "Cannot connect to $display_name"
        echo "Please check network connection and authentication information"
        echo "Press Enter to continue..."
        read
        return 1
    fi
    
    # Check mount point
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_warn "$display_name already mounted"
        echo "Press Enter to continue..."
        read
        return 0
    fi
    
    # Configure fuse to allow other users access
    if [ -f /etc/fuse.conf ]; then
        if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
            echo "Configuring fuse..."
            echo "user_allow_other" | sudo tee -a /etc/fuse.conf > /dev/null
        fi
    else
        log_warn "/etc/fuse.conf does not exist, creating default configuration"
        echo "user_allow_other" | sudo tee /etc/fuse.conf > /dev/null
    fi
    
    # Create mount point directory - FIXED: Secure permissions
    sudo mkdir -p "$mount_point"
    sudo chown $(id -u):$(id -g) "$mount_point"
    sudo chmod 755 "$mount_point"  # Explicit safe permissions
    
    # Create systemd service
    echo "Creating systemd service..."
    sudo tee "/etc/systemd/system/rclone-${remote_name}.service" > /dev/null << EOF
[Unit]
Description=rclone mount for $display_name
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p $mount_point
ExecStartPre=/bin/bash -c 'if ! command -v fusermount3 &>/dev/null && command -v fusermount &>/dev/null; then ln -sf /usr/bin/fusermount /usr/bin/fusermount3; fi'
ExecStart=/usr/bin/rclone mount ${remote_name}: $mount_point \\
    --config $RCLONE_CONFIG_FILE \\
    --allow-other \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 10G \\
    --vfs-cache-max-age 4h \\
    --vfs-read-chunk-size 128M \\
    --vfs-read-chunk-size-limit 2G \\
    --buffer-size 256M \\
    --dir-cache-time 48h \\
    --poll-interval 60s \\
    --umask 002 \\
    --log-level INFO \\
    --log-file /var/log/rclone-${remote_name}.log
ExecStop=/bin/fusermount -u $mount_point
Restart=on-failure
RestartSec=30
User=$(whoami)
Group=$(id -gn)
Environment="PATH=/usr/bin:/bin:/usr/local/bin:/sbin:/usr/sbin"

[Install]
WantedBy=multi-user.target
EOF

    # Create log file - FIXED: Secure log file creation
    local old_umask=$(umask)
    umask 022  # Allow group/other read for log files
    sudo touch "/var/log/rclone-${remote_name}.log"
    sudo chown $(whoami):$(id -gn) "/var/log/rclone-${remote_name}.log"
    sudo chmod 644 "/var/log/rclone-${remote_name}.log"
    umask "$old_umask"
    
    # Reload systemd and start service
    sudo systemctl daemon-reload
    sudo systemctl enable "rclone-${remote_name}.service"
    sudo systemctl start "rclone-${remote_name}.service"
    
    # Check mount status
    echo "Waiting for mount to complete..."
    sleep 5
    
    if sudo systemctl is-active --quiet "rclone-${remote_name}.service"; then
        log_info "$display_name mounted successfully"
        echo "Mount point: $mount_point"
        echo "View content:"
        ls -la "$mount_point" 2>/dev/null | head -5 || echo "Cannot list content temporarily"
    else
        log_error "$display_name mount failed"
        echo "View error information:"
        sudo systemctl status "rclone-${remote_name}.service" --no-pager -l
        echo ""
        echo "View detailed logs:"
        sudo tail -n 20 "/var/log/rclone-${remote_name}.log"
        echo ""
        echo "Possible solutions:"
        echo "1. Manually create symlink: sudo ln -sf /usr/bin/fusermount /usr/bin/fusermount3"
        echo "2. Manual test mount: rclone mount ${remote_name}: $mount_point --config=$RCLONE_CONFIG_FILE --allow-other"
        echo "3. Check system logs: sudo journalctl -xeu rclone-${remote_name}.service"
    fi
    
    echo ""
    echo "Press Enter to continue..."
    read
}

# Show mount status
show_mount_status() {
    log_info "=== Mount status ==="
    echo ""
    
    for remote in gdriver onedrive backblaze; do
        mount_point="$RCLONE_DIR/$remote"
        service_name="rclone-${remote}.service"
        
        echo -n "$remote: "
        if sudo systemctl is-active --quiet "$service_name" 2>/dev/null; then
            echo -e "${GREEN}Mounted${NC}"
            if [ -d "$mount_point" ]; then
                echo "  Content count: $(ls -1 "$mount_point" 2>/dev/null | wc -l) items"
            fi
        else
            echo -e "${RED}Not mounted${NC}"
        fi
    done
    
    echo ""
    echo "Press Enter to continue..."
    read
}

# Unmount all storage
unmount_all_storage() {
    log_warn "=== Unmount all mounts ==="
    echo ""
    
    for remote in gdriver onedrive backblaze; do
        service_name="rclone-${remote}.service"
        if sudo systemctl is-active --quiet "$service_name" 2>/dev/null; then
            echo "Stopping $remote..."
            sudo systemctl stop "$service_name"
            sudo systemctl disable "$service_name"
        fi
    done
    
    log_info "All mounts unmounted"
    echo ""
    echo "Press Enter to continue..."
    read
}

# Part 2 function declarations (empty implementations for now)
deploy_jellyfin_initial() { 
    echo "Feature implemented in part 2"
    echo "Press Enter to continue..."
    read
}

configure_cloudflare_tunnel() { 
    echo "Feature implemented in part 2"
    echo "Press Enter to continue..."
    read
}

switch_to_tunnel_mode() { 
    echo "Feature implemented in part 2"
    echo "Press Enter to continue..."
    read
}

show_service_status() { 
    echo "Feature implemented in part 2"
    echo "Press Enter to continue..."
    read
}

troubleshooting_menu() { 
    echo "Feature implemented in part 2"
    echo "Press Enter to continue..."
    read
}

manage_services_menu() { 
    echo "Feature implemented in part 2"
    echo "Press Enter to continue..."
    read
}

# Main program
main() {
    # Check user
    check_user
    
    while true; do
        show_header
        show_main_menu
        
        read -r choice
        echo ""
        
        case $choice in
            1)
                create_directory_structure
                ;;
            2)
                install_required_software
                ;;
            3)
                configure_rclone
                ;;
            4)
                mount_cloud_storage_menu
                ;;
            5)
                deploy_jellyfin_initial
                ;;
            6)
                configure_cloudflare_tunnel
                ;;
            7)
                switch_to_tunnel_mode
                ;;
            8)
                show_service_status
                ;;
            9)
                troubleshooting_menu
                ;;
            10)
                manage_services_menu
                ;;
            0)
                log_info "Thank you for using! Goodbye!"
                exit 0
                ;;
            *)
                log_error "Invalid option, please select again"
                sleep 2
                ;;
        esac
    done
}

# Run main program
main "$@"