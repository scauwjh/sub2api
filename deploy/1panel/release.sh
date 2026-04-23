#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_TEMPLATE="${PROJECT_ROOT}/deploy/.env.example"

TARGET_SERVICE="all"
SKIP_PULL="false"
SKIP_BUILD="false"

usage() {
  cat <<'EOF'
用法:
  bash deploy/1panel/release.sh [service] [--skip-pull] [--skip-build]

示例:
  bash deploy/1panel/release.sh
  bash deploy/1panel/release.sh sub2api
  bash deploy/1panel/release.sh sub2api --skip-pull

说明:
  service 可选值:
    sub2api | postgres | redis | all
  --skip-pull:
    跳过 git pull，适合代码已提前同步到服务器的场景
  --skip-build:
    跳过 docker compose build，适合仅重启或仅切换编排参数
EOF
}

log() {
  printf '[release] %s\n' "$1"
}

fail() {
  printf '[release][error] %s\n' "$1" >&2
  exit 1
}

is_valid_service() {
  case "$1" in
    all|sub2api|postgres|redis)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

generate_secret() {
  openssl rand -hex 32
}

ensure_env_file() {
  [[ -f "${ENV_TEMPLATE}" ]] || fail "找不到环境模板: ${ENV_TEMPLATE}"
  if [[ -f "${ENV_FILE}" ]]; then
    return 0
  fi

  command_exists openssl || fail "首次初始化 .env 需要 openssl"

  log "检测到 ${ENV_FILE} 不存在，开始按模板初始化"
  cp "${ENV_TEMPLATE}" "${ENV_FILE}"

  local jwt_secret
  local totp_key
  local pg_password
  jwt_secret="$(generate_secret)"
  totp_key="$(generate_secret)"
  pg_password="$(generate_secret)"

  sed -i.bak \
    -e "s/^JWT_SECRET=.*/JWT_SECRET=${jwt_secret}/" \
    -e "s/^TOTP_ENCRYPTION_KEY=.*/TOTP_ENCRYPTION_KEY=${totp_key}/" \
    -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${pg_password}/" \
    -e "s/^BIND_HOST=.*/BIND_HOST=127.0.0.1/" \
    -e "s/^SERVER_PORT=.*/SERVER_PORT=9406/" \
    -e "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=sub2api-1panel/" \
    -e "s/^TZ=.*/TZ=Asia\\/Shanghai/" \
    "${ENV_FILE}"
  rm -f "${ENV_FILE}.bak"

  chmod 600 "${ENV_FILE}"
  mkdir -p "${SCRIPT_DIR}/data" "${SCRIPT_DIR}/postgres_data" "${SCRIPT_DIR}/redis_data"

  if ! grep -q '^COMPOSE_PROJECT_NAME=' "${ENV_FILE}"; then
    printf '\nCOMPOSE_PROJECT_NAME=sub2api-1panel\n' >> "${ENV_FILE}"
  fi

  log "首次初始化完成，请按需编辑 ${ENV_FILE}"
  log "已生成 POSTGRES_PASSWORD / JWT_SECRET / TOTP_ENCRYPTION_KEY"
}

run_compose() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

wait_for_health() {
  local container_name="$1"
  local max_attempts="${2:-30}"
  local attempt=1

  while (( attempt <= max_attempts )); do
    local status
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container_name}" 2>/dev/null || true)"
    case "${status}" in
      healthy|running)
        log "健康检查通过: ${container_name} (${status})"
        return 0
        ;;
      unhealthy|exited|dead)
        fail "容器状态异常: ${container_name} (${status})"
        ;;
    esac
    sleep 2
    attempt=$((attempt + 1))
  done

  fail "等待健康检查超时: ${container_name}"
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --skip-pull)
      SKIP_PULL="true"
      ;;
    --skip-build)
      SKIP_BUILD="true"
      ;;
    *)
      if [[ "${TARGET_SERVICE}" != "all" ]]; then
        fail "只允许指定一个 service 参数"
      fi
      TARGET_SERVICE="$arg"
      ;;
  esac
done

is_valid_service "${TARGET_SERVICE}" || fail "不支持的 service: ${TARGET_SERVICE}"
[[ -f "${COMPOSE_FILE}" ]] || fail "找不到编排文件: ${COMPOSE_FILE}"

command_exists docker || fail "未找到 docker 命令"
docker compose version >/dev/null 2>&1 || fail "未找到 docker compose"

ensure_env_file

cd "${PROJECT_ROOT}"

if [[ "${SKIP_PULL}" != "true" ]]; then
  DIRTY_STATUS="$(git status --short --untracked-files=all | grep -vE '^\?\? deploy/1panel/(data|postgres_data|redis_data)(/|$)|^\?\? deploy/1panel/\.env$' || true)"
  if [[ -n "${DIRTY_STATUS}" ]]; then
    log "当前仓库存在未提交改动，已阻止 git pull，避免覆盖现场"
    printf '%s\n' "${DIRTY_STATUS}"
    fail "请先提交、清理改动，或改用 --skip-pull"
  fi

  CURRENT_BRANCH="$(git branch --show-current)"
  [[ -n "${CURRENT_BRANCH}" ]] || fail "无法确认当前分支"

  log "开始拉取最新代码: branch=${CURRENT_BRANCH}"
  git pull --ff-only origin "${CURRENT_BRANCH}"
else
  log "已按参数跳过 git pull"
fi

cd "${SCRIPT_DIR}"

log "开始校验 compose 配置"
run_compose config >/dev/null

if [[ "${SKIP_BUILD}" != "true" ]]; then
  if [[ "${TARGET_SERVICE}" == "all" ]]; then
    log "开始构建应用镜像"
    run_compose build sub2api
  elif [[ "${TARGET_SERVICE}" == "sub2api" ]]; then
    log "开始构建服务: sub2api"
    run_compose build sub2api
  else
    log "服务 ${TARGET_SERVICE} 无需本地构建，跳过 build"
  fi
else
  log "已按参数跳过 build"
fi

if [[ "${TARGET_SERVICE}" == "all" ]]; then
  log "开始发布整套服务"
  run_compose up -d
  wait_for_health sub2api-postgres
  wait_for_health sub2api-redis
  wait_for_health sub2api
else
  log "开始发布服务: ${TARGET_SERVICE}"
  run_compose up -d "${TARGET_SERVICE}"
  case "${TARGET_SERVICE}" in
    postgres)
      wait_for_health sub2api-postgres
      ;;
    redis)
      wait_for_health sub2api-redis
      ;;
    sub2api)
      wait_for_health sub2api
      ;;
  esac
fi

log "发布完成，当前容器状态如下"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | grep -E 'sub2api|postgres|redis' || true
