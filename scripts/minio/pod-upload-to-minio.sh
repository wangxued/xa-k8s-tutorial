#!/usr/bin/env sh
set -eu

DEFAULT_MINIO_ENDPOINT="http://data-minio-hl.data-export-minio.svc.cluster.local:9000"
DEFAULT_MINIO_BUCKET="export"
DEFAULT_NO_PROXY="localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,10.96.0.0/12,10.63.252.0/24,10.60.0.0/24"

usage() {
  cat <<'EOF'
用法：
  sh pod-upload-to-minio.sh <本地文件或目录> [远端前缀]

示例：
  export AWS_ACCESS_KEY_ID='管理员发放的 access key'
  export AWS_SECRET_ACCESS_KEY='管理员发放的 secret key'
  sh pod-upload-to-minio.sh /workspace/result zhangsan/job-001

可选环境变量：
  MINIO_ENDPOINT   默认集群内上传地址
  MINIO_BUCKET     默认 export
  NO_PROXY         默认包含 .svc.cluster.local
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

require_command mc
require_env "${AWS_ACCESS_KEY_ID:-}" "AWS_ACCESS_KEY_ID"
require_env "${AWS_SECRET_ACCESS_KEY:-}" "AWS_SECRET_ACCESS_KEY"

if [ ! -e "$local_path" ]; then
  echo "错误：本地路径不存在：$local_path" >&2
  exit 1
fi

export NO_PROXY="${NO_PROXY:-$DEFAULT_NO_PROXY}"
export no_proxy="${no_proxy:-$NO_PROXY}"

echo "上传来源：$local_path"
echo "上传目标：s3://${minio_bucket}/${remote_prefix}"

mc alias set data-minio "$minio_endpoint" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
mc cp --recursive "$local_path" "data-minio/${minio_bucket}/${remote_prefix}"

echo "上传完成。"
