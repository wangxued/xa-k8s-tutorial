#!/usr/bin/env sh
# 在 Pod 内运行：从集群内 data-export MinIO 下载到本地目录，并校验大小。
set -eu

DEFAULT_MINIO_ENDPOINT="http://data-minio-hl.data-export-minio.svc.cluster.local:9000"
DEFAULT_MINIO_BUCKET="export"
DEFAULT_NO_PROXY="localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,10.96.0.0/12,10.63.252.0/24,10.60.0.0/24"
DEFAULT_LOCAL_DIR="./minio-downloads"

usage() {
  cat <<'EOF'
用法：
  sh pod-download-from-minio.sh <远端前缀> [本地目录]

示例：
  export AWS_ACCESS_KEY_ID='管理员发放的 access key'
  export AWS_SECRET_ACCESS_KEY='管理员发放的 secret key'
  sh pod-download-from-minio.sh zhangsan/job-001-input /workspace/input

可选环境变量：
  MINIO_ENDPOINT   默认集群内下载地址
  MINIO_BUCKET     默认 export
  NO_PROXY         默认包含 .svc.cluster.local
  SKIP_VERIFY      设为 1 跳过下载后大小校验
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误：未找到命令 $1，请先安装 MinIO Client(mc)。" >&2
    exit 1
  fi
}

require_env() {
  if [ -z "${1:-}" ]; then
    echo "错误：请先设置 $2。" >&2
    exit 1
  fi
}

remote_stat_type() {
  remote_uri="$1"
  json=$(mc stat --json "$remote_uri" 2>/dev/null || true)
  case "$json" in
    *'"type":"file"'*) echo file ;;
    *'"type":"folder"'*) echo folder ;;
    *) echo "" ;;
  esac
}

remote_object_size() {
  remote_uri="$1"
  json=$(mc stat --json "$remote_uri" 2>/dev/null || true)
  size=${json#*"size":}
  size=${size%%,*}
  case "$size" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$size" ;;
  esac
}

local_file_size() {
  path="$1"
  if [ ! -f "$path" ]; then
    echo 0
    return 0
  fi
  wc -c < "$path" | tr -d ' '
}

verify_local_file() {
  local_path="$1"
  remote_uri="$2"
  if [ "${SKIP_VERIFY:-0}" = "1" ]; then
    return 0
  fi
  remote_size=$(remote_object_size "$remote_uri")
  local_size=$(local_file_size "$local_path")
  if [ -z "$remote_size" ] || [ "$remote_size" = "0" ]; then
    echo "WARN 无法读取远端大小，跳过校验：$remote_uri"
    return 0
  fi
  if [ "$local_size" = "$remote_size" ]; then
    return 0
  fi
  echo "错误：大小不一致：本地 ${local_size} 字节，远端 ${remote_size} 字节 → $local_path" >&2
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
local_dir="${2:-$DEFAULT_LOCAL_DIR}"
minio_endpoint="${MINIO_ENDPOINT:-$DEFAULT_MINIO_ENDPOINT}"
minio_bucket="${MINIO_BUCKET:-$DEFAULT_MINIO_BUCKET}"

require_command mc
require_env "${AWS_ACCESS_KEY_ID:-}" "AWS_ACCESS_KEY_ID"
require_env "${AWS_SECRET_ACCESS_KEY:-}" "AWS_SECRET_ACCESS_KEY"

export NO_PROXY="${NO_PROXY:-$DEFAULT_NO_PROXY}"
export no_proxy="${no_proxy:-$NO_PROXY}"

mkdir -p "$local_dir"

remote_base="data-minio/${minio_bucket}/${remote_prefix}"
remote_uri="${remote_base}/"

echo "下载来源：s3://${minio_bucket}/${remote_prefix}"
echo "下载目录：${local_dir}"

mc alias set data-minio "$minio_endpoint" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"

object_type=$(remote_stat_type "$remote_base")
if [ -z "$object_type" ]; then
  object_type=$(remote_stat_type "$remote_uri")
  remote_base="$remote_uri"
fi
if [ -z "$object_type" ]; then
  echo "错误：远端路径不存在：s3://${minio_bucket}/${remote_prefix}" >&2
  exit 1
fi

if [ "$object_type" = "file" ]; then
  base_name=$(basename "$remote_prefix")
  local_path="${local_dir}/${base_name}"
  mc cp "$remote_base" "$local_path"
  verify_local_file "$local_path" "$remote_base"
  echo "单文件下载完成：$local_path"
else
  mc mirror --retry "$remote_uri" "${local_dir}/"
  failed=0
  mc ls --recursive "$remote_uri" > /tmp/pod-download-ls.txt 2>/dev/null || true
  while read -r line; do
    [ -n "$line" ] || continue
    object_name=${line##* }
    [ -n "$object_name" ] || continue
    local_path="${local_dir}/${object_name}"
    remote_object="${remote_uri}${object_name}"
    if [ -f "$local_path" ]; then
      if ! verify_local_file "$local_path" "$remote_object"; then
        failed=1
      fi
    else
      echo "错误：缺少本地文件：$local_path" >&2
      failed=1
    fi
  done < /tmp/pod-download-ls.txt
  rm -f /tmp/pod-download-ls.txt
  if [ "$failed" -ne 0 ]; then
    exit 1
  fi
  echo "目录下载完成：${local_dir}/"
fi

echo "下载完成。"
