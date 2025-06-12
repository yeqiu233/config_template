#!/bin/bash
set -e

INSTALL_DIR="/opt/alist"
SERVICE_FILE="/etc/systemd/system/alist.service"
ARCH=$(uname -m)
DEFAULT_PORT=5244

ALIST_AMD64_URL="https://github.com/nuro-hia/nurohia-alist/releases/download/v3.39.4/alist-linux-amd64.tar.gz"
ALIST_ARM64_URL="https://github.com/nuro-hia/nurohia-alist/releases/download/v3.39.4/alist-linux-arm64.tar.gz"

function detect_arch() {
  if [[ "$ARCH" == "x86_64" ]]; then
    echo "$ALIST_AMD64_URL"
  elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    echo "$ALIST_ARM64_URL"
  else
    echo "[!] 不支持的架构: $ARCH"
    exit 1
  fi
}

function pause_return() {
  echo
  read -rp "按回车键返回菜单..."
}

function backup_data() {
  if [ -f "$INSTALL_DIR/data/data.db" ]; then
    cp "$INSTALL_DIR/data/data.db" "$INSTALL_DIR/data/data.db.bak.$(date +%Y%m%d%H%M%S)"
    echo "[*] 数据库已备份"
  fi
}

function get_server_ip() {
  IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me || hostname -I | awk '{print $1}' || echo "你的服务器IP")
  echo "$IP"
}

function get_alist_port() {
  if [ -f "$INSTALL_DIR/data/config.json" ]; then
    port=$(grep -Po '"http_port"\s*:\s*\K\d+' "$INSTALL_DIR/data/config.json" || grep -Po '"address"\s*:\s*":\K\d+' "$INSTALL_DIR/data/config.json")
    if [[ $port =~ ^[0-9]{4,5}$ ]]; then
      echo "$port"
    else
      echo "$DEFAULT_PORT"
    fi
  else
    echo "$DEFAULT_PORT"
  fi
}

function reset_admin_password() {
  echo "[*] 管理员密码将重置为 123456..."
  "$INSTALL_DIR/alist" admin set 123456 && echo "[✔] 密码已重置为 123456"
}

function install_alist() {
  echo "[+] 安装 Alist 到 $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  # 判断是否已有数据库
  if [ ! -f data/data.db ]; then
    is_fresh_install=1
  else
    is_fresh_install=0
  fi

  systemctl stop alist 2>/dev/null || true
  backup_data

  echo -e "[*] 是否使用自定义 .tar.gz 下载链接？\n留空则使用默认版本 v3.39.4"
  read -rp "请输入下载链接: " custom_url

  if [[ -n "$custom_url" ]]; then
    url="$custom_url"
  else
    url=$(detect_arch)
  fi

  echo "[*] 下载 Alist..."
  wget -O alist.tar.gz "$url"

  echo "[*] 解压中..."
  tar -xzf alist.tar.gz
  chmod +x alist
  rm -f alist.tar.gz

  echo "[*] 初始化配置目录..."
  mkdir -p data
  if [ ! -f data/config.json ]; then
    echo '{"http_port":'"$DEFAULT_PORT"'}' > data/config.json
  fi

  echo "[*] 写入 systemd 服务配置..."
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Alist Server
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/alist server
WorkingDirectory=${INSTALL_DIR}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable alist
  systemctl start alist

  # 如果是全新安装，初始化管理员密码
  if [[ $is_fresh_install -eq 1 ]]; then
    sleep 2
    reset_admin_password
    echo "[*] 管理员账号：admin 密码：123456"
  fi

  IP=$(get_server_ip)
  port=$(get_alist_port)
  echo "Web 面板访问地址： http://$IP:$port"
  echo "======================================="
  pause_return
}

function downgrade_alist() {
  echo "[!] 正在降级，仅覆盖二进制文件，不重置账号和配置。"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  systemctl stop alist 2>/dev/null || true

  echo -e "[*] 是否使用自定义 .tar.gz 下载链接？\n留空则使用默认版本 v3.39.4"
  read -rp "请输入降级下载链接: " custom_url

  if [[ -n "$custom_url" ]]; then
    url="$custom_url"
  else
    url=$(detect_arch)
  fi

  wget -O alist.tar.gz "$url"
  tar -xzf alist.tar.gz
  chmod +x alist
  rm -f alist.tar.gz
  systemctl restart alist

  echo "[✔] 降级完成。"
  IP=$(get_server_ip)
  port=$(get_alist_port)
  echo "Web 面板访问地址： http://$IP:$port"
  pause_return
}


function show_status() {
  echo "===== 当前 Alist 状态 ====="
  if systemctl is-active --quiet alist; then
    echo "[✔] Alist 正在运行"
  else
    echo "[✘] Alist 未运行"
  fi
  echo -n "[*] 当前版本: "
  if [ -x "$INSTALL_DIR/alist" ]; then
    "$INSTALL_DIR/alist" version | grep Version || echo "未知"
  else
    echo "未检测到"
  fi
  echo -n "[*] 监听端口: "
  port=$(get_alist_port)
  echo "$port"
  echo "================================"
  pause_return
}

function show_version() {
  echo "===== 当前 Alist 版本 ====="
  if [ -x "$INSTALL_DIR/alist" ]; then
    "$INSTALL_DIR/alist" version || echo "未知"
  else
    echo "未检测到 Alist 可执行文件"
  fi
  echo "================================"
  pause_return
}

function restart_alist() {
  systemctl restart alist
  echo "[*] Alist 已重启"
  pause_return
}

function stop_alist() {
  systemctl stop alist
  echo "[*] Alist 已停止"
  pause_return
}

function uninstall_alist() {
  echo "[!] 确认卸载 Alist（含数据）？[y/N]"
  read -r confirm
  if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    systemctl stop alist
    systemctl disable alist
    rm -f "$SERVICE_FILE"
    systemctl daemon-reexec
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    echo "[✔] Alist 已卸载"
  else
    echo "已取消"
  fi
  pause_return
}

function manual_reset_admin_password() {
  echo "[!] 这将重置主管理员账号密码为 123456，是否继续？[y/N]"
  read -r confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消操作。"
    pause_return
    return
  fi
  cd "$INSTALL_DIR"
  ./alist admin set 123456
  pause_return
}

function change_port() {
  if [ ! -f "$INSTALL_DIR/data/config.json" ]; then
    echo "配置文件不存在，无法更改端口。"
    pause_return
    return
  fi
  echo "[*] 当前监听端口:"
  grep '"http_port"' "$INSTALL_DIR/data/config.json" || grep '"address"' "$INSTALL_DIR/data/config.json" || echo "默认: $DEFAULT_PORT"
  read -rp "请输入新的端口号（4-5位数字）: " new_port
  if [[ ! $new_port =~ ^[0-9]{4,5}$ ]]; then
    echo "输入端口无效，必须为4-5位数字！"
    pause_return
    return
  fi
  if grep -q '"http_port"' "$INSTALL_DIR/data/config.json"; then
    sed -i "s/\"http_port\":\s*[0-9]\+/\"http_port\":$new_port/" "$INSTALL_DIR/data/config.json"
  elif grep -q '"address"' "$INSTALL_DIR/data/config.json"; then
    sed -i "s/\"address\": \":[0-9]\+\"/\"address\": \":$new_port\"/" "$INSTALL_DIR/data/config.json"
  else
    sed -i "1i\{\"http_port\":$new_port\}," "$INSTALL_DIR/data/config.json"
  fi
  echo "[*] 端口已更新，正在重启 Alist..."
  systemctl restart alist
  IP=$(get_server_ip)
  echo "[✔] 已更改监听端口为: $new_port"
  echo "Web 面板访问地址： http://$IP:$new_port"
  pause_return
}

function quick_open_panel() {
  echo "[*] 正在获取默认面板地址..."
  IP=$(get_server_ip)
  port=$(get_alist_port)
  echo "浏览器访问：http://$IP:$port"
  pause_return
}

function show_menu() {
  clear
  echo "===== Alist 一键部署&管理菜单 ====="
  echo "===== 安装、强制降级默认为 v3.39.4 版本 ====="
  echo "1) 安装 Alist"
  echo "2) 强制降级Alist 版本"
  echo "3) 查看当前运行状态"
  echo "4) 查看当前 Alist 版本"
  echo "5) 重启 Alist 服务"
  echo "6) 停止 Alist 服务"
  echo "7) 卸载 Alist"
  echo "8) 重置管理员密码"
  echo "9) 更改面板端口"
  echo "10) 快速显示访问地址"
  echo "11) 退出"
  echo "======================================="
  read -rp "请输入选项 [1-12]: " choice

  case "$choice" in
    1) install_alist ;;
    2) downgrade_alist ;;
    3) show_status ;;
    4) show_version ;;
    5) restart_alist ;;
    6) stop_alist ;;
    7) uninstall_alist ;;
    8) manual_reset_admin_password ;;
    9) change_port ;;
    10) quick_open_panel ;;
    11) exit 0 ;;
    *) echo "无效选项" && sleep 1 ;;
  esac
}

while true; do
  show_menu
done