#!/bin/bash
# jellyfin_setup_menu.sh - Jellyfin + rclone + Cloudflare Tunnel 菜单式设置脚本
# 第一部分：基础框架和初始化功能（步骤1-4）

# 项目基础配置
PROJECT_DIR="/opt/docker/jellyfin"
RCLONE_DIR="$PROJECT_DIR/rclone"
RCLONE_CONFIG_DIR="$RCLONE_DIR/config"
RCLONE_CONFIG_FILE="$RCLONE_CONFIG_DIR/rclone.conf"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
CURRENT_MODE_FILE="$PROJECT_DIR/.current_mode"
ENV_FILE="$PROJECT_DIR/.env"

# Docker Compose文件
COMPOSE_INITIAL="$PROJECT_DIR/docker-compose.initial.yml"
COMPOSE_TUNNEL="$PROJECT_DIR/docker-compose.tunnel.yml"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 显示标题
show_header() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}  Jellyfin + rclone + Cloudflare Tunnel 设置${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
}

# 显示主菜单
show_main_menu() {
    echo -e "${YELLOW}请选择要执行的操作：${NC}"
    echo ""
    echo "  === 初始化设置 ==="
    echo "  1) 创建目录结构和权限设置"
    echo "  2) 安装必要软件 (rclone, cloudflared, docker)"
    echo ""
    echo "  === 存储配置 ==="
    echo "  3) 配置 rclone"
    echo "  4) 挂载网盘存储"
    echo ""
    echo "  === Jellyfin 部署 ==="
    echo "  5) 部署 Jellyfin (初始模式)"
    echo "  6) 配置 Cloudflare Tunnel"
    echo "  7) 切换到 Tunnel 模式"
    echo ""
    echo "  === 管理工具 ==="
    echo "  8) 查看服务状态"
    echo "  9) 故障排除工具"
    echo "  10) 停止/删除服务"
    echo ""
    echo "  0) 退出"
    echo ""
    echo -n "请输入选项 [0-10]: "
}

# 检查是否为root用户
check_user() {
    if [[ $EUID -eq 0 ]]; then
        echo -e "${RED}警告：检测到root用户${NC}"
        echo "建议使用普通用户运行，脚本会在需要时请求sudo权限"
        echo -n "是否继续？(y/n): "
        read -r choice
        if [[ "$choice" != "y" ]]; then
            exit 1
        fi
    fi
}

# 获取当前运行模式
get_current_mode() {
    if [ -f "$CURRENT_MODE_FILE" ]; then
        cat "$CURRENT_MODE_FILE"
    else
        echo "none"
    fi
}

# 设置当前运行模式
set_current_mode() {
    echo "$1" > "$CURRENT_MODE_FILE"
}

# 加载环境变量
load_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
}

# 检查docker-compose文件是否存在
check_compose_files() {
    local missing_files=()
    
    if [ ! -f "$COMPOSE_INITIAL" ]; then
        missing_files+=("docker-compose.initial.yml")
    fi
    
    if [ ! -f "$COMPOSE_TUNNEL" ]; then
        missing_files+=("docker-compose.tunnel.yml")
    fi
    
    if [ ${#missing_files[@]} -ne 0 ]; then
        echo -e "${RED}错误：缺少以下Docker Compose文件：${NC}"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
        echo ""
        echo "请确保以下文件存在于项目目录中："
        echo "  - $COMPOSE_INITIAL"
        echo "  - $COMPOSE_TUNNEL"
        echo ""
        echo "你可以从项目仓库获取这些文件，或手动创建它们。"
        return 1
    fi
    
    return 0
}

# 1. 创建目录结构和权限设置
create_directory_structure() {
    echo -e "${GREEN}=== 创建目录结构和权限设置 ===${NC}"
    echo ""
    
    # 检查是否已存在
    if [ -d "$PROJECT_DIR" ]; then
        echo -e "${YELLOW}项目目录已存在: $PROJECT_DIR${NC}"
        echo -n "是否重新初始化目录结构？(y/n): "
        read -r choice
        if [[ "$choice" != "y" ]]; then
            echo "保持现有目录结构"
            # 仍然需要检查docker-compose文件
            if ! check_compose_files; then
                echo -e "${RED}请先准备好docker-compose文件${NC}"
            fi
            echo ""
            echo "按 Enter 返回主菜单..."
            read
            return 0
        fi
    fi
    
    echo "创建项目目录结构..."
    
    # 创建主目录
    sudo mkdir -p "$PROJECT_DIR"
    sudo mkdir -p "$RCLONE_DIR"
    sudo mkdir -p "$RCLONE_CONFIG_DIR"
    sudo mkdir -p "$SCRIPTS_DIR/backup"
    
    # 创建挂载点目录
    sudo mkdir -p "$RCLONE_DIR/gdriver"
    sudo mkdir -p "$RCLONE_DIR/onedrive"
    sudo mkdir -p "$RCLONE_DIR/backblaze"
    
    # 创建本地媒体目录（可选）
    echo -n "是否创建本地媒体目录 ~/media？(y/n): "
    read -r choice
    if [[ "$choice" == "y" ]]; then
        mkdir -p ~/media/{movies,tvshows,music,photos}
        echo "本地媒体目录已创建"
    fi
    
    # 设置权限
    echo "设置目录权限..."
    sudo chown -R $(id -u):$(id -g) "$PROJECT_DIR"
    sudo chmod -R 755 "$PROJECT_DIR"
    sudo chmod 700 "$RCLONE_CONFIG_DIR"
    
    # 创建环境变量文件
    if [ ! -f "$ENV_FILE" ]; then
        echo "创建环境变量文件..."
        cat > "$ENV_FILE" << EOF
# Jellyfin 项目环境配置
# 生成时间: $(date)

# 基础配置
PROJECT_DIR=$PROJECT_DIR
RCLONE_CONFIG=$RCLONE_CONFIG_FILE
USER_UID=$(id -u)
USER_GID=$(id -g)
USER_NAME=$(whoami)

# Jellyfin配置
TIMEZONE=Asia/Shanghai
JELLYFIN_DOMAIN=media.taoziyoyo.com
JELLYFIN_HTTP_PORT=8096
JELLYFIN_HTTPS_PORT=8920

# 资源限制
JELLYFIN_CPU_LIMIT=2
JELLYFIN_MEMORY_LIMIT=2G

# rclone挂载配置
RCLONE_CACHE_DIR=/tmp/rclone-cache
RCLONE_CACHE_MAX_SIZE=10G
RCLONE_CACHE_MAX_AGE=4h
EOF
        chmod 600 "$ENV_FILE"
        echo "环境变量文件已创建: $ENV_FILE"
    else
        echo "环境变量文件已存在"
    fi
    
    # 创建 .current_mode 文件
    if [ ! -f "$CURRENT_MODE_FILE" ]; then
        echo "none" > "$CURRENT_MODE_FILE"
    fi
    
    # 提醒用户准备docker-compose文件
    echo ""
    echo -e "${YELLOW}重要提醒：${NC}"
    echo "请确保以下Docker Compose文件已放置在项目目录中："
    echo "  1. $COMPOSE_INITIAL"
    echo "  2. $COMPOSE_TUNNEL"
    echo ""
    
    # 检查docker-compose文件
    if check_compose_files; then
        echo -e "${GREEN}Docker Compose文件检查通过！${NC}"
    else
        echo -e "${RED}请先准备好docker-compose文件再继续后续步骤${NC}"
    fi
    
    # 显示创建结果
    echo ""
    echo -e "${GREEN}目录结构创建完成！${NC}"
    echo "项目根目录: $PROJECT_DIR"
    echo "目录结构："
    echo "  $PROJECT_DIR/"
    echo "  ├── docker-compose.initial.yml"
    echo "  ├── docker-compose.tunnel.yml"
    echo "  ├── .env"
    echo "  ├── .current_mode"
    echo "  ├── rclone/"
    echo "  │   ├── config/"
    echo "  │   │   └── rclone.conf"
    echo "  │   ├── gdriver/"
    echo "  │   ├── onedrive/"
    echo "  │   └── backblaze/"
    echo "  └── scripts/"
    echo "      └── backup/"
    
    echo ""
    echo "按 Enter 返回主菜单..."
    read
}

# 2. 安装必要软件
install_required_software() {
    echo -e "${GREEN}=== 安装必要软件 ===${NC}"
    echo ""
    
    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo -e "${RED}无法检测系统类型${NC}"
        return 1
    fi
    
    echo "检测到系统: $OS"
    echo ""
    
    # 安装 Docker
    if ! command -v docker &> /dev/null; then
        echo "安装 Docker..."
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
                echo -e "${RED}不支持的系统: $OS${NC}"
                echo "请手动安装 Docker"
                ;;
        esac
        
        # 启动 Docker
        sudo systemctl enable docker
        sudo systemctl start docker
        
        # 添加当前用户到 docker 组
        sudo usermod -aG docker $(whoami)
        echo -e "${YELLOW}注意：已将用户添加到 docker 组，可能需要重新登录生效${NC}"
    else
        echo -e "${GREEN}Docker 已安装${NC}"
    fi
    
    # 安装 Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        echo "安装 Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    else
        echo -e "${GREEN}Docker Compose 已安装${NC}"
    fi
    
    # 安装 rclone
    if ! command -v rclone &> /dev/null; then
        echo "安装 rclone..."
        curl https://rclone.org/install.sh | sudo bash
    else
        echo -e "${GREEN}rclone 已安装，版本: $(rclone version | head -1)${NC}"
    fi
    
    # 安装 cloudflared
    if ! command -v cloudflared &> /dev/null; then
        echo "安装 cloudflared..."
        
        # 根据系统架构下载
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
                echo -e "${RED}不支持的系统架构: $ARCH${NC}"
                return 1
                ;;
        esac
        
        sudo wget -O /usr/local/bin/cloudflared "$CLOUDFLARED_URL"
        sudo chmod +x /usr/local/bin/cloudflared
    else
        echo -e "${GREEN}cloudflared 已安装${NC}"
    fi
    
    # 安装其他必要工具
    echo "安装其他必要工具..."
    case $OS in
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y curl wget tree htop fuse
            ;;
        centos|rhel|fedora)
            sudo yum install -y curl wget tree htop fuse
            ;;
    esac
    
    # 处理 fusermount3 软链接
    if ! command -v fusermount3 &> /dev/null && command -v fusermount &> /dev/null; then
        echo "创建 fusermount3 软链接..."
        sudo ln -sf /usr/bin/fusermount /usr/bin/fusermount3
        echo -e "${GREEN}fusermount3 软链接已创建${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}软件安装完成！${NC}"
    echo "已安装："
    echo "  - Docker: $(docker --version 2>/dev/null || echo '未安装')"
    echo "  - Docker Compose: $(docker-compose --version 2>/dev/null || echo '未安装')"
    echo "  - rclone: $(rclone --version 2>/dev/null | head -1 || echo '未安装')"
    echo "  - cloudflared: $(cloudflared --version 2>/dev/null || echo '未安装')"
    
    echo ""
    echo "按 Enter 返回主菜单..."
    read
}

# 3. 配置 rclone
configure_rclone() {
    echo -e "${GREEN}=== 配置 rclone ===${NC}"
    echo ""
    
    # 检查配置目录
    if [ ! -d "$RCLONE_CONFIG_DIR" ]; then
        echo -e "${RED}错误：配置目录不存在，请先执行步骤1${NC}"
        echo "按 Enter 返回主菜单..."
        read
        return 1
    fi
    
    # 检查现有配置
    if [ -f "$RCLONE_CONFIG_FILE" ]; then
        echo -e "${YELLOW}发现现有 rclone 配置${NC}"
        echo "配置文件路径: $RCLONE_CONFIG_FILE"
        echo "已配置的远程存储："
        rclone listremotes --config="$RCLONE_CONFIG_FILE"
        echo ""
        echo -n "是否要添加新的远程存储或修改现有配置？(y/n): "
        read -r choice
        if [[ "$choice" != "y" ]]; then
            echo "保持现有配置"
            echo "按 Enter 返回主菜单..."
            read
            return 0
        fi
    else
        echo "配置文件将创建在: $RCLONE_CONFIG_FILE"
    fi
    
    echo ""
    echo "开始配置 rclone..."
    echo ""
    echo "建议配置以下远程存储："
    echo "  1. Google Drive - 建议命名为: gdriver"
    echo "  2. OneDrive - 建议命名为: onedrive"
    echo "  3. Backblaze B2 - 建议命名为: backblaze (可选)"
    echo ""
    echo -e "${YELLOW}注意：配置时请使用上述建议的命名${NC}"
    echo ""
    echo "按 Enter 开始配置..."
    read
    
    # 运行 rclone 配置，明确指定配置文件路径
    rclone config --config="$RCLONE_CONFIG_FILE"
    
    # 设置配置文件权限
    if [ -f "$RCLONE_CONFIG_FILE" ]; then
        chmod 600 "$RCLONE_CONFIG_FILE"
    fi
    
    # 验证配置
    echo ""
    echo "验证配置..."
    if [ -f "$RCLONE_CONFIG_FILE" ]; then
        echo -e "${GREEN}配置文件已保存${NC}"
        echo "已配置的远程存储："
        rclone listremotes --config="$RCLONE_CONFIG_FILE"
        
        # 测试连接
        echo ""
        echo "测试远程连接..."
        for remote in $(rclone listremotes --config="$RCLONE_CONFIG_FILE" | sed 's/://'); do
            echo -n "测试 $remote: "
            if rclone lsd "${remote}:" --config="$RCLONE_CONFIG_FILE" &>/dev/null; then
                echo -e "${GREEN}连接成功${NC}"
            else
                echo -e "${RED}连接失败${NC}"
            fi
        done
    else
        echo -e "${RED}配置文件创建失败${NC}"
    fi
    
    echo ""
    echo "按 Enter 返回主菜单..."
    read
}

# 4. 挂载网盘存储菜单
mount_cloud_storage_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 挂载网盘存储 ===${NC}"
        echo ""
        echo "  1) 挂载 Google Drive"
        echo "  2) 挂载 OneDrive"
        echo "  3) 挂载 Backblaze"
        echo "  4) 查看挂载状态"
        echo "  5) 卸载所有挂载"
        echo "  0) 返回主菜单"
        echo ""
        echo -n "请选择 [0-5]: "
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
                echo -e "${RED}无效选项${NC}"
                sleep 1
                ;;
        esac
    done
}

# 通用挂载函数
mount_storage() {
    local remote_name=$1
    local display_name=$2
    local mount_point="$RCLONE_DIR/$remote_name"
    
    echo -e "${GREEN}=== 挂载 $display_name ===${NC}"
    echo ""
    
    # 检查并修复 fusermount3 问题
    if ! command -v fusermount3 &> /dev/null; then
        echo -e "${YELLOW}检测到缺少 fusermount3${NC}"
        
        # 检查是否有 fusermount
        if command -v fusermount &> /dev/null; then
            echo "创建 fusermount3 软链接..."
            sudo ln -sf /usr/bin/fusermount /usr/bin/fusermount3
            echo -e "${GREEN}已创建 fusermount3 软链接${NC}"
        else
            echo -e "${RED}错误：系统中没有找到 fusermount${NC}"
            echo "请先安装 fuse: sudo apt-get install fuse"
            echo "按 Enter 继续..."
            read
            return 1
        fi
    fi
    
    # 检查配置
    if ! rclone listremotes --config="$RCLONE_CONFIG_FILE" 2>/dev/null | grep -q "^${remote_name}:"; then
        echo -e "${RED}错误：未找到 $remote_name 配置${NC}"
        echo "请先在 rclone 中配置 $remote_name"
        echo "按 Enter 继续..."
        read
        return 1
    fi
    
    # 测试远程连接
    echo "测试远程连接..."
    if ! rclone lsd "${remote_name}:" --config="$RCLONE_CONFIG_FILE" &>/dev/null; then
        echo -e "${RED}无法连接到 $display_name${NC}"
        echo "请检查网络连接和认证信息"
        echo "按 Enter 继续..."
        read
        return 1
    fi
    
    # 检查挂载点
    if mountpoint -q "$mount_point" 2>/dev/null; then
        echo -e "${YELLOW}$display_name 已经挂载${NC}"
        echo "按 Enter 继续..."
        read
        return 0
    fi
    
    # 配置 fuse 允许其他用户访问
    if [ -f /etc/fuse.conf ]; then
        if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
            echo "配置 fuse..."
            echo "user_allow_other" | sudo tee -a /etc/fuse.conf > /dev/null
        fi
    else
        echo -e "${YELLOW}警告：/etc/fuse.conf 不存在，创建默认配置${NC}"
        echo "user_allow_other" | sudo tee /etc/fuse.conf > /dev/null
    fi
    
    # 创建挂载点目录
    sudo mkdir -p "$mount_point"
    sudo chown $(id -u):$(id -g) "$mount_point"
    
    # 创建 systemd 服务
    echo "创建 systemd 服务..."
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

    # 创建日志文件
    sudo touch "/var/log/rclone-${remote_name}.log"
    sudo chown $(whoami):$(id -gn) "/var/log/rclone-${remote_name}.log"
    
    # 重新加载 systemd 并启动服务
    sudo systemctl daemon-reload
    sudo systemctl enable "rclone-${remote_name}.service"
    sudo systemctl start "rclone-${remote_name}.service"
    
    # 检查挂载状态
    echo "等待挂载完成..."
    sleep 5
    
    if sudo systemctl is-active --quiet "rclone-${remote_name}.service"; then
        echo -e "${GREEN}$display_name 挂载成功${NC}"
        echo "挂载点: $mount_point"
        echo "查看内容："
        ls -la "$mount_point" 2>/dev/null | head -5 || echo "暂时无法列出内容"
    else
        echo -e "${RED}$display_name 挂载失败${NC}"
        echo "查看错误信息："
        sudo systemctl status "rclone-${remote_name}.service" --no-pager -l
        echo ""
        echo "查看详细日志："
        sudo tail -n 20 "/var/log/rclone-${remote_name}.log"
        echo ""
        echo "可能的解决方案："
        echo "1. 手动创建软链接: sudo ln -sf /usr/bin/fusermount /usr/bin/fusermount3"
        echo "2. 手动测试挂载: rclone mount ${remote_name}: $mount_point --config=$RCLONE_CONFIG_FILE --allow-other"
        echo "3. 检查系统日志: sudo journalctl -xeu rclone-${remote_name}.service"
    fi
    
    echo ""
    echo "按 Enter 继续..."
    read
}

# 显示挂载状态
show_mount_status() {
    echo -e "${GREEN}=== 挂载状态 ===${NC}"
    echo ""
    
    for remote in gdriver onedrive backblaze; do
        mount_point="$RCLONE_DIR/$remote"
        service_name="rclone-${remote}.service"
        
        echo -n "$remote: "
        if sudo systemctl is-active --quiet "$service_name" 2>/dev/null; then
            echo -e "${GREEN}已挂载${NC}"
            if [ -d "$mount_point" ]; then
                echo "  内容数量: $(ls -1 "$mount_point" 2>/dev/null | wc -l) 项"
            fi
        else
            echo -e "${RED}未挂载${NC}"
        fi
    done
    
    echo ""
    echo "按 Enter 继续..."
    read
}

# 卸载所有存储
unmount_all_storage() {
    echo -e "${YELLOW}=== 卸载所有挂载 ===${NC}"
    echo ""
    
    for remote in gdriver onedrive backblaze; do
        service_name="rclone-${remote}.service"
        if sudo systemctl is-active --quiet "$service_name" 2>/dev/null; then
            echo "停止 $remote..."
            sudo systemctl stop "$service_name"
            sudo systemctl disable "$service_name"
        fi
    done
    
    echo -e "${GREEN}所有挂载已卸载${NC}"
    echo ""
    echo "按 Enter 继续..."
    read
}


# 第二部分的函数声明（暂时为空实现）
deploy_jellyfin_initial() { 
    echo "功能在第二部分实现"
    echo "按 Enter 继续..."
    read
}

configure_cloudflare_tunnel() { 
    echo "功能在第二部分实现"
    echo "按 Enter 继续..."
    read
}

switch_to_tunnel_mode() { 
    echo "功能在第二部分实现"
    echo "按 Enter 继续..."
    read
}

show_service_status() { 
    echo "功能在第二部分实现"
    echo "按 Enter 继续..."
    read
}

troubleshooting_menu() { 
    echo "功能在第二部分实现"
    echo "按 Enter 继续..."
    read
}

manage_services_menu() { 
    echo "功能在第二部分实现"
    echo "按 Enter 继续..."
    read
}

# 主程序
main() {
    # 检查用户
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
                echo -e "${GREEN}感谢使用！再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择${NC}"
                sleep 2
                ;;
        esac
    done
}

# 运行主程序
main "$@"
