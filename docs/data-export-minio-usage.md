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

**`mc cp` 与 `mc mirror` 区别**（详见 [`docs/mc-command-cheatsheet.md`](../docs/mc-command-cheatsheet.md)）：

| 命令 | 文件 | 目录 |
|------|------|------|
| `mc cp` | ✅ 直接支持 | ✅ 须加 `--recursive` |
| `mc mirror --retry` | ❌ 不支持 | ✅ 目录同步（推荐批量） |

---

## mc 命令速查

以下 `<别名>` / `<endpoint>` 在 **新环境 Pod 内** 用集群内 HTTP，在 **办公网本机** 用公网 HTTPS（见 [入口信息](#入口信息)）。配置 alias 后：

```bash
# Pod 内
mc alias set data-minio http://data-minio-hl.data-export-minio.svc.cluster.local:9000 \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"

# 办公网本机
mc alias set data-minio https://minio-data.xa.hqzyai.com:9443 \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
```

### 上传

| 对象 | 命令 |
|------|------|
| **单个文件** | `mc cp /path/to/file.bin data-minio/export/<用户名>/<任务名>/file.bin` |
| **整个目录** | `mc cp --recursive /path/to/dir/ data-minio/export/<用户名>/<任务名>/` |
| **整个目录（推荐批量）** | `mc mirror --retry /path/to/dir/ data-minio/export/<用户名>/<任务名>/` |

### 下载

| 对象 | 命令 |
|------|------|
| **单个文件** | `mc cp data-minio/export/<用户名>/<任务名>/file.bin ./downloads/file.bin` |
| **整个目录** | `mc cp --recursive data-minio/export/<用户名>/<任务名>/ ./downloads/` |
| **整个目录（推荐批量）** | `mc mirror --retry data-minio/export/<用户名>/<任务名>/ ./downloads/` |

完整说明见 [`docs/mc-minio-cheatsheet.md`](mc-minio-cheatsheet.md)。

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

单文件：

```bash
mc cp /path/to/result.tar.gz data-minio/export/<用户名>/<任务名>/result.tar.gz
```

整个目录（任选其一）：

```bash
mc cp --recursive /path/to/data/ data-minio/export/<用户名>/<任务名>/
mc mirror --retry /path/to/data/ data-minio/export/<用户名>/<任务名>/
```

新集群内为 **HTTP**；公网经 Envoy Gateway **HTTPS :9443** 暴露。

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

手动 mc 示例：

```bash
# 单文件
mc cp data-minio/export/<用户名>/<任务名>/result.tar.gz ./downloads/result.tar.gz
# 整个目录（推荐 mirror）
mc mirror --retry data-minio/export/<用户名>/<任务名>/ ./downloads/
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

手动 mc 示例：

```bash
# 单文件
mc cp ./weights.bin data-minio/export/<用户名>/<任务名>-input/weights.bin
# 整个目录
mc mirror --retry ./dataset/ data-minio/export/<用户名>/<任务名>-input/
```

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

# 单文件
mc cp data-minio/export/<用户名>/<任务名>-input/weights.bin /workspace/input/weights.bin
# 整个目录
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

## 5. 联泰 GPFS 历史数据迁入云网（已验证示例）

适用于联泰集群个人 GPFS（如: `pvc-gpfshome-<用户>`）中的数据，经公网上传至云网 MinIO，再在云网 Pod 或办公网本机下载。

| 项 | 值 |
|---|---|
| 示例 namespace | `changcan22` |
| 示例 PVC | `pvc-gpfshome-changcan22` |
| Pod 挂载路径 | `/gpfshome`（只读） |
| 云网 MinIO 公网 | `https://minio-data.xa.hqzyai.com:9443` |
| 建议远端前缀 | `export/changcan22/<任务名>/` |

**示例 YAML**（2026-06 已验证）：

| 文件 | 说明 |
|------|------|
| [`examples/raw-yaml/liantai-yunwang-minio-secret.example.yaml`](../examples/raw-yaml/liantai-yunwang-minio-secret.example.yaml) | 云网 MinIO 凭据 Secret 模板 |
| [`examples/raw-yaml/liantai-changcan22-gpfshome-export-pod.yaml`](../examples/raw-yaml/liantai-changcan22-gpfshome-export-pod.yaml) | 挂载 GPFS PVC 的导出 Pod |

部署顺序：先 Secret → 再 Pod → `kubectl exec` 进入浏览数据 → 确认路径后 `mc cp` / `mc mirror` 上传。

### 5.1 Secret 模板：部署前须改字段

文件：[`liantai-yunwang-minio-secret.example.yaml`](../examples/raw-yaml/liantai-yunwang-minio-secret.example.yaml)

| YAML 路径 | 示例值 | 是否必改 | 说明 |
|-----------|--------|----------|------|
| `metadata.namespace` | `changcan22` | **是** | 须与个人 GPFS PVC 所在 namespace 一致 |
| `metadata.name` | `yunwang-data-export-minio` | 否 | 与 Pod `envFrom.secretRef.name` 对应；一般保持默认 |
| `stringData.AWS_ACCESS_KEY_ID` | 占位符 | **是** | 管理员发放的云网 **`data-export-user`** Access Key |
| `stringData.AWS_SECRET_ACCESS_KEY` | 占位符 | **是** | 管理员发放的云网 **`data-export-user`** Secret Key |

### 5.2 导出 Pod：部署前须改字段

文件：[`liantai-changcan22-gpfshome-export-pod.yaml`](../examples/raw-yaml/liantai-changcan22-gpfshome-export-pod.yaml)

| YAML 路径 | 示例值 | 是否必改 | 说明 |
|-----------|--------|----------|------|
| `metadata.namespace` | `changcan22` | **是** | 须与 Secret、GPFS PVC 同一 namespace |
| `metadata.name` | `gpfshome-export-changcan22` | **建议** | 同一 namespace 内 Pod 名唯一；可按用户重命名 |
| `metadata.labels.user` | `changcan22` | **建议** | 便于识别归属，与 namespace 或用户名对齐 |
| `spec.nodeSelector.kubernetes.io/hostname` | `mg3232` | **否** | 示例已固定为 GPFS 可达节点；**请勿自行修改** |
| `spec.volumes[].persistentVolumeClaim.claimName` | `pvc-gpfshome-changcan22` | **是** | 改为该用户实际的 GPFS PVC 名称（如: `pvc-gpfshome-<用户>`） |
| `containers[].envFrom.secretRef.name` | `yunwang-data-export-minio` | 否 | 须与 §5.1 Secret 的 `metadata.name` 一致 |
| `containers[].env`（`name: MINIO_REMOTE_PREFIX`） | `changcan22` | **是** | MinIO 对象前缀，对应 `export/<前缀>/<任务名>/` |
| `containers[].env`（`name: MINIO_ENDPOINT`） | `https://minio-data.xa.hqzyai.com:9443` | 否 | 云网公网 S3 入口，固定 |
| `containers[].env`（`name: MINIO_BUCKET`） | `export` | 否 | 中转 bucket，固定 |
| `containers[].volumeMounts[].mountPath` | `/gpfshome` | 否 | Pod 内浏览与上传的本地路径，固定 |
| `containers[].image` | `harbor.xa.xshixun.com:7443/.../mc:...` | 否 | 已验证 `mc` 镜像，固定 |

### 5.3 部署、容器内上传

部署方式:

通过 `kubectl` 命令向新集群内部署

```bash
kubectl apply -f examples/raw-yaml/liantai-yunwang-minio-secret.yaml
kubectl apply -f examples/raw-yaml/liantai-yourname-gpfshome-export-pod.yaml
```

Pod 内上传示例：

```bash
kubectl exec -it <your-pod-name> -n <your-namespace> -- sh

mc alias set yunwang "$MINIO_ENDPOINT" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
mc mirror --retry /gpfshome/cc/ yunwang/export/changcan22/<任务名>/
```

**网络说明**：联泰 Pod 须**直连** `minio-data.xa.hqzyai.com:9443`；设置 `HTTP_PROXY` 会导致上传失败。

上传完成后，可在云网集群 Pod 内用 §2.2 方式下载，或在办公网执行：

```bash
bash scripts/minio/local-download-from-minio.sh changcan22/<任务名> ./downloads
```

## 注意事项

- 仅用于临时中转，文件 14 天后自动过期。
- Pod 内访问集群内 S3 时，`NO_PROXY` 须包含 `.svc.cluster.local`。
- 公网地址端口为 **9443**（Envoy Gateway），格式：`https://<子域名>.xa.hqzyai.com:9443/`。
- 集群内 S3 为 **HTTP**；勿对集群内地址使用 HTTPS URL。
- 示例 `minio-client` Pod 镜像不含 `kubectl cp` 所需的 `tar`；向 Pod 传脚本请用上文 stdin 方式，或在业务镜像中预装 `mc`。
