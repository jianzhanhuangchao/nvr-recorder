#!/bin/bash

# 读取配置文件
CONFIG_FILE="/config/config.yaml"
VIDEO_ROOT=$(yq eval '.recording.video_root' $CONFIG_FILE)
SEGMENT_DURATION=$(yq eval '.recording.segment_duration' $CONFIG_FILE)
RETENTION_DAYS=$(yq eval '.recording.retention_days' $CONFIG_FILE)
CLEANUP_INTERVAL=$(yq eval '.cleanup.interval_hours' $CONFIG_FILE)

# 读取摄像头数量
CAMERA_COUNT=$(yq eval '.cameras | length' $CONFIG_FILE)

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 清理过期视频
cleanup_videos() {
    while true; do
        log "Starting video cleanup (keeping $RETENTION_DAYS days)"
        
        # 计算删除时间点
        DELETE_BEFORE=$(date -d "$RETENTION_DAYS days ago" +%Y%m%d)
        
        # 遍历所有摄像头目录
        for i in $(seq 0 $((CAMERA_COUNT - 1))); do
            CAMERA_NAME=$(yq eval ".cameras[$i].name" $CONFIG_FILE)
            CAMERA_DIR="$VIDEO_ROOT/$CAMERA_NAME"
            
            if [ -d "$CAMERA_DIR" ]; then
                # 删除旧文件
                find "$CAMERA_DIR" -name "*.mp4" -type f | while read file; do
                    # 从文件名提取日期
                    filename=$(basename "$file")
                    filedate=${filename:0:8}
                    
                    if [[ "$filedate" < "$DELETE_BEFORE" ]]; then
                        rm -f "$file"
                        log "Deleted: $file"
                    fi
                done
            fi
        done
        
        # 等待下次清理
        sleep $((CLEANUP_INTERVAL * 3600))
    done
}

# 录制单个摄像头
record_camera() {
    local index=$1
    local name=$(yq eval ".cameras[$index].name" $CONFIG_FILE)
    local ip=$(yq eval ".cameras[$index].ip" $CONFIG_FILE)
    local port=$(yq eval ".cameras[$index].port" $CONFIG_FILE)
    local username=$(yq eval ".cameras[$index].username" $CONFIG_FILE)
    local password=$(yq eval ".cameras[$index].password" $CONFIG_FILE)
    
    # 构建 RTSP URL
    local rtsp_url="rtsp://${username}:${password}@${ip}:${port}/Streaming/Channels/101"
    
    # 创建输出目录
    local output_dir="$VIDEO_ROOT/$name"
    mkdir -p "$output_dir"
    
    log "Starting recording: $name ($rtsp_url)"
    
    # 无限循环录制
    while true; do
        # 生成文件名
        local filename=$(date +%Y%m%d_%H%M%S).mp4
        local output_path="$output_dir/$filename"
        
        log "$name: Recording $filename"
        
        # 使用 ffmpeg 录制指定时长
        ffmpeg -i "$rtsp_url" \
            -c copy \
            -t $SEGMENT_DURATION \
            -reset_timestamps 1 \
            "$output_path" \
            2>/dev/null
        
        # 检查录制是否成功
        if [ $? -ne 0 ] || [ ! -s "$output_path" ]; then
            log "$name: Recording failed, reconnecting in 5 seconds..."
            rm -f "$output_path"
            sleep 5
        fi
    done
}

# 启动清理任务
cleanup_videos &

# 启动所有摄像头录制
for i in $(seq 0 $((CAMERA_COUNT - 1))); do
    record_camera $i &
done

# 等待所有后台进程
wait
