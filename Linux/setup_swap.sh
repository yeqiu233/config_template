#!/bin/bash

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 用户运行此脚本"
  exit 1
fi

SWAPFILE="/swapfile"
SWAPSIZE="2G"

echo "🚧 创建并启用 Swap 文件（如果尚未存在）..."
# 创建 swap 文件
if [ -f "$SWAPFILE" ]; then
  echo "✅ Swap 文件已存在：$SWAPFILE"
else
  echo "📁 创建 $SWAPSIZE 的 swap 文件..."
  fallocate -l $SWAPSIZE $SWAPFILE || dd if=/dev/zero of=$SWAPFILE bs=1M count=2048
  chmod 600 $SWAPFILE
  mkswap $SWAPFILE
fi

# 启用 swap
swapon $SWAPFILE

# 添加到 /etc/fstab（如果尚未添加）
if ! grep -q "^/swapfile" /etc/fstab; then
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  echo "📌 已添加 swapfile 到 /etc/fstab"
else
  echo "📌 /etc/fstab 已包含 swapfile"
fi

# 设置 swappiness 和 vfs_cache_pressure（临时生效）
echo "⚙️ 调整 swappiness 和 cache_pressure..."
sysctl -w vm.swappiness=20
sysctl -w vm.vfs_cache_pressure=50

# 修改 /etc/sysctl.conf（永久生效）
echo "🔧 更新 /etc/sysctl.conf 设置..."
grep -q "^vm.swappiness" /etc/sysctl.conf && \
  sed -i 's/^vm.swappiness=.*/vm.swappiness=20/' /etc/sysctl.conf || \
  echo "vm.swappiness=20" >> /etc/sysctl.conf

grep -q "^vm.vfs_cache_pressure" /etc/sysctl.conf && \
  sed -i 's/^vm.vfs_cache_pressure=.*/vm.vfs_cache_pressure=50/' /etc/sysctl.conf || \
  echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf

echo "✅ 设置完成！当前 swap 状态："
swapon --show
free -h
