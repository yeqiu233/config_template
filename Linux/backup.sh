#!/bin/bash
# WebDAV 备份脚本 - 自动压缩目录并同步到WebDAV

# 配置区域（用户根据实际情况修改）
WEBDAV_URL="你的webdav访问路径"
USERNAME="账号"
PASSWORD="密码"
BACKUP_DIRS=(
    "/opt/1panel/1panel/"   # 备份目录1
    "/opt/docker/nginx/"
)
LOG_FILE="/var/log/webdav_backup.log"

# 依赖检查与安装
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        echo "安装curl..."
        apt-get update && apt-get install -y curl
    fi
    
    if ! command -v tar &> /dev/null; then
        echo "安装tar..."
        apt-get install -y tar
    fi
}

# 日志记录函数 (同时输出到控制台和日志文件)
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
}

# 清空WebDAV目录函数 - 通过删除并重新创建目录
clean_webdav_directory() {
    log "开始清空WebDAV目录: $WEBDAV_URL"
    
    # 删除整个目录（递归删除）
    log "正在删除整个目录（递归删除）..."
    curl -u "$USERNAME:$PASSWORD" -X DELETE "$WEBDAV_URL" -s -o /dev/null 2>> "$LOG_FILE"
    local delete_status=$?
    if [ $delete_status -eq 0 ]; then
        log "目录删除成功"
    else
        log "目录删除失败，可能不存在或服务器不支持递归删除，尝试继续（也许目录不存在）"
    fi
    
    # 等待1秒，确保删除操作完成
    sleep 1
    
    # 重新创建目录
    log "正在重新创建目录..."
    curl -u "$USERNAME:$PASSWORD" -X MKCOL "$WEBDAV_URL" -s -o /dev/null 2>> "$LOG_FILE"
    if [ $? -eq 0 ]; then
        log "目录创建成功"
    else
        log "目录创建失败"
        return 1
    fi
    
    return 0
}

# 主备份函数
run_backup() {
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    
    # 清空整个WebDAV目录（通过删除并重建）
    clean_webdav_directory
    
    for dir in "${BACKUP_DIRS[@]}"; do
        # 验证目录存在性
        [ ! -d "$dir" ] && log "目录不存在: $dir" && continue
        
        # 获取目录名
        dir_name=$(basename "$dir")
        backup_file="${dir_name}_${TIMESTAMP}.tar.gz"
        temp_file="/tmp/$backup_file"
        
        # 压缩目录
        log "正在压缩: $dir"
        tar -czf "$temp_file" -C "$(dirname "$dir")" "$(basename "$dir")" 2>> "$LOG_FILE"
        if [ $? -ne 0 ]; then
            log "压缩失败: $dir"
            rm -f "$temp_file" &>/dev/null
            continue
        fi
        
        # 上传新备份
        log "正在上传: $backup_file"
        curl -u "$USERNAME:$PASSWORD" -T "$temp_file" "${WEBDAV_URL}${backup_file}" 2>> "$LOG_FILE"
        if [ $? -eq 0 ]; then
            log "上传成功: $backup_file"
        else
            log "上传失败: $backup_file"
        fi
        
        # 清理临时文件
        rm -f "$temp_file"
    done
    
    log "备份任务完成"
}

# 创建日志目录
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# 执行流程
check_dependencies
log "===== 备份开始 ====="
run_backup
log "===== 备份结束 ====="