# 设备目录服务的容器镜像。
#
# 持久化：PostgreSQL（docker-compose 里独立容器）。本镜像只需多装 pg 一个纯 JS 依赖。

FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
COPY src ./src
COPY scripts ./scripts

# pg 是纯 JS 包，alpine 上无需编译
RUN npm install --omit=dev

ENV NODE_ENV=production
ENV PORT=8787
ENV HOST=0.0.0.0

EXPOSE 8787

CMD ["node", "src/index.mjs"]
