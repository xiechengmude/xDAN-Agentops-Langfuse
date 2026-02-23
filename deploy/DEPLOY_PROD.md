# Langfuse Prod 服务器部署

## 服务器信息

| 项目 | 值 |
|------|-----|
| IP | 43.128.100.43 |
| Web 端口 | 5005 |
| Worker 端口 | 3030 (仅内部) |
| 分支 | main |
| 项目路径 | /workspace/xDAN-Agentops-Langfuse |
| Compose 文件 | deploy/docker-compose.prd.yml |
| Web 镜像 | langfuse/langfuse:3 |
| Worker 镜像 | langfuse/langfuse-worker:3 |

## 服务架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  docker-compose.prd.yml (Langfuse 全栈部署)                                  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                   langfuse-web (3000) ← 对外暴露                     │    │
│  │                   Next.js Web 应用 + tRPC + REST API                 │    │
│  │                   (首次启动自动创建 Admin 账号)                        │    │
│  └───────────────────────────┬─────────────────────────────────────────┘    │
│                              │                                              │
│  ┌───────────────────────────┴─────────────────────────────────────────┐    │
│  │                   langfuse-worker (3030) ← 仅内部                    │    │
│  │                   Express.js + BullMQ 后台任务处理                    │    │
│  └───────────────────────────┬─────────────────────────────────────────┘    │
│                              │                                              │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌──────────────┐            │
│  │ PostgreSQL  │ │ ClickHouse │ │   Redis    │ │  MinIO (S3)  │            │
│  │ (5432)      │ │ (8123/9000)│ │   (6379)   │ │  (9090/9091) │            │
│  │ 主数据库    │ │ 分析数据库  │ │ 缓存+队列  │ │  对象存储     │            │
│  └──────┬─────┘ └─────┬──────┘ └─────┬──────┘ └──────┬───────┘            │
│         │             │              │               │                     │
│  deploy/data/   deploy/data/   deploy/data/    deploy/data/                │
│   postgres/    clickhouse/       redis/          minio/                    │
│  (本地持久化)  (本地持久化)    (本地持久化)    (本地持久化)                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 本地持久化目录

所有数据映射到 `deploy/data/` 本地目录，方便备份、迁移和查看:

```
deploy/
├── docker-compose.prd.yml
├── .env.example
├── DEPLOY_PROD.md
├── scripts/
│   └── deploy_prod.sh
└── data/                          ← 所有持久化数据
    ├── postgres/                  ← PostgreSQL 数据
    ├── clickhouse/
    │   ├── data/                  ← ClickHouse 数据
    │   └── logs/                  ← ClickHouse 日志
    ├── redis/                     ← Redis AOF 持久化
    └── minio/                     ← MinIO 对象存储 (媒体/导出)
```

## Admin 初始化账号

首次启动时 Langfuse 会自动创建以下管理员账号 (在 `.env` 中配置):

| 项目 | 默认值 |
|------|--------|
| 邮箱 | admin@xdan.ai |
| 密码 | xdan@2024 |
| 组织 | xDAN |
| 项目 | xDAN AgentOps |
| Public Key | pk-lf-xdan-default |
| Secret Key | sk-lf-xdan-default |

> 已有数据的情况下不会重复创建。PK/SK 可直接用于 SDK 接入。

## 日常代码更新

```bash
ssh root@43.128.100.43 "cd /workspace/xDAN-Agentops-Langfuse && git pull && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env pull && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env down && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env up -d"
```

## 完整部署

### 方式 1: 一键部署脚本 (推荐)

```bash
# 首次部署 (创建数据目录 + 初始化 Admin)
./deploy/scripts/deploy_prod.sh --init

# 日常更新
./deploy/scripts/deploy_prod.sh
```

### 方式 2: SSH 远程执行

```bash
ssh root@43.128.100.43 '/workspace/xDAN-Agentops-Langfuse/deploy/scripts/deploy_prod.sh'
```

### 方式 3: 分步部署 (首次/调试)

```bash
# 1. 克隆代码
ssh root@43.128.100.43 "git clone https://github.com/YOUR_ORG/xDAN-Agentops-Langfuse.git /workspace/xDAN-Agentops-Langfuse"

# 2. 配置环境变量
ssh root@43.128.100.43 "cd /workspace/xDAN-Agentops-Langfuse && cp deploy/.env.example .env"
# 编辑 .env，修改所有 CHANGEME 占位符

# 3. 创建持久化数据目录
ssh root@43.128.100.43 "cd /workspace/xDAN-Agentops-Langfuse && \
  mkdir -p deploy/data/{postgres,clickhouse/data,clickhouse/logs,redis,minio} && \
  chown -R 101:101 deploy/data/clickhouse"

# 4. 拉取镜像并启动
ssh root@43.128.100.43 "cd /workspace/xDAN-Agentops-Langfuse && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env pull && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env up -d"

# 5. 验证
ssh root@43.128.100.43 "curl -s http://localhost:3000/api/public/health"
```

## 验证服务

```bash
# Web 应用健康检查
ssh root@43.128.100.43 "curl -s http://localhost:3000/api/public/health"

# Web 应用就绪检查
ssh root@43.128.100.43 "curl -s http://localhost:3000/api/public/ready"

# Worker 健康检查
ssh root@43.128.100.43 "curl -s http://localhost:3030/api/health"

# PostgreSQL
ssh root@43.128.100.43 "docker exec langfuse-postgres pg_isready -U postgres"

# ClickHouse
ssh root@43.128.100.43 "curl -s http://localhost:8123/ping"

# Redis
ssh root@43.128.100.43 "docker exec langfuse-redis redis-cli -a myredissecret ping"

# MinIO
ssh root@43.128.100.43 "curl -s http://localhost:9090/minio/health/live"
```

## 查看日志

```bash
# 所有服务
ssh root@43.128.100.43 "cd /workspace/xDAN-Agentops-Langfuse && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env logs --tail 100 -f"

# Web 应用
ssh root@43.128.100.43 "docker logs langfuse-web --tail 100 -f"

# Worker
ssh root@43.128.100.43 "docker logs langfuse-worker --tail 100 -f"

# PostgreSQL
ssh root@43.128.100.43 "docker logs langfuse-postgres --tail 100 -f"

# ClickHouse
ssh root@43.128.100.43 "docker logs langfuse-clickhouse --tail 100 -f"

# Redis
ssh root@43.128.100.43 "docker logs langfuse-redis --tail 100 -f"
```

## 查看容器状态

```bash
ssh root@43.128.100.43 "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
```

## Docker 服务名映射

| 用途 | 容器名 | 端口 | 对外暴露 |
|------|--------|------|----------|
| Web 应用 | langfuse-web | 3000 | 是 |
| Worker | langfuse-worker | 3030 | 否 (127.0.0.1) |
| PostgreSQL | langfuse-postgres | 5432 | 否 (127.0.0.1) |
| ClickHouse | langfuse-clickhouse | 8123/9000 | 否 (127.0.0.1) |
| Redis | langfuse-redis | 6379 | 否 (127.0.0.1) |
| MinIO API | langfuse-minio | 9090 | 否 (127.0.0.1) |
| MinIO Console | langfuse-minio | 9091 | 否 (127.0.0.1) |

## 数据备份

```bash
# 备份 PostgreSQL
ssh root@43.128.100.43 "docker exec langfuse-postgres pg_dump -U postgres postgres | gzip > /backup/langfuse_pg_$(date +%Y%m%d).sql.gz"

# 备份整个数据目录 (停服状态更安全)
ssh root@43.128.100.43 "tar -czf /backup/langfuse_data_$(date +%Y%m%d).tar.gz -C /workspace/xDAN-Agentops-Langfuse/deploy data/"

# 查看数据目录大小
ssh root@43.128.100.43 "du -sh /workspace/xDAN-Agentops-Langfuse/deploy/data/*"
```

## 数据库迁移

Langfuse 启动时自动执行 PostgreSQL 和 ClickHouse 迁移，无需手动操作。

| 场景 | 操作 | 说明 |
|------|------|------|
| 普通更新 | `pull && up -d` | 自动迁移 |
| 禁用自动迁移 | `.env` 设置 `LANGFUSE_AUTO_POSTGRES_MIGRATION_DISABLED=true` | 手动控制 |
| ClickHouse 迁移 | Worker 自动执行 | 通过 `CLICKHOUSE_MIGRATION_URL` |

## 版本升级

```bash
# 1. 备份 (重要!)
ssh root@43.128.100.43 "docker exec langfuse-postgres pg_dump -U postgres postgres | gzip > /backup/langfuse_pg_pre_upgrade_$(date +%Y%m%d).sql.gz"

# 2. 更新并重启
ssh root@43.128.100.43 "cd /workspace/xDAN-Agentops-Langfuse && git pull && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env pull && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env down && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env up -d"

# 3. 验证
ssh root@43.128.100.43 "curl -s http://localhost:3000/api/public/health"
```

## 单服务快速重启

```bash
# 仅重启 Web (不影响其他服务)
ssh root@43.128.100.43 "cd /workspace/xDAN-Agentops-Langfuse && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env pull langfuse-web && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env up -d langfuse-web"

# 仅重启 Worker
ssh root@43.128.100.43 "cd /workspace/xDAN-Agentops-Langfuse && \
  docker compose -f deploy/docker-compose.prd.yml --env-file .env up -d langfuse-worker"
```

## 端口冲突说明 (43.128.100.43)

服务器已有大量服务运行，以下为端口分配:

| Langfuse 服务 | 端口 | 说明 |
|---------------|------|------|
| Web | 3000 | 无冲突 |
| Worker | 3030 | 无冲突，仅 127.0.0.1 |
| PostgreSQL | 5432 | 无冲突，仅 127.0.0.1 |
| ClickHouse | 8123/9000 | 无冲突，仅 127.0.0.1 |
| Redis | **6380** | 避开 6379 (xdan-vibe-admin-redis 占用) |
| MinIO | 9090/9091 | 无冲突，仅 127.0.0.1 |

> Redis 宿主机端口改为 6380 (容器内部仍为 6379)，通过 `REDIS_HOST_PORT=6380` 配置。

## 安全建议

1. **密码**: 所有 CHANGEME 必须替换为强密码
2. **网络**: 仅 Web (3000) 对外，其余绑定 127.0.0.1
3. **HTTPS**: 生产环境用已有的 Nginx 反向代理 + TLS (服务器已有 Nginx on 80/443)
4. **注册**: 推荐设置 `AUTH_DISABLE_SIGNUP=true` 禁止公开注册
5. **备份**: 定期备份 `deploy/data/` 目录
6. **防火墙**: 仅开放 80, 443 端口

## 注意事项

- 使用 `deploy/docker-compose.prd.yml` 而非根目录的 `docker-compose.yml`
- 所有数据持久化在 `deploy/data/` 本地目录，不使用 Docker named volumes
- **修改 .env 后需要 `docker compose down && up -d`，`docker restart` 不加载新环境变量**
- Admin 账号仅在首次启动 (空库) 时自动创建
- ClickHouse 目录需要 101:101 用户权限
- MinIO 启动时自动创建 `langfuse` bucket
- 建议使用 tmux 执行长时间部署命令

## 快速参考 (AI 助手用)

```bash
# 完整 compose 命令前缀
COMPOSE="docker compose -f deploy/docker-compose.prd.yml --env-file .env"

# 启动
$COMPOSE up -d

# 停止
$COMPOSE down

# 日志
$COMPOSE logs -f

# 状态
$COMPOSE ps
```
