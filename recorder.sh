#!/bin/bash

CONFIG_FILE="/config/config.yaml"
VIDEO_ROOT=$(yq eval '.recording.video_root' $CONFIG_FILE)
SEGMENT_DURATION=$(yq eval '.recording.segment_duration' $CONFIG_FILE)
RETENTION_DAYS=$(yq eval '.recording.retention_days' $CONFIG_FILE)
CLEANUP_INTERVAL=$(yq eval '.cleanup.interval_hours' $CONFIG_FILE)

# 获取摄像头数量
CAMERA_COUNT=$(yq eval '.cameras | length' $CONFIG_FILE)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_info() {
    log "${GREEN}[INFO]${NC} $1"
}

log_error() {
    log "${RED}[ERROR]${NC} $1"
}

log_warn() {
    log "${YELLOW}[WARN]${NC} $1"
}

# 清理过期视频
cleanup_videos() {
    while true; do
        log_info "Starting video cleanup (keeping $RETENTION_DAYS days)"
        
        # 计算删除时间点（使用日期比较）
        DELETE_DATE=$(date -d "$RETENTION_DAYS days ago" +%Y%m%d)
        DELETED_COUNT=0
        
        # 遍历所有摄像头目录
        for i in $(seq 0 $((CAMERA_COUNT - 1))); do
            CAMERA_NAME=$(yq eval ".cameras[$i].name" $CONFIG_FILE)
            CAMERA_DIR="$VIDEO_ROOT/$CAMERA_NAME"
            
            if [ -d "$CAMERA_DIR" ]; then
                # 查找并删除旧文件
                while IFS= read -r file; do
                    # 从文件名提取日期（格式：YYYYMMDD_HHMMSS.mp4）
                    filename=$(basename "$file")
                    filedate=${filename:0:8}
                    
                    if [[ "$filedate" < "$DELETE_DATE" ]]; then
                        rm -f "$file"
                        ((DELETED_COUNT++))
                        log_info "Deleted: $file"
                    fi
                done < <(find "$CAMERA_DIR" -name "*.mp4" -type f | sort)
            fi
        done
        
        if [ $DELETED_COUNT -gt 0 ]; then
            log_info "Cleanup completed: deleted $DELETED_COUNT files"
        else
            log_info "Cleanup completed: no files to delete"
        fi
        
        # 等待下次清理（转换为秒）
        sleep $((CLEANUP_INTERVAL * 3600))
    done
}

# 检查 RTSP URL 是否有效
check_rtsp_url() {
    local url=$1
    local name=$2
    
    log_info "$name: Testing RTSP connection..."
    
    # 使用 ffmpeg 测试连接（5秒超时）
    if timeout 10 ffmpeg -i "$url" -t 1 -f null - 2>&1 | grep -q "200 OK"; then
        log_info "$name: RTSP connection successful"
        return 0
    else
        log_warn "$name: RTSP connection test failed, will retry"
        return 1
    fi
}

# 录制单个摄像头
record_camera() {
    local index=$1
    local name=$(yq eval ".cameras[$index].name" $CONFIG_FILE)
    local rtsp_url=$(yq eval ".cameras[$index].rtsp_url" $CONFIG_FILE)
    
    # 创建输出目录
    local output_dir="$VIDEO_ROOT/$name"
    mkdir -p "$output_dir"
    
    log_info "Starting recording: $name"
    log_info "  RTSP URL: $rtsp_url"
    log_info "  Output dir: $output_dir"
    
    # 等待网络就绪
    sleep 2
    
    # 无限循环录制
    while true; do
        # 生成文件名（使用当前时间）
        local filename=$(date +%Y%m%d_%H%M%S).mp4
        local output_path="$output_dir/$filename"
        local temp_path="$output_dir/temp_$filename"
        
        log_info "$name: Recording segment $filename (${SEGMENT_DURATION}s)"
        
        # 使用 ffmpeg 录制指定时长
        # -i: 输入URL
        # -c copy: 直接复制流，不重新编码（快速）
        # -t: 录制时长
        # -reset_timestamps 1: 重置时间戳
        # -y: 覆盖输出文件
        ffmpeg -i "$rtsp_url" \
            -c copy \
            -t $SEGMENT_DURATION \
            -reset_timestamps 1 \
            -y \
            "$temp_path" \
            2>/dev/null
        
        # 检查录制是否成功
        if [ $? -eq 0 ] && [ -f "$temp_path" ] && [ -s "$temp_path" ]; then
            # 重命名临时文件为正式文件
            mv "$temp_path" "$output_path"
            log_info "$name: Successfully recorded $filename ($(du -h "$output_path" | cut -f1))"
        else
            # 录制失败，删除临时文件
            [ -f "$temp_path" ] && rm -f "$temp_path"
            log_error "$name: Recording failed, reconnecting in 5 seconds..."
            
            # 测试连接
            check_rtsp_url "$rtsp_url" "$name"
            
            sleep 5
        fi
    done
}

# 显示配置信息
show_config() {
    log_info "=========================================="
    log_info "NVR Recorder Configuration"
    log_info "=========================================="
    log_info "Cameras: $CAMERA_COUNT"
    for i in $(seq 0 $((CAMERA_COUNT - 1))); do
        local name=$(yq eval ".cameras[$i].name" $CONFIG_FILE)
        local url=$(yq eval ".cameras[$i].rtsp_url" $CONFIG_FILE)
        log_info "  Camera $((i+1)): $name"
        log_info "    URL: ${url:0:50}..."
    done
    log_info "Segment duration: ${SEGMENT_DURATION}s"
    log_info "Video root: $VIDEO_ROOT"
    log_info "Retention days: $RETENTION_DAYS"
    log_info "Cleanup interval: ${CLEANUP_INTERVAL}h"
    log_info "=========================================="
}

# 主函数
main() {
    log_info "NVR Recorder starting..."
    
    # 检查配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # 显示配置
    show_config
    
    # 检查摄像头配置
    if [ $CAMERA_COUNT -eq 0 ]; then
        log_error "No cameras configured in $CONFIG_FILE"
        exit 1
    fi
    
    # 创建视频根目录
    mkdir -p "$VIDEO_ROOT"
    
    # 启动清理任务（后台运行）
    log_info "Starting cleanup service (every ${CLEANUP_INTERVAL}h)"
    cleanup_videos &
    
    # 等待一下确保清理服务启动
    sleep 2
    
    # 启动所有摄像头录制（每个摄像头独立进程）
    for i in $(seq 0 $((CAMERA_COUNT - 1))); do
        log_info "Starting recorder for camera $((i+1))"
        record_camera $i &
        # 稍微延迟，避免同时启动造成网络拥堵
        sleep 1
    done
    
    log_info "All cameras started successfully!"
    log_info "Recording in progress... (Ctrl+C to stop)"
    
    # 等待所有后台进程
    wait
}

# 捕获退出信号
trap 'log_info "Shutting down..."; kill $(jobs -p); exit 0' SIGTERM SIGINT

# 运行主函数
main
