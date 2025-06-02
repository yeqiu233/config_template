#!/bin/bash

set -e

# 1. 备份现有源
BACKUP_DIR="/etc/apt/backup_$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/apt/sources.list "$BACKUP_DIR/"
if [ -d /etc/apt/sources.list.d ]; then
    mkdir -p "$BACKUP_DIR/sources.list.d"
    mv /etc/apt/sources.list.d/* "$BACKUP_DIR/sources.list.d/" 2>/dev/null || true
fi

# 2. 获取系统版本信息
. /etc/os-release
CODENAME="$VERSION_CODENAME"
VERSION_NUMBER=$(echo "$VERSION_ID" | tr -d '"')

# 3. 设定组件和安全性源后缀
COMPONENTS="main contrib non-free"
if [ "$VERSION_NUMBER" -ge 12 ]; then
    COMPONENTS="$COMPONENTS non-free-firmware"
fi

if [ "$VERSION_NUMBER" -ge 11 ]; then
    SECURITY_SUFFIX="-security"
else
    SECURITY_SUFFIX="/updates"
fi

# 4. 生成新的 sources.list
cat > /etc/apt/sources.list <<EOF
# 官方主仓库
deb https://deb.debian.org/debian $CODENAME $COMPONENTS
deb https://deb.debian.org/debian $CODENAME-updates $COMPONENTS

# 安全更新
deb https://security.debian.org/debian-security $CODENAME$SECURITY_SUFFIX $COMPONENTS
EOF

# 5. 更新软件包列表并升级系统
apt update -y
apt upgrade -y

# 6. 安装常用工具和网络工具
apt install -y git curl wget net-tools

# 7. 永久开启IPv4和IPv6转发
SYSCTL_CONF="/etc/sysctl.conf"
cp "$SYSCTL_CONF" "$SYSCTL_CONF.bak_$(date +%Y%m%d%H%M%S)"

if grep -q "^net.ipv4.ip_forward" "$SYSCTL_CONF"; then
    sed -i "s/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/" "$SYSCTL_CONF"
else
    echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
fi

if grep -q "^net.ipv6.conf.all.forwarding" "$SYSCTL_CONF"; then
    sed -i "s/^net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/" "$SYSCTL_CONF"
else
    echo "net.ipv6.conf.all.forwarding=1" >> "$SYSCTL_CONF"
fi

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

echo "软件源已更新，系统升级完成，常用工具已安装，IPv4和IPv6转发已开启。"
