FROM alpine:3.19

# 安装 ffmpeg 和基础工具
RUN apk add --no-cache \
    ffmpeg \
    bash \
    yq \
    coreutils \
    findutils \
    tzdata

# 设置时区
ENV TZ=Asia/Shanghai

# 创建必要目录
RUN mkdir -p /recordings /scripts /config

# 复制脚本
COPY recorder.sh /scripts/recorder.sh
COPY config.yaml /config/config.yaml

# 赋予执行权限
RUN chmod +x /scripts/recorder.sh

# 运行脚本
CMD ["/scripts/recorder.sh"]
