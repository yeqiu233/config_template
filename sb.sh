#!/usr/bin/env bash
# Debian / Ubuntu + systemd. Install as /usr/local/bin/sb.
set -u -o pipefail
umask 077
export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
DIR=/etc/sing-box
CFG=$DIR/config.json
BACKUP=$DIR/config.json.bak
WORK=$DIR
STATE=$DIR
UI=$DIR/ui
LOCK=/run/lock/sb.lock
SELF=/usr/local/bin/sb
SETTINGS=$DIR/sb.conf
UNITS=/etc/systemd/system
TMPDIR=/tmp
export TMPDIR
export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
LEGACY_WORK=/var/lib/sing-box
PROXY=https://gh-proxy.com/
OFFICIAL_URL=https://github.com/SagerNet/sing-box-dashboard/archive/refs/heads/gh-pages.zip
CLASH_URL=https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip
if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
    C=$'\e[96m'; G=$'\e[92m'; Y=$'\e[93m'; R=$'\e[91m'; B=$'\e[1m'; N=$'\e[0m'
else C= G= Y= R= B= N=; fi
ok(){ printf '%s[成功]%s %s\n' "$G" "$N" "$*"; }
info(){ printf '%s[提示]%s %s\n' "$C" "$N" "$*"; }
warn(){ printf '%s[注意]%s %s\n' "$Y" "$N" "$*"; }
err(){ printf '%s[失败]%s %s\n' "$R" "$N" "$*" >&2; return 1; }
ask(){ local a; read -r -p "$1 [y/N]: " a || return 1; [[ $a == [yY] ]]; }
version(){ timeout 2s sing-box version 2>/dev/null | awk 'NR==1 {print $3}'; }
need(){ local x bad=(); for x in "$@"; do command -v "$x" >/dev/null || bad+=("$x"); done; if ((${#bad[@]})); then err "缺少依赖：${bad[*]}。请先执行 apt update && apt install -y ca-certificates curl jq python3 util-linux iproute2 procps"; return 1; fi; }
fetch(){ curl -q -fsSL --connect-timeout 8 --max-time 90 --retry 0 --proto '=http,https' --proto-redir '=http,https' "$@"; }
url_ok(){ [[ $1 =~ ^https?://[^[:space:]]+$ ]]; }
atomic_text(){ local f=$1 t; t=$(mktemp "$(dirname "$f")/.sb-write.XXXXXX") || return 1; printf '%s\n' "$2" > "$t" && mv -fT -- "$t" "$f" || { rm -f -- "$t"; return 1; }; }
atomic_file(){ local src=$1 dst=$2 t; t=$(mktemp "$(dirname "$dst")/.sb-write.XXXXXX") || return 1; cat -- "$src" > "$t" && mv -fT -- "$t" "$dst" || { rm -f -- "$t"; return 1; }; }
require_box(){ need sing-box || return 1; }
# Root files in a sticky directory cannot be removed/renamed by sing-box.
# Never use recursive chown on the entire directory.
protected(){ [[ $1 == sb || $1 == sb-* || $1 == sb.conf || $1 == sb.lock || $1 == manager || $1 == data || $1 == ui || $1 == config.url || $1 == .sb-* || $1 == install.log || $1 == config-*.bak || $1 == config.json.bak ]]; }
permissions(){
    getent passwd sing-box >/dev/null && getent group sing-box >/dev/null || { err '不存在 sing-box 用户或组，请先安装官方软件包。'; return 1; }
    chown root:sing-box "$DIR" && chmod 1770 "$DIR" || return 1
    ensure_ui || return 1
    local f n
    for f in "$UI"/* "$UI"/.[!.]* "$UI"/..?*; do
        [[ -e $f || -L $f ]] || continue
        [[ ! -L $f ]] || { warn "跳过面板符号链接：$f"; continue; }
        chown -hR sing-box:sing-box -- "$f" || return 1
    done
    for f in "$DIR"/* "$DIR"/.[!.]* "$DIR"/..?*; do
        [[ -e $f || -L $f ]] || continue
        n=${f##*/}; protected "$n" && continue
        [[ ! -L $f ]] || { warn "跳过符号链接：$f"; continue; }
        chown -hR sing-box:sing-box -- "$f" || return 1
    done
}
settings_get(){ [[ -f $SETTINGS && ! -L $SETTINGS && $(stat -c '%u:%h' "$SETTINGS" 2>/dev/null) == 0:1 ]] || return 1; jq -r "$1" "$SETTINGS"; }
settings_write(){
    local t; t=$(mktemp) || return 1
    if ! jq "$@" "$SETTINGS" > "$t"; then rm -f -- "$t"; return 1; fi
    local rc=0; atomic_file "$t" "$SETTINGS" || rc=$?; rm -f -- "$t"; return "$rc"
}
setup_service(){
    local bin drop=/etc/systemd/system/sing-box.service.d/90-sb-manager.conf
    bin=$(command -v sing-box) || return 1
    [[ $bin == /* && $bin != *[[:space:]]* ]] || return 1
    mkdir -p /etc/systemd/system/sing-box.service.d || return 1
    cat > "$drop.tmp" <<EOF
[Service]
User=sing-box
Group=sing-box
StateDirectory=
WorkingDirectory=$WORK
ExecStart=
ExecStart=$bin -D $WORK -c $CFG run
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
EOF
    mv -fT "$drop.tmp" "$drop" && systemctl daemon-reload
}
# A persistent systemd start interlock, removed only by a validated manual import.
# It is a unit drop-in, not a new state file in /etc/sing-box.
HOLD=/etc/systemd/system/sing-box.service.d/91-sb-start-hold.conf
GUARD=sb-manager-network-guard
hold_service(){
    local t
    mkdir -p -- "${HOLD%/*}" || return 1
    t=$(mktemp "${HOLD%/*}/.hold.XXXXXX") || return 1
    if ! printf '[Unit]\nConditionPathExists=!%s\n' "$HOLD" > "$t" || ! mv -fT -- "$t" "$HOLD"; then rm -f -- "$t"; return 1; fi
    systemctl daemon-reload
}
safety_stop(){
    local rc=0
    hold_service || rc=1
    # Stop even if writing the interlock failed; never restart on failure.
    systemctl stop sing-box.service || rc=1
    systemctl disable sing-box.service >/dev/null 2>&1 || rc=1
    if systemctl is-active --quiet sing-box.service; then err '安全停机失败，请从本地控制台检查'; return 1; fi
    return "$rc"
}
network_probe(){
    local label=$1 url code; shift
    for url in "$@"; do
        code=$(curl -q -sS --noproxy '*' --connect-timeout 3 --max-time 7 --retry 0 --proto '=https' -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || continue
        case $code in 200|204) ok "$label：正常"; return 0;; esac
    done
    warn "$label：无法访问"; return 1
}
guard_pending(){
    local u state
    for u in "$GUARD.timer" "$GUARD.service"; do
        state=$(systemctl show "$u" -p ActiveState --value 2>/dev/null) || state=''
        case $state in active|activating|deactivating|reloading) return 0;; esac
    done
    return 1
}
guarded_start(){
    local allow=${1:-normal} cn=0 foreign=0
    if [[ -e $HOLD && $allow != imported ]]; then err '内核处于安全停机状态，请先使用菜单 02 导入并校验配置'; return 1; fi
    need curl systemd-run timeout || return 1
    if guard_pending; then err '上一次网络保护任务尚未结束，请稍后重试'; return 1; fi
    # Independent of the SSH session. If the manager dies before confirming
    # connectivity, this transient timer puts the core back into safe hold.
    if ! systemd-run --quiet --collect --unit="$GUARD" --on-active=120s --timer-property=AccuracySec=1s /bin/bash "$SELF" --network-guard-stop; then
        err '无法建立独立网络保护，取消启动'; return 1
    fi
    if [[ -e $HOLD ]]; then
        if ! rm -f -- "$HOLD" || ! systemctl daemon-reload; then
            safety_stop; systemctl stop "$GUARD.timer" 2>/dev/null || true; return 1
        fi
    fi
    info '正在启动内核，已启用 120 秒失联保护……'
    if timeout 45s systemctl restart sing-box.service; then
        sleep 3
        if systemctl is-active --quiet sing-box.service; then
            info '正在检查国内、国外网络……'
            network_probe '国内网络' 'https://www.baidu.com/' 'https://connect.rom.miui.com/generate_204' && cn=1
            network_probe '国外网络' 'https://www.gstatic.com/generate_204' 'https://www.cloudflare.com/cdn-cgi/trace' && foreign=1
            if ((cn || foreign)) && systemctl is-active --quiet sing-box.service; then
                # Cancel only after connectivity is confirmed. If the guard has
                # already fired, keep the service stopped instead of racing it.
                if systemctl stop "$GUARD.timer" && ! guard_pending && [[ ! -e $HOLD ]] && systemctl is-active --quiet sing-box.service; then
                    if ((cn && foreign)); then ok '国内、国外网络检测均通过'; else warn '仅一类网络检测通过，按设置保留内核运行'; fi
                    return 0
                fi
                warn '失联保护已触发或无法解除'
            else warn '两类网络均未通过，或服务已退出'; fi
        else warn '内核未进入运行状态'; fi
    else warn '内核启动失败或超时'; fi
    # Keep the independent guard armed until the immediate stop is confirmed.
    if safety_stop; then
        systemctl stop "$GUARD.timer" 2>/dev/null || true
        err '已停止内核并关闭开机自启，请修正配置后通过菜单 02 重新导入'
    else
        err '安全停机未确认，独立保护任务仍保留，请检查本地控制台'
    fi
    return 1
}
restart_box_inner(){
    local allow=${1:-normal}
    [[ -s $CFG ]] || { err '尚未导入配置，请先使用菜单 02'; return 1; }
    if [[ -e $HOLD && $allow != imported ]]; then err '内核处于安全停机状态，请先使用菜单 02 导入配置'; return 1; fi
    if guard_pending; then err '上一次网络保护任务尚未结束，请稍后重试'; return 1; fi
    if [[ $allow != imported ]]; then check_layout && check_cfg "$CFG" || return 1; fi
    # 根据 systemd 当前工作目录判断是否需要迁移，不另建标记文件。
    local old f name previous
    previous=$(systemctl show sing-box --property=WorkingDirectory --value) || return 1
    if [[ $previous == "$DIR/data" || $previous == "$LEGACY_WORK" ]]; then
        systemctl stop sing-box || return 1
        for old in "$previous"; do
            [[ -d $old && ! -L $old ]] || continue
            for f in "$old"/* "$old"/.[!.]* "$old"/..?*; do
                [[ -e $f && ! -L $f ]] || continue
                name=${f##*/}; protected "$name" && continue
                [[ $name != *.json && ! -e $DIR/$name && ! -L $DIR/$name ]] || continue
                cp -an -- "$f" "$DIR/" || return 1
            done
        done
    fi
    migrate_ui || return 1
    permissions && setup_service && guarded_start "$allow"
}
# 仅转换官方已有的面板路径字段；所有面板使用 ui/名称，保留原下载地址等选项。
normalize_ui(){
    jq --arg dir "$DIR" --arg legacy "$LEGACY_WORK" '
      def panelpath($default):
        . as $p | (if . == $dir+"/ui" or . == $dir+"/ui/" or . == "ui" or . == "ui/" or . == "./ui" or . == "./ui/" then $default
          elif startswith($dir+"/ui/") then ltrimstr($dir+"/ui/")
          elif startswith($dir+"/data/") then ltrimstr($dir+"/data/")
          elif startswith($dir+"/") then ltrimstr($dir+"/")
          elif startswith($legacy+"/") then ltrimstr($legacy+"/")
          elif startswith("./") then ltrimstr("./") else . end)
        | ltrimstr("ui/") | ltrimstr("data/")
        | if test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (startswith("sb-")|not) and . != "sb" and . != "sb.conf" and . != "sb.lock" and . != "install.log" and (test("^config-.*\\.bak$")|not) and . != "cache.db" and . != "config.json" and . != "config.json.bak" and . != "config.url" and . != "manager" and . != "data" and . != "ui" then $dir+"/ui/"+. else error("不支持的面板目录："+$p) end;
      if (.experimental.clash_api.external_ui // "") != "" then .experimental.clash_api.external_ui |= panelpath("zashboard") else . end
      | if (.services|type)=="array" then .services |= map(if .type=="api" then
          if .dashboard==true then .dashboard={enabled:true,path:("dashboard"|panelpath("dashboard"))}
          elif (.dashboard|type)=="string" then .dashboard={enabled:true,path:(.dashboard|if .=="" then "dashboard" else . end|panelpath("dashboard"))}
          elif (.dashboard|type)=="object" and .dashboard.enabled==true then .dashboard.path |= ((. // "")|if .=="" then "dashboard" else . end|panelpath("dashboard"))
          else . end else . end) else . end
      | ([.experimental.clash_api.external_ui // empty | select(.!="")] + [.services[]? | select(.type=="api") | .dashboard | select(type=="object" and .enabled==true) | .path]) as $paths
      | if ($paths|length)!=($paths|unique|length) then error("多个面板使用相同目录，请为每个面板指定不同名称") else . end' "$1"
}
ensure_ui(){
    [[ ! -L $UI && ( ! -e $UI || -d $UI ) ]] || { err 'ui 目录不安全'; return 1; }
    mkdir -p -- "$UI" && chown root:sing-box "$UI" && chmod 1770 "$UI"
}
migrate_ui(){
    ensure_ui || return 1
    [[ -s $CFG ]] || return 0
    local row k n p src idx target old base stopped=0 rows
    rows=$(panels) || return 1
    while IFS= read -r row; do
        [[ -n $row ]] || continue
        IFS=$'\t' read -r k n p src idx <<< "$row"
        target=$(resolve_panel "$p") || return 1
        [[ ! -e $target ]] || continue
        base=${target##*/}
        for old in "$DIR/$base" "$DIR/data/$base" "$DIR/data/ui/$base" "$LEGACY_WORK/$base" "$LEGACY_WORK/ui/$base"; do
            [[ -d $old && ! -L $old && $(realpath -m -- "$old") == "$old" ]] || continue
            if (( ! stopped )); then systemctl stop sing-box || return 1; stopped=1; fi
            # 保留原目录，不覆盖已经存在的新面板。
            cp -a -- "$old" "$target" || return 1
            info "面板已复制到 $target（原目录保留）"
            break
        done
    done <<< "$rows"
}
restart_box(){
    local t backup
    [[ -s $CFG && ! -e $HOLD ]] || { err '尚未导入有效配置，或处于安全停机状态，请先使用菜单 02'; return 1; }
    need jq sing-box || return 1
    check_layout || return 1
    t=$(mktemp) || return 1
    if ! normalize_ui "$CFG" > "$t"; then rm -f -- "$t"; return 1; fi
    if jq -e --slurpfile new "$t" '. == $new[0]' "$CFG" >/dev/null; then
        rm -f -- "$t"; restart_box_inner; return $?
    fi
    if ! check_cfg "$t"; then rm -f -- "$t"; err '面板路径调整校验失败，原配置未修改'; return 1; fi
    backup=$BACKUP
    if ! atomic_file "$CFG" "$backup" || ! atomic_file "$t" "$CFG"; then rm -f -- "$t"; return 1; fi
    rm -f -- "$t"
    if restart_box_inner; then ok '面板路径已统一到 ui/'; return 0; fi
    warn '迁移后启动失败，恢复旧配置……'
    # 恢复原配置及原面板路径，不重新触发迁移。
    if safety_stop && atomic_file "$backup" "$CFG" && permissions; then warn '已恢复旧配置，内核保持停止'; fi
    return 1
}
check_cfg(){ (cd "$WORK" && timeout 60s sing-box check -c "$1" -D "$WORK"); }
check_layout(){ [[ ! -L $CFG ]] || { err 'config.json 不得是符号链接'; return 1; }; local f; for f in "$DIR"/*.json; do [[ -e $f ]] || continue; [[ $f == "$CFG" ]] || { err '检测到额外 JSON 配置文件；本脚本只管理单一 config.json，已取消操作。'; return 1; }; done; }
set_sub(){ local u; read -r -p 'Sub-Store 配置链接（回车取消）: ' u || return 1; [[ -n $u ]] || return 1; url_ok "$u" || { err '请输入 HTTP/HTTPS 链接'; return 1; }; settings_write --arg u "$u" '.sub_url=$u' && ok '链接已保存到 sb.conf'; }
release_query(){
    local base=$1 data result
    info "正在读取官方更新日志（最多12秒）" >&2
    data=$(curl -q -4 -fsSL --connect-timeout 5 --max-time 12 --retry 0 --max-redirs 3 --max-filesize 2097152 --proto '=https' --proto-redir '=https' "${base}https://raw.githubusercontent.com/SagerNet/sing-box/testing/docs/changelog.md") || return 1
    result=$(printf '%s\n' "$data" | awk '
        $1=="####" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && !stable {stable=$2}
        $1=="####" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta|rc)(\.[0-9]+)?$/ && !beta {beta=$2}
        END {if (!stable && !beta) exit 1; printf "%s|%s\n", stable, beta}
    ') || { err '未识别到官方版本号，可能返回了代理错误页面'; return 1; }
    printf '%s\n' "$result"
}
install_box(){
    need curl jq dpkg dpkg-query || return 1
    local cur stable='' beta='' releases choice target='' base="$PROXY" source='官方更新日志'
    info '状态检查中……'
    cur=$(version) || cur=''
    if releases=$(release_query "$base"); then
        IFS='|' read -r stable beta <<< "$releases"
    else
        warn '查询失败，未修改配置或服务。'
        printf '1. 使用备用代理查询\n2. 手动输入版本\n0. 返回\n'
        read -r -p '请选择: ' choice || return 0
        case $choice in
            1) base=https://gh-proxy.org/; if releases=$(release_query "$base"); then IFS='|' read -r stable beta <<< "$releases"; else warn '备用代理查询失败，仍可手动指定版本'; fi;;
            2) :;;
            *) return 0;;
        esac
    fi
    printf '\n当前安装版本：%s\n稳定版（%s）：%s\n测试版（%s）：%s\n\n' "${cur:-未安装}" "$source" "${stable:-未获取}" "$source" "${beta:-未获取}"
    printf '1. 安装稳定版\n2. 安装测试版\n3. 手动指定版本\n0. 返回\n'
    read -r -p '请选择: ' choice || return 0
    case $choice in
        1) target=$stable;; 2) target=$beta;;
        3) read -r -p '请输入版本号（例如 1.14.4，回车取消）: ' target || return 0; target=${target#v}; [[ -n $target ]] || return 0;;
        0|'') return 0;; *) err '无效选项'; return 1;;
    esac
    [[ $target =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)(\.[0-9]+)?)?$ ]] || { err '版本无效或未获取，请使用手动指定版本'; return 1; }
    [[ $cur != "$target" ]] || { ok '已经是所选版本'; return 0; }
    warn '仅安装内核：下载成功后停止现有服务，安装后保持停止并关闭自启。若通过此内核的 Tailscale 连接，请先切换到本地控制台。'
    ask "确认通过 $base 安装 sing-box $target？" || return 0
    locked install_selected "$target" "$base"
}
install_selected(){
    local target=$1 base=$2 log tmp status=0 arch package url had=0 save='' state
    need dpkg dpkg-deb dpkg-query curl systemctl || return 1
    check_layout || return 1
    if guard_pending; then err '上一次网络保护任务尚未结束，请稍后重试'; return 1; fi
    if [[ -e $CFG ]]; then
        [[ -f $CFG && ! -L $CFG ]] || { err 'config.json 不是普通文件'; return 1; }
        had=1
    fi
    arch=$(dpkg --print-architecture) || return 1
    [[ $arch =~ ^[a-z0-9]+$ ]] || return 1
    tmp=$(mktemp -d) || return 1; log=$STATE/install.log
    package="$tmp/sing-box.deb"
    url="${base}https://github.com/SagerNet/sing-box/releases/download/v${target}/sing-box_${target}_linux_${arch}.deb"
    atomic_text "$log" '' || { rm -rf -- "$tmp"; return 1; }
    info '正在下载官方内核安装包（此时不停止现有服务）……'
    if ! curl -q -4 -fSL --connect-timeout 8 --max-time 180 --retry 0 --proto '=https' --proto-redir '=https' "$url" -o "$package" > "$log" 2>&1 ||
       [[ $(dpkg-deb -f "$package" Package 2>>"$log") != sing-box || $(dpkg-deb -f "$package" Architecture 2>>"$log") != "$arch" ]]; then
        tail -n 10 "$log"; rm -rf -- "$tmp"; err '下载失败或软件包不匹配，未停止服务'; return 1
    fi
    if ((had)); then
        save="$tmp/config.previous"
        if ! cp -- "$CFG" "$save"; then rm -rf -- "$tmp"; err '无法暂存原配置，取消安装'; return 1; fi
    fi
    # Set the persistent interlock BEFORE dpkg, not after package hooks run.
    if ! hold_service; then rm -rf -- "$tmp"; err '无法禁止自动启动，取消安装'; return 1; fi
    state=$(systemctl show sing-box.service -p LoadState --value 2>/dev/null) || state=''
    if [[ $state != not-found ]]; then
        if ! systemctl stop sing-box.service; then rm -rf -- "$tmp"; err '无法确认内核已停止，取消安装'; return 1; fi
    fi
    systemctl disable sing-box.service >/dev/null 2>&1 || true
    info '正在安装内核，禁止软件包自动启动服务……'
    DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold -i "$package" >> "$log" 2>&1 || status=$?
    # Debian packages may ship a sample config. Never import it on behalf of the user.
    local keep_tmp=0
    if ((had)); then
        if ! cmp -s -- "$save" "$CFG" && ! atomic_file "$save" "$CFG"; then
            status=1; keep_tmp=1; warn "原配置恢复失败，临时副本保留于：$save"
        fi
    elif [[ -e $CFG || -L $CFG ]]; then
        rm -f -- "$CFG" || status=1
    fi
    ((keep_tmp)) || rm -rf -- "$tmp"
    systemctl daemon-reload || status=1
    safety_stop || status=1
    if ((status != 0)) || [[ $(version) != "$target" ]] || ! dpkg-query -W -f='${Status}\n' sing-box 2>/dev/null | grep -qx 'install ok installed'; then
        tail -n 15 "$log"; err "安装未确认成功，内核保持安全停机。请检查依赖及日志：$log"; return 1
    fi
    ok "内核安装完成：$(version)"
    info '未启动内核，未开启自启。请使用菜单 02 下载并导入有效配置。'
}
update_config(){
    local mode=${1:-manual} u tmp normalized backup='' had=0 washeld=0
    need curl jq sing-box systemd-run || return 1; check_layout || return 1
    if [[ -e $HOLD && $mode != manual ]]; then warn '内核处于安全停机状态，仅允许通过菜单 02 手动导入'; return 1; fi
    if guard_pending; then err '上一次网络保护任务尚未结束，请稍后重试'; return 1; fi
    u=$(settings_get '.sub_url // empty') || return 1
    if [[ -z $u ]]; then [[ $mode == manual ]] && set_sub || { err '尚未设置 Sub-Store 链接'; return 1; }; u=$(settings_get '.sub_url // empty') || return 1; fi
    url_ok "$u" || { err '配置链接无效'; return 1; }
    tmp=$(mktemp) || return 1
    info '正在下载并验证配置……'
    normalized=$(mktemp) || { rm -f -- "$tmp"; return 1; }
    if ! fetch "$u" -o "$tmp" || ! jq -e 'type=="object"' "$tmp" >/dev/null || ! normalize_ui "$tmp" > "$normalized" || ! check_cfg "$normalized"; then rm -f -- "$tmp" "$normalized"; err '下载或校验失败，旧配置及服务未修改。'; return 1; fi
    rm -f -- "$tmp"; tmp=$normalized
    if [[ -f $CFG ]] && jq -e --slurpfile new "$tmp" '. == $new[0]' "$CFG" >/dev/null 2>&1; then
        rm -f -- "$tmp"
        if [[ ! -e $HOLD ]] && timeout 2s systemctl is-active --quiet sing-box 2>/dev/null; then
            ok '配置未变化，无需备份或重启'; return 0
        fi
        info '配置未变化，保留已有备份，尝试安全启动内核……'
        if restart_box_inner imported; then ok '服务运行中'; return 0; fi
        safety_stop || warn '安全停机未确认，请检查本地控制台'
        return 1
    fi
    if [[ -e $CFG ]]; then
        [[ -f $CFG && ! -L $CFG ]] || { rm -f -- "$tmp"; err 'config.json 不是普通文件'; return 1; }
        had=1; backup=$BACKUP
        if ! atomic_file "$CFG" "$backup"; then rm -f -- "$tmp"; err '备份失败，旧配置未修改'; return 1; fi
    fi
    # Protect against a disconnect or reboot between replacing the config and arming the watchdog.
    [[ ! -e $HOLD ]] || washeld=1
    if ! hold_service; then rm -f -- "$tmp"; err '无法建立启动保护，旧配置未修改'; return 1; fi
    if ! atomic_file "$tmp" "$CFG"; then
        rm -f -- "$tmp"
        if (( ! washeld )); then rm -f -- "$HOLD" && systemctl daemon-reload || warn '启动保护未解除，请通过菜单 02 重试'; fi
        return 1
    fi
    rm -f -- "$tmp"
    ok '配置校验通过，已导入配置'
    if restart_box_inner imported; then ok '配置更新完成，服务运行中'; return 0; fi
    warn '启动或网络检测失败，正在停止内核并恢复旧配置（不自动重启）……'
    if ! safety_stop; then err '安全停机未确认，暂不修改磁盘配置，请从本地控制台检查'; return 1; fi
    if ((had)); then
        if ! atomic_file "$backup" "$CFG" || ! permissions; then err "旧配置恢复失败，备份：$backup"; return 1; fi
        warn '旧配置已恢复，内核保持停止'
    else
        rm -f -- "$CFG" || return 1
        warn '首次导入未通过运行检测，已撤销新配置，内核保持停止'
    fi
    return 1
}
# systemd 定时器：本地时间，每日一次，关机错过的任务在开机后补跑。
timer_set(){
    local id=$1 action=$2 t=$3 unit=sb-manager-$1
    [[ $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { err '请输入 HH:MM，例如 04:30'; return 1; }
    [[ -x $SELF && $(stat -c '%u' "$SELF") == 0 ]] || { err "请先将脚本安装到 $SELF（root 所有）"; return 1; }
    cat > "$UNITS/$unit.service.tmp" <<EOF
[Unit]
Description=sing-box manager $id update
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$SELF $action
EOF
    cat > "$UNITS/$unit.timer.tmp" <<EOF
[Unit]
Description=sing-box manager $id timer
[Timer]
OnCalendar=*-*-* $t:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
    mv -fT "$UNITS/$unit.service.tmp" "$UNITS/$unit.service" && mv -fT "$UNITS/$unit.timer.tmp" "$UNITS/$unit.timer" &&
    systemctl daemon-reload && systemctl enable --now "$unit.timer" && systemctl restart "$unit.timer" && { if [[ $id == config ]]; then ok "定时任务已启用"; else ok "每日 $t 自动执行（系统本地时间）"; fi; }
}
timer_off(){ local u=sb-manager-$1; systemctl disable --now "$u.timer" 2>/dev/null || true; rm -f -- "/etc/systemd/system/$u.timer" "/etc/systemd/system/$u.service"; systemctl daemon-reload && ok '定时任务已移除'; }
# Config update schedule: daily calendar trigger, with a persistent day gate.
config_interval(){
    local n
    n=$(settings_get '.config_schedule.days // 1' 2>/dev/null) || n=1
    [[ $n =~ ^([1-9]|[1-8][0-9]|90)$ ]] || n=1
    printf '%s' "$n"
}
config_timer_time(){
    local t
    t=$(sed -nE 's/^OnCalendar=\*-\*-\* ([0-9]{2}:[0-9]{2}):00$/\1/p' "$UNITS/sb-manager-config.timer" 2>/dev/null | head -n1)
    printf '%s' "$t"
}
config_update_status(){
    local n t
    if ! timeout 2s systemctl is-enabled --quiet sb-manager-config.timer 2>/dev/null; then printf '未开启'; return; fi
    n=$(config_interval); t=$(config_timer_time)
    if [[ $n == 1 ]]; then printf '每日'; else printf '每%s天' "$n"; fi
    [[ -z $t ]] || printf ' %s' "$t"
    if ! timeout 2s systemctl is-active --quiet sb-manager-config.timer 2>/dev/null; then printf '（未运行）'; fi
}
config_schedule_set(){
    local n=$1 t=$2 today now next old
    [[ $n =~ ^([1-9]|[1-8][0-9]|90)$ ]] || { err '请输入 1-90 的整数'; return 1; }
    [[ $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { err '时间格式应为 HH:MM'; return 1; }
    [[ -n $(settings_get '.sub_url // empty') ]] || set_sub || return 1
    today=$(date +%F); now=$(date +%H:%M)
    if [[ $n == 1 && $now < $t ]]; then next=$today; else next=$(date -d "$today +$n days" +%F) || return 1; fi
    old=$(settings_get '.config_schedule // null') || return 1
    settings_write --argjson n "$n" --arg t "$t" --arg next "$next" '.config_schedule={days:$n,time:$t,next_due:$next}' || return 1
    if ! timer_set config --update-config "$t"; then
        settings_write --argjson old "$old" 'if $old==null then del(.config_schedule) else .config_schedule=$old end' || true
        err '定时任务设置失败，请检查自动更新状态后重试'; return 1
    fi
    printf '更新周期：%s\n下次更新：%s %s（系统本地时间）\n' "$(config_update_status)" "$next" "$t"
}
config_update_due(){
    local n next t today now
    # Existing daily timers continue to work before a new schedule is set.
    next=$(settings_get '.config_schedule.next_due // empty') || return 1
    [[ -n $next ]] || { update_config auto; return $?; }
    n=$(config_interval); t=$(settings_get '.config_schedule.time // empty') || return 1
    [[ $next =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { err '自动更新设置无效，请重新设置'; return 1; }
    today=$(date +%F); now=$(date +%H:%M)
    if [[ $today < $next || ( $today == "$next" && $now < $t ) ]]; then return 0; fi
    # A failed download/check/restart does not advance the date: retry next daily trigger.
    update_config auto || return $?
    next=$(date -d "$(date +%F) +$n days" +%F) || return 1
    settings_write --arg next "$next" '.config_schedule.next_due=$next'
}
config_schedule_show(){
    local next t trigger
    printf '自动更新：%s\n' "$(config_update_status)"
    if systemctl is-enabled --quiet sb-manager-config.timer 2>/dev/null; then
        next=$(settings_get '.config_schedule.next_due // empty') || return 1
        t=$(config_timer_time)
        if [[ -n $next ]]; then printf '下次应更新：%s %s（系统本地时间）\n' "$next" "$t"
        else
            trigger=$(systemctl show sb-manager-config.timer -p NextElapseUSecRealtime --value 2>/dev/null) || trigger=''
            printf '下次执行：%s\n' "${trigger:-未知}"
        fi
    fi
}
auto_config(){
    local a n t
    printf '1. 设置每日更新\n2. 指定更新时间\n3. 自动更新状态\n4. 关闭自动更新\n0. 返回\n'
    read -r -p '请选择: ' a || return 0
    case $a in
        1) n=1;;
        2) read -r -p '每隔多少天更新（1-90）: ' n || return 0
           [[ $n =~ ^([1-9]|[1-8][0-9]|90)$ ]] || { err '请输入 1-90 的整数'; return 1; };;
        3) config_schedule_show; return $?;;
        4) timer_off config && settings_write 'del(.config_schedule)'; return $?;;
        *) return 0;;
    esac
    read -r -p '更新时间（HH:MM，回车默认 04:00）: ' t || return 0
    config_schedule_set "$n" "${t:-04:00}"
}
forwarding(){ local a b; a=$(sysctl -n net.ipv4.ip_forward) || return 1; b=$(sysctl -n net.ipv6.conf.all.forwarding) || return 1; if [[ $a != 1 ]]; then sysctl -w net.ipv4.ip_forward=1 || return 1; fi; if [[ $b != 1 ]]; then sysctl -w net.ipv6.conf.all.forwarding=1 || return 1; fi; printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/99-sing-box-forward.conf.tmp || return 1; mv -fT /etc/sysctl.d/99-sing-box-forward.conf.tmp /etc/sysctl.d/99-sing-box-forward.conf || return 1; sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding; ok 'IPv4 / IPv6 转发已开启并持久化'; }
# 面板只从当前配置发现，不编造额外配置字段。相对路径遵循官方服务工作目录。
panels(){ jq -r --arg official "$OFFICIAL_URL" --arg clash "$CLASH_URL" '
  ( .experimental.clash_api // {} | select((.external_ui // "") != "") | ["clash", "zashboard", .external_ui, (if (.external_ui_download_url // "")=="" then $clash else .external_ui_download_url end), "-"] ),
  ( (.services // []) | to_entries[] | select(.value.type=="api") | . as $s | .value.dashboard | select(.==true or type=="string" or (type=="object" and .enabled==true)) | (if type=="object" then . elif type=="string" then {path:.} else {} end) | ["official", "dashboard", (if (.path // "")=="" then "dashboard" else .path end), (if (.download_url // "")=="" then $official else .download_url end), ($s.key|tostring)] ) | @tsv' "$CFG"; }
resolve_panel(){
    local p=$1 base=$WORK clean
    [[ $p != *'$'* && $p != *'~'* ]] || { err '不支持带环境变量的面板目录，请改成绝对路径'; return 1; }
    [[ $p == /* ]] || p=$base/$p
    clean=$(realpath -ms -- "$p") || return 1
    [[ $(realpath -m -- "$p") == "$clean" ]] || { err '拒绝操作含符号链接的面板路径'; return 1; }
    [[ $clean == "$DIR/"* ]] || { err '面板必须位于 /etc/sing-box 下，请修改配置中的面板路径'; return 1; }
    [[ ${clean%/*} == "$UI" ]] && ! protected "${clean##*/}" && [[ ${clean##*/} != .* && ${clean##*/} != *.json && ${clean##*/} != cache.db ]] || { err '面板须为 /etc/sing-box/ui 下独立的一级子目录；旧配置请先执行菜单 06'; return 1; }
    [[ $clean != "$CFG" && $clean != "$DIR/config.url" ]] || return 1
    [[ ! -e $clean || -d $clean ]] || { err '面板路径不是目录'; return 1; }
    printf '%s\n' "$clean"
}
panel_load(){
    IFS=$'\t' read -r kind name rawpath source idx <<< "$1"
    path=$(resolve_panel "$rawpath") || return 1
    name=${path##*/}
    # 保留旧版按 /etc/sing-box/面板名 生成的标识，兼容已设定的 timer 和更新标记。
    key=$(printf '%s' "$kind:$DIR/${path##*/}" | sha256sum | cut -c1-16)
    local override
    override=$(jq -r --arg k "${path##*/}" '.panel_urls[$k] // empty' "$SETTINGS") || return 1
    [[ -z $override ]] || source=$override
    url_ok "$source" || { err '面板下载链接无效'; return 1; }
}
choose_panel(){ local -a rows; local i a; [[ -s $CFG ]] || { err '没有配置文件'; return 1; }; need jq python3 || return 1; mapfile -t rows < <(panels); ((${#rows[@]})) || { warn '当前配置没有启用面板'; return 1; }; for i in "${!rows[@]}"; do IFS=$'\t' read -r k n p s ix <<< "${rows[i]}"; printf '%2d. %s\n' "$((i+1))" "${p##*/}"; done; read -r -p '请选择面板（回车返回）: ' a; [[ $a =~ ^[1-9][0-9]{0,3}$ ]] && ((a<=${#rows[@]})) || return 1; panel_load "${rows[a-1]}"; }
# 解包前拒绝路径穿越、链接、特殊文件。只接受有 index.html 的完整面板或单个静态文件。
prepare_panel(){ python3 - "$@" <<'PY'
import sys, pathlib, zipfile, tarfile, shutil, stat, urllib.parse, re
src, out, url, old = sys.argv[1:]
src, out, old = map(pathlib.Path, (src, out, old))
raw = out / 'raw'; raw.mkdir(); ready = out / 'ready'
def dest(n):
    p = pathlib.PurePosixPath(n)
    if p.is_absolute() or '..' in p.parts or '\\' in n: raise ValueError('unsafe archive path')
    return raw.joinpath(*p.parts)
try:
    if zipfile.is_zipfile(src):
        with zipfile.ZipFile(src) as z:
            for m in z.infolist():
                p = dest(m.filename); mode = (m.external_attr >> 16) & 0o170000
                if mode not in (0, stat.S_IFREG, stat.S_IFDIR): raise ValueError('unsafe zip member')
                if m.is_dir(): p.mkdir(parents=True, exist_ok=True); continue
                p.parent.mkdir(parents=True, exist_ok=True)
                with z.open(m) as a, p.open('wb') as b: shutil.copyfileobj(a,b)
    elif tarfile.is_tarfile(src):
        with tarfile.open(src) as t:
            for m in t:
                p = dest(m.name)
                if m.isdir(): p.mkdir(parents=True, exist_ok=True); continue
                if not m.isfile(): raise ValueError('unsafe tar member')
                p.parent.mkdir(parents=True, exist_ok=True)
                with t.extractfile(m) as a, p.open('wb') as b: shutil.copyfileobj(a,b)
    else:
        name = pathlib.PurePosixPath(urllib.parse.unquote(urllib.parse.urlsplit(url).path)).name
        if not re.fullmatch(r'[A-Za-z0-9_.-]+\.(html?|js|css|json|svg|png|ico|webp|woff2?)', name, re.I): raise ValueError('unknown file format')
        if old.is_dir():
            if any(p.is_symlink() for p in old.rglob('*')): raise ValueError('existing panel contains symlinks')
            shutil.copytree(old, raw, dirs_exist_ok=True)
        shutil.copyfile(src, raw / name)
    root = raw
    while not (root / 'index.html').is_file():
        children = list(root.iterdir())
        if len(children) != 1 or not children[0].is_dir(): raise ValueError('index.html not found')
        root = children[0]
    shutil.move(str(root), str(ready))
    (ready / '.etag').unlink(missing_ok=True)
except Exception as e:
    print('面板文件处理失败:', e, file=sys.stderr); sys.exit(1)
PY
}
panel_update(){
    local mode=$1 tmp stage saved active=0
    need curl python3 diff || return 1
    ensure_ui || return 1
    tmp=$(mktemp -d) || return 1
    info '正在下载面板并检查内容是否有变化……'
    if ! fetch "$source" -o "$tmp/download" || ! prepare_panel "$tmp/download" "$tmp" "$source" "$path"; then rm -rf -- "$tmp"; err '面板下载或解包失败，旧文件未修改'; return 1; fi
    if [[ -d $path ]] && diff -qr -x .etag "$path" "$tmp/ready" >/dev/null 2>&1; then rm -rf -- "$tmp"; ok '面板已是当前下载源的最新内容'; return 0; fi
    if [[ $mode == manual ]]; then info '检测到面板内容变化'; ask '确认更新面板？' || { rm -rf -- "$tmp"; return 0; }; fi
    stage=$(mktemp -d "$(dirname "$path")/.sb-ui.XXXXXX") || { rm -rf -- "$tmp"; return 1; }
    if ! cp -a "$tmp/ready/." "$stage/" || ! chmod -R u=rwX,go=rX "$stage"; then rm -rf -- "$tmp" "$stage"; return 1; fi
    rm -rf -- "$tmp"
    # 官方原生下载器可能同时写目录，先停止正在运行的服务。
    if [[ $kind == official ]] && systemctl is-active --quiet sing-box; then systemctl stop sing-box || { rm -rf -- "$stage"; return 1; }; active=1; fi
    if [[ $kind == official && $(official_state) != off ]]; then
        : > "$stage/.etag" && touch -d '2000-01-01' "$stage/.etag" || { rm -rf -- "$stage"; if ((active)); then restart_box; fi; return 1; }
    fi
    saved=$(mktemp -d "$(dirname "$path")/.sb-old-ui.XXXXXX") || { rm -rf -- "$stage"; ((active)) && restart_box; return 1; }
    if [[ -e $path ]] && ! mv -T -- "$path" "$saved/old"; then rm -rf -- "$saved" "$stage"; ((active)) && restart_box; return 1; fi
    if ! mv -T -- "$stage" "$path"; then [[ ! -e $saved/old ]] || mv -T -- "$saved/old" "$path"; rm -rf -- "$stage" "$saved"; ((active)) && restart_box; err '面板替换失败'; return 1; fi
    if ! chown -hR sing-box:sing-box "$path" || { ((active)) && ! restart_box; }; then rm -rf -- "$path"; [[ ! -e $saved/old ]] || mv -T -- "$saved/old" "$path"; if ((active)); then restart_box || warn '服务恢复失败，请查看日志'; fi; rm -rf -- "$saved"; err '面板权限修复或服务启动失败，已回退面板'; return 1; fi
    rm -rf -- "$saved"; ok "面板更新完成：$path"
}
# 官方源码：目录非空且没有 .etag 时，视为用户自备静态文件，不启动自动更新循环。
# 不删除 dashboard 配置对象，否则 /dashboard/ 也会被关闭。
official_state(){
    if [[ -f $path/.etag && ! -L $path/.etag ]]; then printf 'on';
    elif [[ ! -d $path || -z $(ls -A -- "$path" 2>/dev/null) ]]; then printf 'pending';
    else printf 'off'; fi
}
official_auto(){
    local action=$1 marker=$path/.etag active=0 oldmarker=0 tmp rc=0
    [[ -f $path/index.html ]] || { err '请先手动下载面板，再切换自动更新'; return 1; }
    [[ ! -L $marker && ( ! -e $marker || -f $marker ) ]] || { err '原生标记不是普通文件，拒绝操作'; return 1; }
    if [[ $action == off && $(official_state) == off ]]; then ok '官方面板自动更新已关闭'; return 0; fi
    if [[ $action == on && $(official_state) == on ]]; then ok '官方面板自动更新已开启'; return 0; fi
    if systemctl is-active --quiet sing-box; then systemctl stop sing-box || return 1; active=1; fi
    tmp=$(mktemp) || { if ((active)); then restart_box; fi; return 1; }
    if [[ -f $marker && ! -L $marker ]]; then
        if ! cp -- "$marker" "$tmp"; then rm -f -- "$tmp"; if ((active)); then restart_box; fi; return 1; fi
        oldmarker=1
    fi
    if [[ $action == off ]]; then
        # 只备份原生标记和当前模块到统一参数文件；备份不用于判断开关状态。
        # dashboard 配置本身不移除，静态面板仍可访问。
        local d
        if ! d=$(jq -c --argjson i "$idx" '.services[$i].dashboard' "$CFG") ||
           ! settings_write --arg k "${path##*/}" --argjson d "$d" --rawfile etag "$tmp" '.panel_backups[$k]={dashboard:$d,etag:$etag}' ||
           ! rm -f -- "$marker"; then rc=1; fi
    else
        # 用空 ETag 恢复原生托管，强制重新检查下载源，避免使用过期的 ETag。
        if ! atomic_text "$marker" '' || ! chown sing-box:sing-box "$marker" || ! touch -d '2000-01-01' "$marker"; then rc=1; fi
    fi
    if ((rc == 0 && active)) && ! restart_box; then rc=1; fi
    if ((rc)); then
        if ((oldmarker)); then atomic_file "$tmp" "$marker" && chown sing-box:sing-box "$marker" || warn '原生标记恢复失败'; else rm -f -- "$marker"; fi
        if ((active)); then restart_box || warn '服务恢复失败，请查看日志'; fi
        rm -f -- "$tmp"; err '切换失败，已尝试恢复旧状态'; return 1
    fi
    rm -f -- "$tmp"
    if [[ $action == off ]]; then ok '官方自动更新已关闭，静态面板仍可访问；原标记及模块已备份到 sb.conf'; else ok '官方原生自动更新已恢复（按配置的 update_interval）'; fi
}
official_update_file(){
    local marker="$path/.etag" panel="${path##*/}"
    if [[ -f $marker && ! -L $marker ]]; then
        printf '更新文件：%s\n' "$marker"
    elif jq -e --arg k "$panel" '.panel_backups[$k] | type == "object" and has("etag")' "$SETTINGS" >/dev/null 2>&1; then
        printf '备份位置：%s\n备份字段：panel_backups.%s.etag\n' "$SETTINGS" "$panel"
    elif [[ -f $DIR/sb-panel-$key.etag ]]; then
        printf '备份文件：%s\n' "$DIR/sb-panel-$key.etag"
    else warn '未找到更新文件或备份'; fi
}
panel_menu(){
    local a t kind name rawpath source idx path key
    choose_panel || return 1
    printf '\n%s%s%s\n' "$B" "$name" "$N"
    if [[ $kind == official ]]; then case $(official_state) in on) info '原生自动更新：开启';; off) info '原生自动更新：关闭（静态文件）';; pending) info '原生自动更新：面板未下载，启动时由原生模块处理';; esac; else if systemctl is-active --quiet "sb-manager-panel-$key.timer" 2>/dev/null; then info '定时自动更新：开启'; elif systemctl is-enabled --quiet "sb-manager-panel-$key.timer" 2>/dev/null; then warn '定时自动更新：已启用，未运行'; else info '定时自动更新：未开启'; fi; fi
    printf '1. 手动更新\n2. 关闭自动更新\n3. 开启自动更新\n'
    [[ $kind != official ]] || printf '4. 查找更新文件\n'
    printf '0. 返回\n'
    read -r -p '请选择: ' a
    case $a in
        1) panel_update manual;;
        2) if [[ $kind == official ]]; then official_auto off; else timer_off "panel-$key"; fi;;
        3) if [[ $kind == official ]]; then official_auto on; else read -r -p '每天更新时间（HH:MM）: ' t; timer_set "panel-$key" "--update-panel $key" "$t"; fi;;
        4) [[ $kind != official ]] || official_update_file;;
    esac
}
update_panel_key(){ local row kind name rawpath source idx path key; [[ -s $CFG ]] || return 1; while IFS= read -r row; do panel_load "$row" || continue; if [[ $key == "$1" && $kind != official ]]; then panel_update auto; return $?; fi; done < <(panels); err '配置中找不到此面板，未执行更新'; }
show_defaults(){
    local u row kind name rawpath source idx path key
    u=$(settings_get '.sub_url // empty') || return 1
    printf '\nSub-Store: %s\n' "${u:-未设置}"
    if [[ ! -s $CFG ]]; then printf '面板：暂无配置\n'; return 0; fi
    while IFS= read -r row; do
        panel_load "$row" || continue
        printf '%s: %s\n' "${path##*/}" "$source"
    done < <(panels)
}
defaults(){ local a u kind name rawpath source idx path key; printf '1. 设置 Sub-Store 链接\n2. 设置面板下载链接\n3. 恢复面板下载链接\n4. 查看当前设置信息\n0. 返回\n'; read -r -p '请选择: ' a; case $a in 1) set_sub;; 2) choose_panel || return 1; read -r -p '面板下载链接（回车取消）: ' u; [[ -n $u ]] || return 0; url_ok "$u" || { err '链接无效'; return 1; }; settings_write --arg k "${path##*/}" --arg u "$u" '.panel_urls[$k]=$u' && ok '面板下载链接已保存（用于脚本手动/定时更新）'; [[ $kind != official ]] || info '官方原生自动更新仍使用 config.json 内的 download_url';; 3) choose_panel || return 1; settings_write --arg k "${path##*/}" 'del(.panel_urls[$k])' && ok '已恢复配置中的链接';; 4) show_defaults;; esac; }
autostart(){ local a; printf '当前状态: %s\n1. 开启开机自启\n2. 关闭开机自启\n0. 返回\n' "$(systemctl is-enabled sing-box 2>/dev/null || true)"; read -r -p '请选择: ' a; case $a in 1) if [[ -e $HOLD || ! -s $CFG ]]; then err '请先使用菜单 02 导入有效配置并通过运行检测'; return 1; fi; systemctl enable sing-box && ok '已开启开机自启' ;; 2) systemctl disable sing-box && ok '已关闭开机自启';; esac; }
logs(){ local a; printf '1. 查看最近 100 行\n2. 实时日志（Ctrl+C 返回）\n0. 返回\n'; read -r -p '请选择: ' a; case $a in 1) journalctl -u sing-box -n 100 --no-pager -o cat;; 2) journalctl -u sing-box -n 50 -f -o cat;; esac; }
init_lock(){
# /run/lock 可能是共享 sticky 目录；拒绝预置的符号链接、硬链接或非 root 文件。
[[ -d /run/lock && ! -L /run/lock ]] || { err '/run/lock 不可用'; return 1; }
if [[ ! -e $LOCK && ! -L $LOCK ]]; then (set -o noclobber; : > "$LOCK") || { [[ -f $LOCK && ! -L $LOCK ]] || return 1; }; fi
[[ ! -L $LOCK && -f $LOCK && $(stat -c '%u:%h' -- "$LOCK") == 0:1 ]] || { err '运行时任务锁不安全'; return 1; }
chmod 600 "$LOCK" || return 1
}
locked(){
    need flock || return 1
    init_lock || return 1
    ( flock -n 9 || { err '已有管理任务正在执行，请稍后重试'; exit 1; }; init_runtime && "$@" ) 9<"$LOCK"
}
status_width(){
    local LC_ALL=C.UTF-8 str=$1 ch i w=0
    for ((i=0;i<${#str};i++)); do
        ch=${str:i:1}; if [[ $ch == [$'\x01'-$'\x7f'] ]]; then ((w+=1)); else ((w+=2)); fi
    done
    printf '%s' "$w"
}
status_pad(){ local n; n=$(($1-$(status_width "$2"))); ((n>=2)) || n=2; printf '%*s' "$n" ''; }
menu_status(){
    local v=$1 service=$2 enabled=$3 a b sc ec update
    case $service in active) service='运行中'; sc=$G;; inactive) service='已停止'; sc=$Y;; failed) service='异常'; sc=$R;; *) service='未知'; sc=$Y;; esac
    case $enabled in enabled|enabled-runtime) enabled='开启'; ec=$G;; disabled|masked) enabled='关闭'; ec=$Y;; *) enabled='未知'; ec=$Y;; esac
    a="版本：${v:-未安装}"; b="服务：$service"
    update=$(config_update_status)
    # 固定列宽；超长预发行版本号单独显示，防止挤乱状态栏。
    if (( $(status_width "$a") > 14 )); then
        printf '  %s\n  服务：%s%s%s%s自启：%s%s%s\n' "$a" "$sc" "$service" "$N" "$(status_pad 14 "$b")" "$ec" "$enabled" "$N"
    else
        printf '  %s%s服务：%s%s%s%s自启：%s%s%s\n' "$a" "$(status_pad 16 "$a")" "$sc" "$service" "$N" "$(status_pad 14 "$b")" "$ec" "$enabled" "$N"
    fi
    printf '  更新：%s\n' "$update"
}
menu_draw(){
    local i accent='' title='' reset="$N" rule='──────────────────────────────────────────'
    local -a names=('安装升级' '更新配置' '自动更新' '默认参数' '开启转发' '重启服务' '停止服务' '查看日志' '自启管理' '更新面板')
    if [[ -n $N ]]; then accent=$'\e[1;96m'; title=$'\e[1;97;44m'; fi
    printf '%s%s%s\n' "$accent" "$rule" "$reset"
    printf '%s          sing-box 管理工具               %s\n' "$title" "$reset"
    printf '%s%s%s\n\n' "$accent" "$rule" "$reset"
    menu_status "$1" "$2" "$3"
    printf '\n%s── 功能菜单 ──────────────────────────────%s\n\n' "$accent" "$reset"
    for ((i=0;i<10;i+=2)); do
        printf '  %s%02d%s  %s        %s%02d%s  %s\n' "$accent" "$((i+1))" "$reset" "${names[i]}" "$accent" "$((i+2))" "$reset" "${names[i+1]}"
    done
    printf '\n  %s00%s  退出\n\n%s%s%s\n' "$Y" "$reset" "$accent" "$rule" "$reset"
}
main(){ local a v s e; while true; do
    [[ ! -t 1 ]] || printf '\033[2J\033[H'
    v=$(version) || v=''; s=$(timeout 2s systemctl is-active sing-box 2>/dev/null || true); e=$(timeout 2s systemctl is-enabled sing-box 2>/dev/null || true)
    menu_draw "$v" "$s" "$e"
    read -r -p '  请输入功能编号: ' a || return 0
    printf '\n'
    case $a in 1|01) install_box;; 2|02) locked update_config manual;; 3|03) locked auto_config;; 4|04) locked defaults;; 5|05) locked forwarding;; 6|06) locked restart_box && ok '服务已重启' || err '重启失败，请查看日志';; 7|07) locked systemctl stop sing-box && ok '服务已停止';; 8|08) trap ' : ' INT; (trap 'exit 130' INT; logs); trap - INT;; 9|09) locked autostart;; 10) locked panel_menu;; 0|00) return 0;; *) warn '请输入 0 到 10';; esac
    printf '\n'; read -r -p '按回车返回主菜单……' a || return 0
 done; }
[[ $EUID == 0 ]] || { err '请使用 root 用户运行'; exit 1; }
init_runtime(){
need systemctl flock realpath || return 1
[[ -d /run/systemd/system ]] || { err '本脚本需要 systemd（Debian / Ubuntu）'; return 1; }
[[ ! -L $DIR ]] || { err '配置目录不得是符号链接'; return 1; }
mkdir -p "$DIR" || return 1
# Directory stays writable for cache/panel creation, with sticky bit protecting root-owned files.
if [[ $(stat -c '%u:%a' "$DIR") != 0:1770 ]]; then
    chown root:root "$DIR" && chmod 1700 "$DIR" || return 1
fi
# Refuse existing unsafe management files rather than following links or trusting their contents.
for f in "$DIR"/sb "$DIR"/sb.conf "$DIR"/sb.lock "$DIR"/sb-* "$DIR"/install.log "$DIR"/config-*.bak "$BACKUP"; do
    [[ -e $f || -L $f ]] || continue
    [[ ! -L $f && -f $f && $(stat -c '%u' -- "$f") == 0 && $(stat -c '%h' -- "$f") == 1 ]] || { err "管理文件不安全：$f"; return 1; }
    if [[ $f == "$DIR/sb" ]]; then chmod 700 "$f" || return 1; else chmod 600 "$f" || return 1; fi
done
if [[ ! -e $SETTINGS ]]; then
    need jq || return 1
    atomic_text "$SETTINGS" '{"sub_url":"","panel_urls":{}}' || return 1
    # Old subscription link is imported only if it looks like an HTTP(S) URL.
    if [[ -f $DIR/config.url && ! -L $DIR/config.url ]]; then
        IFS= read -r old_url < "$DIR/config.url" || true
        if url_ok "${old_url:-}"; then settings_write --arg u "$old_url" '.sub_url=$u' || return 1; fi
    fi
fi
if getent group sing-box >/dev/null; then chown root:sing-box "$DIR" && chmod 1770 "$DIR" || return 1; else chmod 1755 "$DIR" || return 1; fi
}
# Install/update the manager itself. The core, configuration and timers are untouched.
# Download this script to a file before invoking --install.
install_dependencies(){
    local -a packages=()
    command -v curl >/dev/null || packages+=(curl)
    command -v jq >/dev/null || packages+=(jq)
    command -v python3 >/dev/null || packages+=(python3)
    command -v flock >/dev/null || packages+=(util-linux)
    command -v ip >/dev/null && command -v ss >/dev/null || packages+=(iproute2)
    command -v sysctl >/dev/null || packages+=(procps)
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    ((${#packages[@]})) || return 0
    need apt-get || return 1
    info "安装管理工具缺少的依赖：${packages[*]}"
    apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update &&
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 install -y --no-install-recommends "${packages[@]}" || { err '依赖安装失败，请检查 APT 网络或软件源后重新运行安装命令'; return 1; }
}
# Only root-owned, non-linked, non-group/world-writable startup files are edited.
trusted_file(){
    local f=$1 mode
    [[ -f $f && ! -L $f && $(stat -c '%u:%h' -- "$f") == 0:1 ]] || return 1
    mode=$(stat -c '%a' -- "$f") || return 1
    (( (8#$mode & 022) == 0 ))
}
trusted_dir(){
    local d=$1 mode
    [[ -d $d && ! -L $d && $(stat -c '%u' -- "$d") == 0 ]] || return 1
    mode=$(stat -c '%a' -- "$d") || return 1
    (( (8#$mode & 022) == 0 ))
}
add_shell_hook(){
    local f=$1 line='[ ! -r /etc/profile.d/sb.sh ] || . /etc/profile.d/sb.sh'
    if [[ -e $f || -L $f ]]; then
        trusted_file "$f" || { err "启动文件不安全，未修改：$f"; return 1; }
        grep -Fxq -- "$line" "$f" && return 0
    fi
    printf '\n# sing-box manager shortcut\n%s\n' "$line" >> "$f"
}
install_shortcut(){
    local profile=/etc/profile.d/sb.sh login=/root/.profile tmp
    trusted_dir /etc/profile.d && trusted_dir /root || { err '登录配置目录权限不安全'; return 1; }
    if [[ -e $profile || -L $profile ]]; then
        trusted_file "$profile" || { err "快捷入口文件不安全：$profile"; return 1; }
        # Do not overwrite an unrelated administrator's script.
        if ! grep -Fxq '# sing-box manager shortcut' "$profile" &&
           ! grep -Fxq "alias sb='/usr/local/bin/sb'" "$profile" &&
           ! grep -Fxq "alias sb='/bin/bash /usr/local/bin/sb'" "$profile"; then
            err "发现非本工具的快捷入口：$profile，请检查后再安装"; return 1
        fi
    fi
    tmp=$(mktemp /etc/profile.d/.sb-profile.XXXXXXXX) || return 1
    cat > "$tmp" <<'PROFILE'
# sing-box manager shortcut
# Loaded by root's Bash login and interactive startup files.
if [ "$(id -u)" = 0 ]; then
    case "$PATH" in
        /usr/local/bin|/usr/local/bin:*) ;;
        *) export PATH="/usr/local/bin:$PATH" ;;
    esac
    if [ -n "${BASH_VERSION:-}" ]; then
        alias sb='/usr/local/bin/sb'
        hash -r 2>/dev/null || :
    fi
fi
PROFILE
    if ! chmod 644 "$tmp" || ! mv -fT -- "$tmp" "$profile"; then rm -f -- "$tmp"; return 1; fi
    # Bash reads only the first existing login file in this order.
    if [[ -e /root/.bash_profile || -L /root/.bash_profile ]]; then login=/root/.bash_profile
    elif [[ -e /root/.bash_login || -L /root/.bash_login ]]; then login=/root/.bash_login; fi
    add_shell_hook /root/.bashrc && add_shell_hook "$login" || return 1
    # Verify the managed shortcut in an isolated Bash (no user startup code).
    /bin/bash --noprofile --norc -c '. /etc/profile.d/sb.sh; [[ $(type -P sb) == /usr/local/bin/sb && ${BASH_ALIASES[sb]:-} == /usr/local/bin/sb ]]' || { err '快捷入口验证失败'; return 1; }
}
menu_check(){
    local out
    out=$(printf '00\n' | timeout 15s "$1" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
    [[ $out == *'sing-box 管理工具'* && $out == *'安装升级'* && $out == *'更新面板'* ]]
}
install_manager(){
    need realpath timeout install stat || return 1
    local src origin=${BASH_SOURCE[0]:-}
    [[ -n $origin && -f $origin ]] || { err '请先使用 curl -o 下载 sb.sh，再执行 bash sb.sh --install（不能直接使用 curl | bash 安装本文件）'; return 1; }
    src=$(realpath -e -- "$origin" 2>/dev/null) || { err '无法找到安装源文件，请先下载 sb.sh'; return 1; }
    [[ -f $src ]] || { err '安装源必须是普通文件'; return 1; }
    [[ -d /run/systemd/system ]] || { err '需要正在运行 systemd 的 Debian / Ubuntu 系统'; return 1; }
    install_dependencies || return 1
    need curl jq python3 flock systemctl systemd-run ip sysctl || return 1
    init_lock || return 1
    (
        flock -n 9 || { err '有管理任务正在运行，请结束后再更新管理工具'; exit 1; }
        local dir staged='' previous='' had=0 changed=0
        dir=${SELF%/*}
        mkdir -p -- "$dir" || exit 1
        trusted_dir "$dir" || { err '安装目录权限不安全'; exit 1; }
        trap 'rm -f -- "$staged" "$previous"' EXIT
        staged=$(mktemp "$dir/.sb-install.XXXXXXXX") || exit 1
        install -o root -g root -m 755 -- "$src" "$staged" || exit 1
        bash -n "$staged" || { err '语法检查失败，旧脚本未修改'; exit 1; }
        menu_check "$staged" || { err '菜单启动检查失败，旧脚本未修改'; exit 1; }
        if [[ -e $SELF || -L $SELF ]]; then
            [[ -f $SELF && $(stat -Lc '%u' -- "$SELF") == 0 ]] && grep -Fq 'sing-box 管理工具' "$SELF" || { err "发现其他同名命令：$SELF，拒绝覆盖"; exit 1; }
            had=1
        fi
        if ((had)) && cmp -s -- "$staged" "$SELF" && [[ ! -L $SELF ]]; then
            chown root:root "$SELF" && chmod 755 "$SELF" || exit 1
        else
            if ((had)); then
                previous=$(mktemp "$dir/.sb-backup.XXXXXXXX") || exit 1
                install -o root -g root -m 700 -- "$SELF" "$previous" && mv -fT -- "$previous" "$dir/.sb.previous" || exit 1
            fi
            mv -fT -- "$staged" "$SELF" || exit 1
            changed=1
        fi
        # Execute the installed path directly, not via bash (tests shebang and executable permission).
        if ! menu_check "$SELF"; then
            if ((changed && had)); then
                install -o root -g root -m 755 -- "$dir/.sb.previous" "$staged" && mv -fT -- "$staged" "$SELF" || warn "旧版恢复失败，备份：$dir/.sb.previous"
            elif ((changed)); then rm -f -- "$SELF"; fi
            err '安装后的菜单验证失败'; exit 1
        fi
        install_shortcut || { err "脚本已写入 $SELF，但快捷入口配置未完成，请按错误提示处理"; exit 1; }
        ok "管理工具已安装并通过菜单测试：$SELF"
    ) 9<"$LOCK" || return 1
    printf '\n当前 SSH 会话执行：. /etc/profile.d/sb.sh\n然后输入 sb。以后重新登录可直接输入 sb。\n不会安装或重启 sing-box 内核，不会修改订阅、面板或定时任务。\n'
}
case ${1:-} in --network-guard-stop) warn '失联保护超时，停止内核'; safety_stop;; '') main;; --install) install_manager;; --update-config) locked config_update_due;; --update-panel) [[ ${2:-} =~ ^[a-f0-9]{16}$ ]] || exit 1; locked update_panel_key "$2";; *) err '未知参数'; exit 1;; esac
