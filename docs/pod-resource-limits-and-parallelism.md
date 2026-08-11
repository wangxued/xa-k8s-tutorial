# 容器资源上限与并行度设置

> **适用集群**：雄安院 K8s（API：`https://k8s-yw.hqzyai.com:6443`）  
> **日期**：2026-08-11（北京时间，UTC+8）

在 Pod 内执行 `nproc`、`free -h`、`top` 看到的是**整台物理节点**的规格（例如 192 核 / 1.5 TB），而容器实际能用的只有创建任务时申请的 CPU / 内存配额。按看到的节点规格去设置编译并行度、线程数或进程池大小，会瞬间把配额打满，表现为 Pod 连不上、命令无响应、任务无提示中断。

本文说明如何取到真实配额、常见工具的并行度写法，以及 Pod 卡住时的自查与恢复步骤。

---

## 1. 核心概念：看到的不等于能用的

```text
  容器内看到的（节点规格）              容器实际可用（申请的配额）
  ┌──────────────────────┐            ┌──────────────────────┐
  │ nproc      → 192     │            │ cpu.max    → 64 核    │
  │ free -h    → 1.5 TB  │   实际生效  │ memory.max → 256 GiB  │
  │ top        → 全节点   │  ────────> │ 超出即限流 / OOM       │
  └──────────────────────┘            └──────────────────────┘
```

| 在容器内执行 | 返回的是 | 能否作为并行度依据 |
|--------------|----------|--------------------|
| `nproc` | 节点物理核数 | 否 |
| `os.cpu_count()` / `multiprocessing.cpu_count()` | 节点物理核数 | 否 |
| `free -h` | 节点总内存 | 否 |
| `top` / `htop` | 节点全局视图 | 否 |
| `cat /sys/fs/cgroup/cpu.max` | **容器 CPU 配额** | 是 |
| `cat /sys/fs/cgroup/memory.max` | **容器内存上限** | 是 |

超出配额后的内核行为：

| 超出项 | 内核行为 | 用户侧观感 |
|--------|----------|------------|
| CPU | CFS 限流，所有进程按比例削减时间片 | 整个容器变慢；SSH / VS Code 连不上；`kubectl exec` 超时 |
| 内存 | OOM killer 杀掉容器内**某一个**进程 | 训练或编译无提示中断，日志无报错 |

**需要特别注意**：内存超限时被杀的通常是容器内的子进程，而不是容器主进程。因此 Pod 状态**仍然是 `Running`、`RESTARTS` 不变**，平台侧和 `kubectl describe pod` 都看不到任何异常事件。任务"莫名其妙就没了"多数属于这种情况。

---

## 2. 查询真实配额

进入容器后执行：

```bash
kubectl exec -it <POD> -n <NS> -- bash

# 容器内执行
echo "CPU 配额 : $(awk '{ if ($1=="max") print "无限制"; else printf "%d 核", $1/$2 }' /sys/fs/cgroup/cpu.max)"
echo "内存上限 : $(awk '{ printf "%.0f GiB", $1/1024/1024/1024 }' /sys/fs/cgroup/memory.max)"
echo "内存已用 : $(awk '{ printf "%.1f GiB", $1/1024/1024/1024 }' /sys/fs/cgroup/memory.current)"
```

在 Python 中按配额决定并行度：

```python
import os


def cpu_quota():
    """返回容器实际可用核数；无 cgroup 限制时回退到节点核数。"""
    try:
        quota, period = open("/sys/fs/cgroup/cpu.max").read().split()
    except OSError:
        return os.cpu_count()
    if quota == "max":
        return os.cpu_count()
    return max(1, int(quota) // int(period))


def mem_limit_gib():
    """返回容器内存上限（GiB）；读取失败时返回 None。"""
    try:
        return int(open("/sys/fs/cgroup/memory.max").read()) / 1024 ** 3
    except (OSError, ValueError):
        return None


print(cpu_quota(), mem_limit_gib())
```

在 64 核 / 256 GiB 的容器中实测输出为 `64 256.0`，而同一容器内 `os.cpu_count()` 返回 `192`。

若 `/sys/fs/cgroup/cpu.max` 不存在（cgroup v1 环境），改读 `/sys/fs/cgroup/cpu/cpu.cfs_quota_us` 与 `cpu.cfs_period_us`，两者相除即为核数。

---

## 3. 并行度设置对照表

### 3.1 编译类

编译是最容易打满配额的场景，且**内存**通常比 CPU 先触顶。

| 工具 | 默认并行度 | 建议写法 |
|------|------------|----------|
| `ninja` | 节点核数 + 2 | `ninja -j 8` |
| `make` | 裸 `-j` 表示**不限制** | `make -j8`，不要写裸 `-j` |
| `cmake --build` | 同 make | `cmake --build . -j 8` |
| Python 扩展源码安装（flash-attn、deepspeed、apex、xformers 等） | 读 `nproc` | `MAX_JOBS=8 pip install ...` |
| `pip install`（无预编译 wheel 时回落到源码编译） | 同上 | 同上；优先选预编译 wheel |
| `cargo build` | 节点核数 | `cargo build -j 8` |
| `go build` | 节点核数 | `GOMAXPROCS=8 go build` |

**并行度估算**：CUDA 源码编译时，单个编译器前端进程（`cicc`）峰值内存可达 5 GiB，一次 `nvcc` 调用还会按多个 GPU 架构派生出多个此类进程。建议取以下两者的较小值：

```text
并行度 = min( CPU 配额 ÷ 4 , 内存上限(GiB) ÷ 6 )
```

例如 64 核 / 256 GiB 的容器，建议并行度为 `min(16, 42) = 16`，保守起步可先用 8。

### 3.2 Python / 训练

| 场景 | 变量或参数 | 建议 |
|------|------------|------|
| BLAS / OpenMP 线程 | `OMP_NUM_THREADS`、`MKL_NUM_THREADS`、`OPENBLAS_NUM_THREADS`、`NUMEXPR_NUM_THREADS` | **必须显式设置**，见下方说明 |
| PyTorch CPU 线程 | `torch.set_num_threads(n)` | 与 `OMP_NUM_THREADS` 保持一致 |
| DataLoader | `num_workers` | 每卡 4～8，且 `num_workers × GPU 数 ≤ CPU 配额` |
| 单机多卡启动 | `torchrun --nproc_per_node` | 等于本 Pod 申请的 GPU 数 |
| 进程池 | `multiprocessing.Pool(processes=n)` | 显式传 `processes`，不使用默认值 |
| joblib / scikit-learn | `n_jobs` | 不使用 `-1` |
| pandas / pyarrow 多线程读写 | `use_threads`、线程数参数 | 显式设置 |
| pytest 并行 | `-n auto` | 改为 `-n 8` |

**关于 `OMP_NUM_THREADS`**：不设置时，每个进程都会按节点核数创建线程。8 卡训练即 8 个 rank × 192 线程 = 1536 线程争抢 64 核配额，CPU 限流会让训练比单线程还慢。建议在启动脚本开头固定：

```bash
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8
```

### 3.3 数据处理与 IO

| 场景 | 建议 |
|------|------|
| `ffmpeg` | 显式 `-threads N`，不使用默认 |
| 解压大量小文件到共享存储 | 串行执行，不要并发 |
| `rsync` / `mc mirror` 并发传输 | 控制并发数在 4～8 |
| 数据集预处理进程池 | 按 §2 取配额后计算，并预留内存余量 |

---

## 4. 目录选择：本地盘与共享存储

| 数据类型 | 建议落点 | 说明 |
|----------|----------|------|
| 编译中间产物、`pip install` 临时目录、conda 环境 | `local-path` scratch PVC（如 `/scratch`） | 本地 NVMe，小文件读写快 |
| 大量小文件的解压与生成 | 同上 | 共享存储上元数据操作代价高 |
| 数据集、模型权重、checkpoint、任务结果 | `h3c-csi-sc-nfs` / `h3c-csi-sc-epc` | 跨节点共享、可长期保存 |

在共享存储上执行编译或大量小文件操作，会同时拖慢自己的任务和同一存储上的其他任务。

**共享存储采用 `hard` 挂载**：存储侧繁忙时，读写进程会进入 `D`（不可中断睡眠）状态，此时 `kill -9` 也无法终止该进程，只能等待 IO 返回。判断方法：

```bash
ps -eo pid,stat,wchan:24,comm --no-headers | awk '$2 ~ /D/'
```

若 `wchan` 显示 `rpc_wait_bit_killable`，即为等待共享存储响应。

---

## 5. Pod 连不上或卡住时的自查

### 5.1 判断是否为配额打满

进入容器后执行以下自查命令：

```bash
echo "== CPU 配额 =="
awk '{ if ($1=="max") print "无限制"; else printf "%d 核\n", $1/$2 }' /sys/fs/cgroup/cpu.max

echo "== CPU 限流 =="
grep -E 'nr_periods|nr_throttled' /sys/fs/cgroup/cpu.stat

echo "== 内存 =="
awk '{ printf "已用 %.1f GiB\n", $1/1024/1024/1024 }' /sys/fs/cgroup/memory.current
awk '{ printf "上限 %.1f GiB\n", $1/1024/1024/1024 }' /sys/fs/cgroup/memory.max

echo "== OOM 记录 =="
cat /sys/fs/cgroup/memory.events

echo "== 内存回收停顿 =="
cat /sys/fs/cgroup/memory.pressure

echo "== CPU 占用前 10 =="
ps -eo pid,stat,pcpu,pmem,rss,etime,comm --sort=-pcpu --no-headers | head -10

echo "== 内存占用前 10 =="
ps -eo pid,stat,pmem,rss,comm --sort=-rss --no-headers | head -10
```

判读标准：

| 字段 | 位置 | 异常判据 |
|------|------|----------|
| `oom_kill` | `memory.events` | 大于 0 表示已有进程被内存不足杀掉 |
| `max` | `memory.events` | 数千次表示内存长期贴着上限运行 |
| `nr_throttled / nr_periods` | `cpu.stat` | 比值持续超过 10% 表示 CPU 配额不足 |
| `full avg300` | `memory.pressure` | 超过 20% 表示大部分时间在等内存回收 |

这些计数器自容器启动开始累计。用 `ps -o lstart= -p 1` 可查看容器启动时刻，据此判断是当前发生的问题还是历史记录。

### 5.2 exec 也进不去时

VS Code Remote 建立连接需要启动 Node 主进程、扩展宿主、文件索引和 Git 状态检查，开销远大于普通终端。容器资源紧张时，往往 VS Code 连不上但 `kubectl exec` 仍可用。

按开销从小到大依次尝试：

```bash
# 1. 最轻量
kubectl exec -n <NS> <POD> -- ps -eo pid,stat,pcpu,comm --sort=-pcpu --no-headers | head

# 2. 交互式 shell
kubectl exec -it -n <NS> <POD> -- bash

# 3. 以上均超时，说明容器已严重过载，请联系平台管理员
```

### 5.3 清理 VS Code 残留进程

反复重连会在容器内累积多个互不复用的 VS Code Server 实例，每个实例都带有独立的扩展宿主与文件索引进程，持续占用资源。清理方式：

```bash
kubectl exec -n <NS> <POD> -- bash -c \
  "pkill -TERM -f '[v]scode-server'; sleep 5; pkill -KILL -f '[v]scode-server'"
```

`[v]scode-server` 的写法用于避免 `pkill` 匹配到执行该命令的 shell 自身而提前退出，效果与 `vscode-server` 相同。清理后重新发起连接即可获得干净的实例。

### 5.4 停止失控的任务

先确认要终止的对象，再执行终止：

```bash
# 查看
ps -eo pid,ppid,stat,pcpu,rss,etime,args --no-headers | grep -E 'ninja|make|python' | grep -v grep

# 按进程名终止
pkill -TERM -f <进程名特征>

# 按 PID 终止
kill -TERM <PID>
```

编译或训练任务的父进程常已重定向到容器主进程，终止终端或 VS Code 不会连带停止它们，需要单独终止。

### 5.5 关于 `<defunct>` 僵尸进程

容器主进程通常为 `sleep infinity`，它不回收子进程，因此任何退出的孤儿进程都会留下 `<defunct>` 标记，数量可达数百个。

| 问题 | 结论 |
|------|------|
| 僵尸进程占 CPU 或内存吗？ | 不占，只占一个 PID 槽位 |
| 会导致 Pod 卡住吗？ | 不会，PID 上限为数十万，余量充足 |
| 能 kill 掉吗？ | 不能，只能通过重建 Pod 清除 |

**看到大量 `<defunct>` 不代表故障**，它是此前任务退出或被 OOM 杀掉后留下的记录。排查时应关注 §5.1 的 cgroup 指标，而不是僵尸进程数量。

---

## 6. 资源确实不够时的处理方式

| 方式 | 说明 |
|------|------|
| 原地扩容 CPU / 内存 | 不重启容器、不释放 GPU，见 [`pod-inplace-resize-guide.md`](pod-inplace-resize-guide.md) |
| 申请提高 namespace quota | 在华清云 SaaS 提交 |
| 拆分任务分批执行 | 降低单次并行度，延长执行时间换取稳定性 |

提高并行度**不能**突破配额。CPU 配额是硬上限，超出部分只会转化为限流等待；内存超出则直接触发进程被杀。

---

## 7. 常见问题

### 7.1 Pod 显示 `Running`，为什么进不去？

容器自身的 CPU 配额被占满时，新建的连接进程拿不到足够时间片而握手超时；内存贴顶时新进程可能在启动阶段被 OOM killer 杀掉。这两种情况下容器主进程都存活，因此 Pod 状态、`describe pod` 事件和平台监控都显示正常。按 §5.1 查容器 cgroup 指标即可确认。

### 7.2 训练跑到一半就没了，日志里没有任何报错

多为内存超限被 OOM killer 终止。检查：

```bash
cat /sys/fs/cgroup/memory.events
```

`oom_kill` 大于 0 即可确认。处理方式：调小 batch size、减少 DataLoader `num_workers`、或按 §6 扩容内存。

### 7.3 `nvidia-smi` 显示 GPU 利用率很低，但 GPU 已被占用

常见于 CPU 侧成为瓶颈：DataLoader worker 数量不足导致数据供不上，或线程数设置过大导致 CPU 限流。先按 §5.1 查 `nr_throttled`，再按 §3.2 调整。

### 7.4 某个进程 `kill -9` 也杀不掉

进程处于 `D` 状态，正在等待共享存储 IO 返回。共享存储为 `hard` 挂载，此状态下不响应任何信号，只能等待 IO 完成。参见 §4。

### 7.5 已经原地扩大了 CPU，为什么速度没变化

原地扩容只放大 cgroup 上限，应用侧的并行度参数需要同步调整才会用上新增的核数。参见 §3。

### 7.6 `kubectl exec -- python3` 报 `executable file not found`

Conda 等环境的 PATH 通常写在 `~/.bashrc` 中，而 `kubectl exec -- <命令>` 不加载该文件。改为加载登录环境执行：

```bash
kubectl exec -n <NS> <POD> -- bash -lc 'python3 your_script.py'
```

或直接使用解释器绝对路径，例如 `/root/miniconda3/bin/python3`。交互式 `kubectl exec -it ... -- bash` 不受影响。

---

## 8. 相关文档

- [`pod-inplace-resize-guide.md`](pod-inplace-resize-guide.md) — 运行中 Pod 原地扩缩 CPU / 内存
- [`gpu-workload-scenarios.md`](gpu-workload-scenarios.md) — 单机 Deployment 与多机 Job 选型
- [`multinode-gpu-training.md`](multinode-gpu-training.md) — 多机多卡训练
- [`h20-node-usage.md`](h20-node-usage.md) — H20 节点规格与存储限制
- [`../charts/xay-ai/README.md`](../charts/xay-ai/README.md) — Helm 部署与 resources 参数
