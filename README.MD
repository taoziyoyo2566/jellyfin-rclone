# Jellyfin + rclone + Cloudflare Tunnel 一键部署脚本

> **Author:** taoziyoyo  
> **脚本文件:** `jellyfin_setup_menu.sh`  
> **适用环境:** Ubuntu/Debian/CentOS x86/ARM VPS 或物理机  
> **功能:** 快速交互式部署 Jellyfin 媒体服务器，结合 rclone 云盘挂载、Cloudflare Tunnel 隧道内网穿透，适合自建私有媒体库 HTTPS 服务。

---

## ✨ 脚本简介

本项目提供一份**菜单式的 Bash 脚本**，适合新手与运维人员一键搭建 Jellyfin 媒体服务。主要特性如下：

- 一键完成目录结构、权限、安全配置初始化
- 自动检测并安装 Docker、docker-compose、rclone、cloudflared 等必要依赖
- 支持配置和安全挂载 Google Drive、OneDrive、Backblaze B2 等主流网盘
- 支持 systemd 服务管理，自动开机挂载
- 提供 Cloudflare Tunnel 接入公网 HTTPS
- 提供服务状态、挂载状态、日志等辅助管理功能
- 日志输出带颜色和分级，便于排查
- 高安全性（关键配置仅限本人访问，umask/权限控制到位）

---

## 🚀 快速开始

### 1. 下载脚本并赋予权限

```bash
wget https://your-repo/jellyfin_setup_menu.sh
chmod +x jellyfin_setup_menu.sh


脚本执行后默认会在 /opt/docker/jellyfin 生成如下结构：

/opt/docker/jellyfin/
├── docker-compose.initial.yml      # 初始 Docker Compose 配置
├── docker-compose.tunnel.yml       # 含 Tunnel 的 Docker Compose 配置
├── .env                           # 环境变量配置（仅本人可读）
├── .current_mode                  # 当前运行模式标识（仅本人可读）
├── rclone/
│   ├── config/
│   │   └── rclone.conf            # rclone 配置
│   ├── gdriver/                   # Google Drive 挂载点
│   ├── onedrive/                  # OneDrive 挂载点
│   └── backblaze/                 # Backblaze 挂载点
└── scripts/
    └── backup/                    # 备份脚本
