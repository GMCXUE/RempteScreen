# 设备目录服务的容器镜像。
#
# 持久化：PostgreSQL（docker-compose 里独立容器）。头像处理使用 sharp，数据库连接使用 pg。

FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
COPY src ./src
COPY scripts ./scripts

# sharp 安装对应平台的预编译 libvips，保留 optional dependencies。
RUN apk add --no-cache ffmpeg && npm install --omit=dev && node scripts/check-video-runtime.mjs

ENV NODE_ENV=production
ENV PORT=8787
ENV HOST=0.0.0.0

EXPOSE 8787

CMD ["node", "src/index.mjs"]
