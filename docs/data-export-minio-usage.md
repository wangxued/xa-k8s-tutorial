> **适用集群**：雄安院 K8s（`yw-k8s`）  
> **日期**：2026-06-29

# 数据导出 MinIO 使用说明

新集群提供 **data-export MinIO** 作为临时数据中转，支持双向传输：

| 方向 | 典型场景 |
|------|----------|
| **Pod 上传 → 办公网下载** | 训练/推理结果导出到本机 |
| **办公网上传 → Pod 下载** | 数据集、权重、配置从本机送入集群 |

数据默认 **14 天** 自动清理，不用于长期归档。

## 入口信息

| 项 | 值 |
|---|---|
| 集群内 S3（Pod 上传/下载） | `http://data-minio-hl.data-export-minio.svc.cluster.local:9000` |
| 公网 S3（本机上传/下载） | `https://minio-data.xa.hqzyai.com:9443` |
| Bucket | `export` |
| 路径规范 | `<用户名>/<任务名>/`（避免与其他用户混放） |

账号由管理员单独发放（**`data-export-user`**，仅 S3 读写）：

```bash
export AWS_ACCESS_KEY_ID='...'
export AWS_SECRET_ACCESS_KEY='...'
```

5090 / H200 用户 Pod 均可经**集群内地址**访问；MinIO 服务运行在 H200 节点，与业务 Pod 所在节点无关。

> **Console 说明**：Web 控制台 `https://minio-data-console.xa.hqzyai.com:9443` 仅供运维，请用管理员账号 `dataExportAdmin` 登录。`data-export-user` 在 Console 中权限不足（如 `/quota` 403、Object Browser 异常）。**日常上传/下载请用 `mc` 或本仓库脚本，不要用 Console。**

## 辅助脚本

本仓库 [`scripts/minio/`](../scripts/minio/) 提供四个脚本，与 [`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html) 命令等价，并带重试/校验：

| 脚本 | 运行位置 | 方向 |
|------|----------|------|
| [`pod-upload-to-minio.sh`](../scripts/minio/pod-upload-to-minio.sh) | Pod 内 | 集群内上传 |
| [`pod-download-from-minio.sh`](../scripts/minio/pod-download-from-minio.sh) | Pod 内 | 集群内下载 + 大小校验 |
| [`local-download-from-minio.sh`](../scripts/minio/local-download-from-minio.sh) | 办公网本机 | 公网下载 |
| [`local-upload-to-minio.sh`](../scripts/minio/local-upload-to-minio.sh) | 办公网本机 | 公网上传 |

使用前设置 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`（见上文）。

---

## 1. Pod 上传 → 办公网下载（导出结果）

### 1.1 Pod 内上传

Pod 内需要 `mc`（MinIO Client）。未安装时可使用 [`examples/raw-yaml/minio-client-pod.yaml`](../examples/raw-yaml/minio-client-pod.yaml) 临时 Pod（镜像已内置 `mc`）。

**方式 A：脚本（推荐）**

```bash
export AWS_ACCESS_KEY_ID='<管理员发放>'
export AWS_SECRET_ACCESS_KEY='<管理员发放>'
sh scripts/minio/pod-upload-to-minio.sh /path/to/data <用户名>/<任务名>
```

**方式 B：手动 mc**

```bash
export MINIO_ENDPOINT='http://data-minio-hl.data-export-minio.svc.cluster.local:9000'
export NO_PROXY='localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,10.96.0.0/12,10.63.252.0/24,10.60.0.0/24'

mc alias set data-minio "$MINIO_ENDPOINT" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
mc cp --recursive /path/to/data data-minio/export/<用户名>/<任务名>/
```

集群内为 **HTTP**；公网经 Envoy Gateway **HTTPS :9443** 暴露。

### 1.2 本机下载

本机安装 `mc` 后：

```bash
# macOS Apple Silicon 示例
curl -fsSL https://dl.min.io/client/mc/release/darwin-arm64/mc -o mc
chmod +x mc

export AWS_ACCESS_KEY_ID='<管理员发放>'
export AWS_SECRET_ACCESS_KEY='<管理员发放>'

bash scripts/minio/local-download-from-minio.sh <用户名>/<任务名> ./downloads
```

目录下载使用 `mc mirror --retry`：已完整落盘且大小一致的文件会跳过，失败项自动重试。

**断点续传说明**：单个大文件不支持字节级续传；中断后需重新下载该文件。目录批量下载时，`mirror --retry` 可跳过已完成的文件。

---

## 2. 办公网上传 → Pod 下载（导入数据）

### 2.1 本机上传

```bash
export AWS_ACCESS_KEY_ID='<管理员发放>'
export AWS_SECRET_ACCESS_KEY='<管理员发放>'

bash scripts/minio/local-upload-to-minio.sh ./dataset <用户名>/<任务名>-input
```

单文件或整个目录均可；目录上传使用 `mc mirror --retry`。

### 2.2 Pod 内下载

**方式 A：脚本（推荐）**

示例 Pod 镜像为极简环境，推荐通过 stdin 注入脚本：

```bash
kubectl apply -f examples/raw-yaml/minio-client-pod.yaml -n <your-namespace>
kubectl wait --for=condition=Ready pod/minio-client -n <your-namespace> --timeout=120s

export AWS_ACCESS_KEY_ID='<管理员发放>'
export AWS_SECRET_ACCESS_KEY='<管理员发放>'

cat scripts/minio/pod-download-from-minio.sh | kubectl exec -i -n <your-namespace> minio-client -- \
  env AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  sh -s -- <用户名>/<任务名>-input /workspace/input
```

**方式 B：在 Pod 内手动 mc**

```bash
kubectl exec -it minio-client -n <your-namespace> -- sh

export AWS_ACCESS_KEY_ID='...'
export AWS_SECRET_ACCESS_KEY='...'
export NO_PROXY='localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,10.96.0.0/12,10.63.252.0/24,10.60.0.0/24'

mc alias set data-minio http://data-minio-hl.data-export-minio.svc.cluster.local:9000 \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
mc mirror --retry data-minio/export/<用户名>/<任务名>-input/ /workspace/input/
```

下载完成后可在 Pod 内直接使用 `/workspace/input` 下的文件。

---

## 3. 检查与清理

```bash
mc ls --recursive data-minio/export/<用户名>/<任务名>/
mc rm --recursive --force data-minio/export/<用户名>/<任务名>/
```

## 4. 与其他存储的分工

| 场景 | 推荐方式 |
|------|----------|
| 编译缓存、短期 scratch | `local-path` scratch PVC |
| 5090 共享训练数据 | `h3c-csi-sc-nfs` |
| H200 共享权重 / checkpoint | `h3c-csi-sc-nfs` 或 `h3c-csi-sc-epc` |
| **集群 ↔ 办公网临时中转** | **data-export MinIO**（本文） |

MinIO 中转面向「集群 ↔ 办公网」临时数据交换；集群内长期数据仍应使用个人 NFS/EPC PVC。详见 [GPU 工作负载场景选型](gpu-workload-scenarios.md)。

## 注意事项

- 仅用于临时中转，文件 14 天后自动过期。
- Pod 内访问集群内 S3 时，`NO_PROXY` 须包含 `.svc.cluster.local`。
- 公网地址端口为 **9443**（Envoy Gateway），格式：`https://<子域名>.xa.hqzyai.com:9443/`。
- 集群内 S3 为 **HTTP**；勿对集群内地址使用 HTTPS URL。
- 示例 `minio-client` Pod 镜像不含 `kubectl cp` 所需的 `tar`；向 Pod 传脚本请用上文 stdin 方式，或在业务镜像中预装 `mc`。
