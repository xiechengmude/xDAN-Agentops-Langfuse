#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Langfuse 生产环境部署脚本
# 用法:
#   ./deploy/scripts/deploy_prod.sh          # 常规更新
#   ./deploy/scripts/deploy_prod.sh --init   # 首次部署 (创建目录 + 初始化)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.prd.yml"
ENV_FILE="$PROJECT_DIR/.env"
DATA_DIR="$DEPLOY_DIR/data"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# ============================================================================
# 参数解析
# ============================================================================
INIT_MODE=false

for arg in "$@"; do
    case $arg in
        --init)
            INIT_MODE=true
            shift
            ;;
        *)
            log_error "Unknown argument: $arg"
            echo "Usage: $0 [--init]"
            exit 1
            ;;
    esac
done

# ============================================================================
# 前置检查
# ============================================================================
echo ""
echo "========================================"
echo "  Langfuse 生产环境部署"
echo "========================================"
echo ""
log_info "项目路径:   $PROJECT_DIR"
log_info "Compose:    $COMPOSE_FILE"
log_info "数据目录:   $DATA_DIR"
log_info "模式:       $(if $INIT_MODE; then echo '首次部署 (--init)'; else echo '常规更新'; fi)"
echo ""

# 检查 docker
if ! command -v docker &> /dev/null; then
    log_error "Docker 未安装!"
    exit 1
fi

# 检查 .env 文件
if [ ! -f "$ENV_FILE" ]; then
    log_warn ".env 文件不存在"
    if [ -f "$DEPLOY_DIR/.env.example" ]; then
        log_info "从模板创建: cp deploy/.env.example .env"
        cp "$DEPLOY_DIR/.env.example" "$ENV_FILE"
        log_warn "请编辑 .env 文件，修改所有 CHANGEME 标记的变量!"
        log_warn "然后重新运行此脚本"
        exit 1
    else
        log_error "未找到 .env 模板，请手动创建 .env 文件"
        exit 1
    fi
fi

# 检查 .env 中是否还有 CHANGEME
if grep -q "CHANGEME" "$ENV_FILE"; then
    log_warn ".env 文件中仍有 CHANGEME 占位符，请确认已修改所有密码!"
    echo ""
    grep --color=always "CHANGEME" "$ENV_FILE" || true
    echo ""
    read -p "是否继续部署? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "已取消部署，请先修改 .env 文件"
        exit 0
    fi
fi

# ============================================================================
# 首次部署: 创建本地持久化目录
# ============================================================================
if $INIT_MODE; then
    log_step "创建本地持久化数据目录..."
    mkdir -p "$DATA_DIR/postgres"
    mkdir -p "$DATA_DIR/clickhouse/data"
    mkdir -p "$DATA_DIR/clickhouse/logs"
    mkdir -p "$DATA_DIR/redis"
    mkdir -p "$DATA_DIR/minio"

    # ClickHouse 需要 101:101 用户权限
    chown -R 101:101 "$DATA_DIR/clickhouse" 2>/dev/null || \
        log_warn "无法设置 ClickHouse 目录权限 (非 root?), Docker 会自动处理"

    log_info "数据目录已创建:"
    ls -la "$DATA_DIR/"
    echo ""
fi

# 检查数据目录是否存在
if [ ! -d "$DATA_DIR" ]; then
    log_error "数据目录 $DATA_DIR 不存在! 请使用 --init 参数首次部署"
    exit 1
fi

# ============================================================================
# 记录当前状态
# ============================================================================
log_step "当前容器状态"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps 2>/dev/null || log_warn "当前没有运行中的容器"
echo ""

# ============================================================================
# 拉取最新代码
# ============================================================================
log_step "拉取最新代码..."
cd "$PROJECT_DIR"
git pull

# ============================================================================
# 拉取最新镜像
# ============================================================================
log_step "拉取最新 Docker 镜像..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull

# ============================================================================
# 停止旧服务 (不删除数据卷)
# ============================================================================
log_step "停止旧服务..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down

# ============================================================================
# 启动服务
# ============================================================================
log_step "启动服务..."
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

# ============================================================================
# 等待服务就绪
# ============================================================================
log_step "等待服务就绪..."

MAX_RETRIES=60
RETRY_INTERVAL=3

for i in $(seq 1 $MAX_RETRIES); do
    if curl -sf http://localhost:3000/api/public/health > /dev/null 2>&1; then
        echo ""
        log_info "Web 服务已就绪!"
        break
    fi
    if [ "$i" -eq "$MAX_RETRIES" ]; then
        echo ""
        log_error "Web 服务未在 $((MAX_RETRIES * RETRY_INTERVAL)) 秒内就绪"
        log_error "请检查日志: docker compose -f $COMPOSE_FILE --env-file $ENV_FILE logs langfuse-web --tail 50"
        exit 1
    fi
    echo -n "."
    sleep $RETRY_INTERVAL
done

# ============================================================================
# 验证服务
# ============================================================================
echo ""
log_step "验证服务状态"
echo ""
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps
echo ""

# Health checks
WEB_HEALTH=$(curl -sf http://localhost:3000/api/public/health 2>&1 || echo "FAIL")
WORKER_HEALTH=$(curl -sf http://localhost:3030/api/health 2>&1 || echo "FAIL")

log_info "Web Health:    $WEB_HEALTH"
log_info "Worker Health: $WORKER_HEALTH"

# ============================================================================
# 显示持久化数据大小
# ============================================================================
echo ""
log_step "数据目录占用"
du -sh "$DATA_DIR"/* 2>/dev/null || true

# ============================================================================
# 完成
# ============================================================================
echo ""
echo "========================================"
log_info "部署完成!"
echo "========================================"
echo ""
log_info "Web UI:  http://localhost:${WEB_PORT:-3000}"

if $INIT_MODE; then
    echo ""
    log_info "Admin 账号 (首次启动自动创建):"
    log_info "  邮箱:  $(grep LANGFUSE_INIT_USER_EMAIL "$ENV_FILE" | cut -d= -f2 || echo 'admin@xdan.ai')"
    log_info "  密码:  (见 .env 中 LANGFUSE_INIT_USER_PASSWORD)"
    log_info "  PK:    $(grep LANGFUSE_INIT_PROJECT_PUBLIC_KEY "$ENV_FILE" | cut -d= -f2 || echo 'pk-lf-xdan-default')"
    log_info "  SK:    $(grep LANGFUSE_INIT_PROJECT_SECRET_KEY "$ENV_FILE" | cut -d= -f2 || echo 'sk-lf-xdan-default')"
fi
echo ""
