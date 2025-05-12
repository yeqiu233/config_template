#!/bin/bash

# 备份现有源
BACKUP_DIR="/etc/apt/backup_$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/apt/sources.list "$BACKUP_DIR/"
if [ -d /etc/apt/sources.list.d ]; then
    mkdir -p "$BACKUP_DIR/sources.list.d"
    mv /etc/apt/sources.list.d/* "$BACKUP_DIR/sources.list.d/" 2>/dev/null
fi

# 获取系统版本信息
. /etc/os-release
CODENAME="$VERSION_CODENAME"
VERSION_NUMBER=$(echo "$VERSION_ID" | tr -d '"')

# 确定组件和安全性源后缀
COMPONENTS="main contrib non-free"
if [ "$VERSION_NUMBER" -ge 12 ]; then
    COMPONENTS="$COMPONENTS non-free-firmware"
fi

if [ "$VERSION_NUMBER" -ge 11 ]; then
    SECURITY_SUFFIX="-security"
else
    SECURITY_SUFFIX="/updates"
fi

# 生成新的sources.list
cat > /etc/apt/sources.list <<EOF
# 官方主仓库
deb https://deb.debian.org/debian $CODENAME $COMPONENTS
deb https://deb.debian.org/debian $CODENAME-updates $COMPONENTS

# 安全更新
deb https://security.debian.org/debian-security $CODENAME$SECURITY_SUFFIX $COMPONENTS
EOF

# 更新软件列表
apt update -y