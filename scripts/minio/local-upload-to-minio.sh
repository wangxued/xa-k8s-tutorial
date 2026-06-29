#!/usr/bin/env bash
# 在目标机（用户本机）直接运行：上传到云网 data-export MinIO 公网端点，带重试。
set -euo pipefail

DEFAULT_MINIO_ENDPOINT="https://minio-data.xa.hqzyai.com:9443"
DEFAULT_MINIO_BUCKET="export"
DEFAULT_MC_ALIAS="data-minio"
DEFAULT_RETRY_MAX=5
DEFAULT_RETRY_SLEEP_SEC=10

usage() {
  cat <<'EOF'
用法：
  bash local-upload-to-minio.sh <本地文件或目录> [远端前缀]

示例：
  export AWS_ACCESS_KEY_ID='管理员发放的 access key'
  export AWS_SECRET_ACCESS_KEY='管理员发放的 secret key'
  bash local-upload-to-minio.sh ./dataset zhangsan/job-001-input

可选环境变量：
  MINIO_ENDPOINT        默认公网 https://minio-data.xa.hqzyai.com:9443
  MINIO_BUCKET          默认 export
  MC_BIN                mc 可执行文件路径，默认 mc
  MC_ALIAS              mc alias 名，默认 data-minio
  RETRY_MAX             失败重试次数，默认 5
  RETRY_SLEEP_SEC       重试间隔秒数，默认 10
  MC_MIRROR_WORKERS     并发数，传给 mc mirror --max-workers
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误：未找到命令 $1，请先安装 MinIO Client (mc)。" >&2
    exit 1
  fi
}

require_env() {
  local value="$1"
  local name="$2"
  if [ -z "$value" ]; then
    echo "错误：请先设置 ${name}。" >&2
    exit 1
  fi
}

local_path_type() {
  local path="$1"
  if [ -f "$path" ]; then
    echo file
  elif [ -d "$path" ]; then
    echo folder
  else
    echo unknown
  fi
}

upload_single_with_retry() {
  local local_path="$1"
  local remote_uri="$2"
  local attempt=1
  local max_attempts="$RETRY_MAX"

  while [ "$attempt" -le "$max_attempts" ]; do
    log "上传单文件 (${attempt}/${max_attempts})：$local_path → $remote_uri"
    if "$mc_bin" cp "$local_path" "$remote_uri"; then
      log "单文件上传完成：$remote_uri"
      return 0
    fi
    log "mc cp 失败 (attempt ${attempt})"
    if [ "$attempt" -lt "$max_attempts" ]; then
      log "等待 ${RETRY_SLEEP_SEC}s 后重试..."
      sleep "$RETRY_SLEEP_SEC"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

upload_tree_with_mirror() {
  local local_path="$1"
  local remote_uri="$2"
  local attempt=1
  local max_attempts="$RETRY_MAX"
  local mirror_args=(mirror --retry)

  if [ -n "${MC_MIRROR_WORKERS:-}" ]; then
    mirror_args+=(--max-workers "$MC_MIRROR_WORKERS")
  fi

  while [ "$attempt" -le "$max_attempts" ]; do
    log "目录同步 (${attempt}/${max_attempts})：$local_path/ → $remote_uri"
    if "${mc_bin}" "${mirror_args[@]}" "$local_path/" "$remote_uri"; then
      log "目录上传完成"
      return 0
    fi
    log "mc mirror 失败 (attempt ${attempt})"
    if [ "$attempt" -lt "$max_attempts" ]; then
      log "等待 ${RETRY_SLEEP_SEC}s 后重试..."
      sleep "$RETRY_SLEEP_SEC"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

local_path="$1"
remote_prefix="${2:-$(basename "$local_path")}"
minio_endpoint="${MINIO_ENDPOINT:-$DEFAULT_MINIO_ENDPOINT}"
minio_bucket="${MINIO_BUCKET:-$DEFAULT_MINIO_BUCKET}"
mc_bin="${MC_BIN:-mc}"
mc_alias="${MC_ALIAS:-$DEFAULT_MC_ALIAS}"
RETRY_MAX="${RETRY_MAX:-$DEFAULT_RETRY_MAX}"
RETRY_SLEEP_SEC="${RETRY_SLEEP_SEC:-$DEFAULT_RETRY_SLEEP_SEC}"

require_command "$mc_bin"
require_env "${AWS_ACCESS_KEY_ID:-}" "AWS_ACCESS_KEY_ID"
require_env "${AWS_SECRET_ACCESS_KEY:-}" "AWS_SECRET_ACCESS_KEY"

if [ ! -e "$local_path" ]; then
  echo "错误：本地路径不存在：$local_path" >&2
  exit 1
fi

path_type=$(local_path_type "$local_path")
if [ "$path_type" = "unknown" ]; then
  echo "错误：本地路径既不是文件也不是目录：$local_path" >&2
  exit 1
fi

remote_prefix="${remote_prefix%/}"
remote_base="${mc_alias}/${minio_bucket}/${remote_prefix}"

log "配置 mc alias：${mc_alias} → ${minio_endpoint}"
"$mc_bin" alias set "$mc_alias" "$minio_endpoint" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"

log "上传来源：$local_path"
log "上传目标：s3://${minio_bucket}/${remote_prefix}（重试 ${RETRY_MAX} 次，间隔 ${RETRY_SLEEP_SEC}s）"

if [ "$path_type" = "file" ]; then
  upload_single_with_retry "$local_path" "${remote_base}/$(basename "$local_path")"
else
  upload_tree_with_mirror "$local_path" "${remote_base}/"
fi

log "全部任务已完成。"
