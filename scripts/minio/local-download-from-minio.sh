#!/usr/bin/env bash
# 在目标机（用户本机）直接运行：从云网 data-export MinIO 下载到本地，带重试与完整性校验。
set -euo pipefail

DEFAULT_MINIO_ENDPOINT="https://minio-data.xa.hqzyai.com:9443"
DEFAULT_MINIO_BUCKET="export"
DEFAULT_MC_ALIAS="data-minio"
DEFAULT_RETRY_MAX=5
DEFAULT_RETRY_SLEEP_SEC=10

usage() {
  cat <<'EOF'
用法：
  bash local-download-from-minio.sh <远端前缀> [本地目录]

示例：
  export AWS_ACCESS_KEY_ID='管理员发放的 access key'
  export AWS_SECRET_ACCESS_KEY='管理员发放的 secret key'
  bash local-download-from-minio.sh zhangsan/job-001 ./downloads

可选环境变量：
  MINIO_ENDPOINT        默认公网 https://minio-data.xa.hqzyai.com:9443
  MINIO_BUCKET          默认 export
  MC_BIN                mc 可执行文件路径，默认 mc
  MC_ALIAS              mc alias 名，默认 data-minio
  RETRY_MAX             失败重试次数，默认 5
  RETRY_SLEEP_SEC       重试间隔秒数，默认 10
  MC_MIRROR_WORKERS     并发数，传给 mc mirror --max-workers
  SKIP_VERIFY           设为 1 跳过下载后大小校验

说明（mc 断点续传）：
  - 单个大文件：mc 不支持 HTTP Range 字节续传；中断后重跑会重新下载该文件。
  - 整个目录：使用 mc mirror --retry，已完整落盘且大小一致的文件会跳过。
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

remote_stat_type() {
  local remote_uri="$1"
  "$mc_bin" stat --json "$remote_uri" 2>/dev/null | sed -n 's/.*"type":"\([^"]*\)".*/\1/p' | head -1
}

remote_object_size() {
  local remote_uri="$1"
  "$mc_bin" stat --json "$remote_uri" 2>/dev/null | sed -n 's/.*"size":\([0-9]*\).*/\1/p' | head -1
}

local_file_size() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo 0
    return 0
  fi
  stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0
}

verify_local_file() {
  local local_path="$1"
  local remote_uri="$2"
  if [ "${SKIP_VERIFY:-0}" = "1" ]; then
    return 0
  fi
  local remote_size local_size
  remote_size=$(remote_object_size "$remote_uri")
  local_size=$(local_file_size "$local_path")
  if [ -z "$remote_size" ] || [ "$remote_size" = "0" ]; then
    log "WARN 无法读取远端大小，跳过校验：$remote_uri"
    return 0
  fi
  if [ "$local_size" = "$remote_size" ]; then
    return 0
  fi
  log "WARN 大小不一致：本地 ${local_size} 字节，远端 ${remote_size} 字节 → $local_path"
  return 1
}

download_single_with_retry() {
  local remote_uri="$1"
  local local_path="$2"
  local attempt=1
  local max_attempts="$RETRY_MAX"

  while [ "$attempt" -le "$max_attempts" ]; do
    log "下载单文件 (${attempt}/${max_attempts})：$remote_uri"
    if "$mc_bin" cp "$remote_uri" "$local_path"; then
      if verify_local_file "$local_path" "$remote_uri"; then
        log "单文件下载完成：$local_path"
        return 0
      fi
      log "校验失败，删除不完整文件后重试"
      rm -f "$local_path"
    else
      log "mc cp 失败 (attempt ${attempt})"
      rm -f "$local_path"
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      log "等待 ${RETRY_SLEEP_SEC}s 后重试..."
      sleep "$RETRY_SLEEP_SEC"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

download_tree_with_mirror() {
  local remote_uri="$1"
  local local_dir="$2"
  local attempt=1
  local max_attempts="$RETRY_MAX"
  local mirror_args=(mirror --retry)

  if [ -n "${MC_MIRROR_WORKERS:-}" ]; then
    mirror_args+=(--max-workers "$MC_MIRROR_WORKERS")
  fi

  while [ "$attempt" -le "$max_attempts" ]; do
    log "目录同步 (${attempt}/${max_attempts})：$remote_uri → $local_dir/"
    if "${mc_bin}" "${mirror_args[@]}" "$remote_uri" "$local_dir/"; then
      log "目录下载完成（已存在且大小一致的文件会被 mirror 跳过）"
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

remote_prefix="${1%/}"
local_dir="${2:-./minio-downloads}"
minio_endpoint="${MINIO_ENDPOINT:-$DEFAULT_MINIO_ENDPOINT}"
minio_bucket="${MINIO_BUCKET:-$DEFAULT_MINIO_BUCKET}"
mc_bin="${MC_BIN:-mc}"
mc_alias="${MC_ALIAS:-$DEFAULT_MC_ALIAS}"
RETRY_MAX="${RETRY_MAX:-$DEFAULT_RETRY_MAX}"
RETRY_SLEEP_SEC="${RETRY_SLEEP_SEC:-$DEFAULT_RETRY_SLEEP_SEC}"

require_command "$mc_bin"
require_env "${AWS_ACCESS_KEY_ID:-}" "AWS_ACCESS_KEY_ID"
require_env "${AWS_SECRET_ACCESS_KEY:-}" "AWS_SECRET_ACCESS_KEY"

mkdir -p "$local_dir"

remote_base="${mc_alias}/${minio_bucket}/${remote_prefix}"
remote_uri="${remote_base}/"

log "配置 mc alias：${mc_alias} → ${minio_endpoint}"
"$mc_bin" alias set "$mc_alias" "$minio_endpoint" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"

log "下载来源：s3://${minio_bucket}/${remote_prefix}"
log "下载目录：${local_dir}（重试 ${RETRY_MAX} 次，间隔 ${RETRY_SLEEP_SEC}s）"

object_type=$(remote_stat_type "${remote_base}")
if [ -z "$object_type" ]; then
  object_type=$(remote_stat_type "${remote_uri}")
  remote_base="${remote_uri}"
fi
if [ -z "$object_type" ]; then
  echo "错误：远端路径不存在：s3://${minio_bucket}/${remote_prefix}" >&2
  exit 1
fi

if [ "$object_type" = "file" ]; then
  base_name=$(basename "$remote_prefix")
  download_single_with_retry "${remote_base}" "${local_dir}/${base_name}"
else
  download_tree_with_mirror "${remote_uri}" "$local_dir"
fi

log "全部任务已完成。"
