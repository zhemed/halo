#!/usr/bin/env bash
# Halo（自维护分叉）一键部署
#
#   curl -fsSL https://raw.githubusercontent.com/zhemed/halo/main/install.sh | bash
#
# 可选参数（管道执行时用 bash -s -- 传入）：
#   --dir <路径>      部署目录（默认 ~/halo）
#   --url <地址>      外部访问地址（默认自动探测本机 IP；如 http://10.0.0.91:8090/）
#   --port <端口>     宿主机端口（默认 8090，仅首次部署生效）
#   --no-start        只准备文件，不启动容器
#   -h, --help        显示帮助
#
# 行为要点：
#   - 幂等：已存在 .env / docker-compose.yaml 时不覆盖；已部署过则只做启动与检查
#   - 数据库密码自动随机生成，不再要求手工修改
#   - 数据落在部署目录的 ./halo2 与 ./db，升级只需改镜像 tag 后重新 up -d

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/zhemed/halo/main"
DIR="$HOME/halo"
PORT=8090
EXTERNAL_URL=""
DO_START=1

usage() { sed -n '2,20p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:?--dir 需要一个路径}"; shift 2 ;;
    --url) EXTERNAL_URL="${2:?--url 需要一个地址}"; shift 2 ;;
    --port) PORT="${2:?--port 需要一个端口}"; shift 2 ;;
    --no-start) DO_START=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1（-h 查看帮助）" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m错误:\033[0m %s\n' "$1" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1（请先安装 Docker）"; }
need docker
docker info >/dev/null 2>&1 || die "无法访问 Docker 守护进程（权限不足或未启动）。试试用 root 执行，或把当前用户加入 docker 组。"
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件（需要 Docker Compose v2）"

# ---- 探测本机 IP 作为默认 external-url ----
detect_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}
if [ -z "$EXTERNAL_URL" ]; then
  IP="$(detect_ip || true)"
  EXTERNAL_URL="http://${IP:-localhost}:${PORT}/"
fi

log "部署目录 : $DIR"
log "访问地址 : $EXTERNAL_URL"

mkdir -p "$DIR" && cd "$DIR"

# ---- 1. 取部署文件（已存在则不覆盖，避免冲掉你的配置）----
if [ -f docker-compose.yaml ]; then
  log "已存在 docker-compose.yaml，跳过下载（如要更新请手动替换）"
else
  log "下载 docker-compose.yaml"
  curl -fsSL "$REPO_RAW/deploy/docker-compose.yaml" -o docker-compose.yaml \
    || die "下载 docker-compose.yaml 失败（网络问题？）"
fi

# ---- 2. 生成 .env（随机数据库密码 + 外部地址）----
if [ -f .env ]; then
  log "已存在 .env，保留现有配置（数据库密码不变）"
else
  log "生成 .env（含随机数据库密码）"
  PW="$(head -c 36 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
  umask 077
  cat > .env <<EOF
# 由 install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')，含密钥，勿提交
HALO_DB_PASSWORD=$PW
HALO_EXTERNAL_URL=$EXTERNAL_URL
EOF
  chmod 600 .env
fi

# ---- 3. 端口（仅当用户显式指定且 compose 里仍是默认端口时才改写）----
if [ "$PORT" != "8090" ] && grep -q "0.0.0.0:8090:8090" docker-compose.yaml; then
  log "把宿主机端口改为 $PORT"
  sed -i "s/0\.0\.0\.0:8090:8090/0.0.0.0:${PORT}:8090/" docker-compose.yaml
fi

if [ "$DO_START" = "0" ]; then
  log "--no-start 指定，文件已就绪：$DIR"
  echo "    启动：cd $DIR && docker compose up -d"
  exit 0
fi

# ---- 4. 启动 ----
log "启动容器"
docker compose up -d

# ---- 5. 等待就绪 ----
log "等待 Halo 就绪（首次启动约 30–60 秒）"
READY=0
for _ in $(seq 1 40); do
  if curl -sS -o /dev/null --max-time 5 "http://127.0.0.1:${PORT}/system/setup" 2>/dev/null; then
    READY=1; break
  fi
  sleep 5
done

echo
if [ "$READY" = "1" ]; then
  log "部署完成 ✅"
else
  log "容器已启动，但暂未探到 HTTP 响应（可能仍在启动）"
  echo "    查看日志：cd $DIR && docker compose logs -f halo"
fi
cat <<EOF

  管理端：${EXTERNAL_URL%/}/console   （首次进入初始化向导）
  数据目录：$DIR/halo2 与 $DIR/db      （备份就是打包这两个目录）
  查看状态：cd $DIR && docker compose ps
  停  止：cd $DIR && docker compose down
  升  级：改 $DIR/docker-compose.yaml 里的镜像 tag 后 docker compose up -d

EOF
