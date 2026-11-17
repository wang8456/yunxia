# 一次构建出「服务端 + 已编译好的网页端」的镜像。
# 只想要服务端、网页另找 nginx 发的话，把 stage web 与最后的 COPY --from 删掉即可。

FROM node:20-slim AS web
WORKDIR /build
COPY web/package.json web/package-lock.json* ./
RUN npm install --no-audit --no-fund
COPY web/ ./
RUN npm run build

FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 \
    YUNXIA_CONFIG=/app/config.json

COPY server/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY server/app ./app
COPY server/config.example.json ./config.example.json
# 服务端会自动在 <仓库根>/web/dist 找前端，这里放到 /web/dist
COPY --from=web /build/dist /web/dist

EXPOSE 8686
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8686"]
