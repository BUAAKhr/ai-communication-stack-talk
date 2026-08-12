# AI Communication Stack: From Workload to Dataflow

> 公开审校稿 v0.6，资料核对日期：2026-08-12。
>
> 建议时长：128–132 分钟；主讲 72 页，另附备份页、demo 与制图建议。本文先按逐页脚本写，便于下一步直接改成 PPT。
>
> 证据标签：`[A]` 官方规范、官方文档或正式论文；`[B]` 官方开源仓库/项目文档；`[C]` 厂商公开演讲、产品预告或尚未充分披露的 2026 新项目。`[C]` 内容适合讲趋势，不宜讲成稳定产品事实。涉及产品微架构时再区分“官方产品事实 / 学术研究方案 / 基于公开材料的推断”，不能用论文方案反推量产芯片实现。

## 课程主张

通信不是一根“更快的线”，而是一条端到端 dataflow。演讲按四个问题推进，而不是按厂商或设备罗列：

```text
model parallelism / serving policy
        ↓ 产生 collective、P2P、all-to-all、KV movement
communication library / distributed kernel
        ↓ 选择算法、分块、调度、buffer 与发起端
transport / topology / congestion control
        ↓ 映射为 packet、path、queue、credit
link / switch / NIC / memory hierarchy
```

课程始终回答四个问题：

1. 数据在哪里产生、在哪里被消费？
2. 数据必须经过哪些物理边界？
3. 谁发起、谁搬运、谁执行 reduce？
4. 慢来自带宽、时延、拥塞、抖动、负载不均，还是额外内存副本？

```text
0. Why data moves
1. Where data moves
2. What the fabric guarantees
3. Who moves the data
4. How we shorten the critical path
```

## 总时间建议

| 章节 | Slides | 时间 |
|---|---:|---:|
| 开场：Why data moves | 1–4 | 6 min |
| 1. Where data moves | 5–21 | 32 min |
| 2. What the fabric guarantees | 22–33 | 24 min |
| 3. Who moves the data | 34–49 | 32 min |
| 4. How we shorten the critical path | 50–71 | 34 min |
| 总结 | 72 | 2 min |
| **总计** | **72** | **130 min** |

---

# 开场：从“链路”切换到“数据流”（0–6 min）
## Slide 1｜标题

屏幕正文：

```text
AI Communication Stack
From Workload to Dataflow

Topology · Transport · Collective · P2P · EP · Distributed Kernel · KV Movement
```

讲师说明：这不是网络设备目录，也不是 NCCL API 教程。目标是建立一个从模型通信 pattern，一直追到 link、switch、NIC、memory 与 kernel schedule 的统一分析框架。

建议图示：一张纵向 stack 图，底部是 PCIe/NVLink/IB/Ethernet，上部是 DP/TP/PP/EP/PD。

## Slide 2｜通信为何正在决定 AI 系统上限

屏幕正文：

```text
Compute scaling: more FLOP/s
Memory scaling: more bytes/s, more capacity
Communication scaling: more endpoints, more paths, more variance

The bottleneck is increasingly coordination, not arithmetic.
```

讲师说明：单卡 kernel 优化处理的是一个内存层级；分布式系统多了拓扑、远端状态、拥塞、失败和不同步完成时间。通信优化因此不是“把 NCCL 换成更快版本”，而是重画 dataflow。

## Slide 3｜五类通信 pattern

| Pattern | 典型来源 | 关键指标 |
|---|---|---|
| AllReduce / ReduceScatter + AllGather | DP、TP | collective latency、bus BW |
| AllGather / ReduceScatter | TP、sequence parallel | 分块与 GEMM overlap |
| P2P / Send-Recv | PP、PD 分离、权重同步 | tail latency、零拷贝、流控 |
| All-to-All / Dispatch-Combine | EP / MoE | incast、负载偏斜、布局转换 |
| KV / state movement | prefix cache、PD、agentic serving | capacity、复用率、存储带宽 |

讲师说明：同一条网络面对的不是一种流量。大块 bulk-synchronous collective、小消息 latency-sensitive EP、持续 KV movement 对 transport 和 buffer 的要求完全不同。

## Slide 4｜一个性能公式不够

屏幕正文：

```text
T_comm ≈ startup + bytes / effective_bandwidth + contention + imbalance + jitter

T_step ≠ T_compute + T_comm
T_step = critical path after overlap and synchronization
```

讲师说明：平均带宽不能解释尾延迟；单次峰值不能解释大规模同步；通信和计算相加也不能表达 overlap。整场课会不断回到 critical path。

---

---
# 1. Where Data Moves: Physical Architecture & Topology (6-38 min)

## 1.1 Inside AI Servers: Package, Node and NUMA

## Slide 5｜先画一台 AI server 的真实数据路径

屏幕正文：

```text
CPU memory ─ CPU ─ PCIe root complex / switch ─ GPU
                                      ├──────── NIC / DPU
GPU ───────────── NVLink / xGMI / HCCS ─────── GPU
                         │
                    NVSwitch / fabric switch
```

讲师说明：PCIe、GPU scale-up fabric 与 NIC 不是互相替代，而是并存。问“GPU 之间是否有 NVLink”还不够，还要问 GPU→NIC 是否绕 CPU、NIC 与 GPU 是否共享 PCIe switch、NUMA 属于哪颗 CPU。

建议图示：`nvidia-smi topo -m` 风格矩阵 + 物理框图并排。

## Slide 6｜PCIe：通用 I/O 骨架，不等于 GPU fabric

屏幕正文：

| PCIe 角色 | 优点 | 约束 |
|---|---|---|
| CPU–GPU / CPU–NIC / GPU–NIC 连接 | 标准化、生态广、可挂多类设备 | root complex、switch oversubscription、NUMA |
| GPUDirect RDMA 路径 | NIC 可 DMA GPU memory | 仍受 PCIe 拓扑、IOMMU、ACS 等影响 |
| P2P fallback | 没有专用 scale-up fabric 时可用 | 带宽与时延通常弱于专用 GPU fabric |

讲师说明：PCIe 的价值是可组合性。性能分析先确认 traffic 是否真的走 peer path，而不是把标称 x16 带宽当作端到端带宽。

## Slide 7｜NVLink + NVSwitch：GPU Memory-Access and Collective Fabric

屏幕正文：

```text
NVLink: high-bandwidth endpoint link
NVSwitch: switched GPU fabric
NVLink domain: GPUs sharing GPU memory-access and collective paths
```

讲师说明：专用 scale-up fabric 的核心不是只把带宽做高，而是提供更紧的 GPU memory-access、同步与 collective data path。这里用 `memory-access fabric`，不把它简化成具有任意 CPU 式一致性语义的通用 load/store 总线。NVSwitch 让拓扑从若干直连边变成交换域；不同代际、HGX/DGX/NVL rack 的规模与能力不可混用。

建议图示：8-GPU HGX 全互联逻辑图，与 rack-scale NVL fabric 对比。[A1][A2]

## Slide 8｜CPU–GPU coherence 是另一条演进线

屏幕正文：

```text
Discrete accelerator model:
  CPU memory ↔ explicit transfer ↔ GPU memory

Coherent superchip model:
  tighter CPU–GPU address/data sharing
```

讲师说明：Grace Hopper / Grace Blackwell 这类 coherent CPU–GPU link 改善的是主机内存访问与编程模型，不应与 GPU–GPU NVLink fabric 混成一件事。课程只强调边界变化，不展开 cache coherence 协议。

## Slide 9｜AMD：Infinity Fabric / xGMI 的同构目标

屏幕正文：

```text
GPU-to-GPU scale-up domain
  + CPU/GPU platform integration
  + PCIe NIC attachment
```

讲师说明：AMD 平台也要回答同样的问题：GPU 间高带宽域有多大、NIC 挂载在哪里、跨 NUMA 与跨节点如何退化。不要用 NVIDIA 名词套 AMD 实现；讲共同设计目标即可。[A3]

## Slide 10｜Ascend 910B/910C：公开材料能讲到哪一层

屏幕正文：

```text
device / board / server scale: HCCS-class accelerator interconnect
cluster scale: RoCE / HCCN and HCCL software
newer SuperPoD direction: UnifiedBus / Lingqu
```

讲师说明：910B/910C 的具体板级拓扑依服务器型号而变。公开材料适合讲 HCCS/HCCN/HCCL 的层级关系，不宜把某一整机厂拓扑画成芯片的唯一拓扑。

来源边界：华为对 2025–2026 SuperPoD/UnifiedBus 有公开发布，但 910C 的很多微架构拓扑图来自第三方拆解，需单独标 `[C]`。[A4]

## Slide 11｜CloudMatrix 384 不是“单节点 384 卡”

屏幕正文：

```text
Conventional server boundary  → rack / multi-rack scale-up domain
```

讲师说明：建议把 CloudMatrix384 作为“服务器边界正在被 scale-up fabric 打破”的案例，而不是塞进单机 CPU/GPU topo。华为官方表述是：Atlas 900 A3 SuperPoD 最多包含 384 个 Ascend 910C，CloudMatrix384 是华为云构建在 Atlas 900 A3 SuperPoD 之上的云服务实例。这个口径不等同于“单服务器 384 卡”；具体交换层数与板级细节若采用第三方图，仍须注明来源和日期。[A4]

## Slide 12｜Topology reading checklist

屏幕正文：

```text
1. What is the smallest high-bandwidth domain?
2. Is every pair symmetric?
3. Where are NICs attached?
4. Is there oversubscription?
5. What happens after leaving the domain?
```

讲师说明：一张 topo 图的作用不是好看，而是预测 algorithm：ring 的顺序、hierarchical collective 的分组、EP replica 应放在哪里、PD transfer 应选择哪张 NIC。

## Slide 13｜本节结论：节点内已有三层网络

```text
memory fabric / coherent link
GPU scale-up fabric
general I/O fabric
```

讲师说明：后面所有 software routing 都是在这三层与节点间网络之间做映射。

## Slide 14｜Blackwell 双 Die：边界先在 package 内消失

屏幕正文：

```text
compute die 0 ── 10 TB/s chip-to-chip interconnect ── compute die 1
                         ↓
                 unified single GPU
```

讲师说明：NVIDIA 官方对 Blackwell 的原文是：两个 reticle-limited GPU dies 由 10 TB/s chip-to-chip interconnect 连接成一个 “single, unified GPU”。因此对 CUDA 程序员，它呈现为一个 GPU，而不是必须手工切分的两个 device。但这里的 10 TB/s 应按官方 “chip-to-chip link” 口径原样引用；官方公开材料没有给出足以把它拆成单向/双向、payload/aggregate 的细节。更重要的是，地址空间和 device 身份统一，不自动推出所有物理访问具有完全相同的时延、带宽或争用。[A23]

建议图示：只画两个 compute die、相邻的 HBM 资源和中间 NV-HBI/芯片间链路；在逻辑层外框写 “one CUDA GPU”，在物理层标 “local / cross-die path may differ”。不要把 HBM stack 或 L2 slice 与某个 die 的精确归属画成官方事实，也不要虚构内部一致性目录或具体 L2 分区。

---
## 1.2 From Node to Cluster: NIC, Switch and Topology

## Slide 15｜先区分 NIC、DPU 与加速器互联端点

| 类型 | 数据面能力 | 典型角色 / 案例 |
|---|---|---|
| High-performance NIC / fabric adapter | OS bypass、DMA、transport | ConnectX；AWS EFA |
| SmartNIC / DPU | NIC data path + programmable cores/offload | BlueField 等 |
| Scale-up fabric endpoint（不是 NIC） | accelerator memory access、同步或 collective path | NVLink、NeuronLink、TPU ICI 端点 |

讲师说明：不要因为某个 runtime 同时使用两类链路，就把它们归为同一种设备。判断数据路径时看五件事：谁 post work、谁推进 progress、是否能直接访问 accelerator memory、是否执行 collective/transport offload，以及它属于节点内 scale-up 还是节点间 fabric。

## Slide 16｜NVIDIA：ConnectX/BlueField + Spectrum

屏幕正文：

```text
ConnectX: high-performance NIC/RNIC
BlueField: DPU = NIC data path + programmable infrastructure processor
Spectrum-X: Ethernet switch + NIC/DPU + software stack
```

讲师说明：BlueField 不是 Spectrum switch，DOCA 也不是 collective library 的同义词。DOCA 是面向 DPU/网络与基础设施加速的 SDK；NCCL/SHARP 处于不同抽象层。[A5][A6]

## Slide 17｜AWS EFA + Trainium：节点内外是两层互联

屏幕正文：

```text
inside Trainium system: NeuronLink / accelerator fabric
between instances: EFA + SRD/libfabric path
software: Neuron collectives map traffic onto both layers
```

讲师说明：EFA 不等于“云版 InfiniBand”，也不等于 NeuronLink。EFA 是 AWS 为 EC2 HPC/ML 提供的网络接口，应用可经 libfabric、MPI、NCCL plugin 或 Neuron runtime 使用；SRD 是其可扩展可靠数据报 transport。Trainium 系统内部另有 NeuronLink/accelerator fabric。软件可以统一调度两层路径，但硬件与可靠性边界仍应分别画。[A7][A8]

## Slide 18｜Fabric topology：Fat Tree / Clos

屏幕正文：

```text
leaf ↔ spine ↔ leaf
```

讲师说明：Clos/Fat Tree 的价值是提供大量等价路径和可扩展 bisection bandwidth。成本来自交换芯片、光模块、布线与更复杂的拥塞控制。所谓“无阻塞”取决于端口配置和 oversubscription，不是拓扑名字自动保证。

## Slide 19｜Rail-optimized topology

屏幕正文：

```text
GPU0/NIC0 across nodes → rail 0
GPU1/NIC1 across nodes → rail 1
...
```

讲师说明：rail optimization 用稳定的 local GPU–NIC affinity 换取更少的跨节点第一跳/最后一跳争用，适合规则 collective。代价是 placement、rank mapping 与故障恢复更受拓扑约束。[A11]

## Slide 20｜Google 3D Torus：不要只记形状

屏幕正文：

```text
Torus strengths: regularity, locality, incremental wiring
Torus cost: path diversity / bisection depend on partition shape
```

讲师说明：Google TPU pod 的 ICI 拓扑随代际演进，并非所有 TPU 都固定 3D torus。讲 3D torus 时把它作为“拓扑感知 partition + collective”案例，不要说成 Google 当前所有 AI 网络的统一形态。[A12]

---
## 1.3 Scale-Up vs. Scale-Out: Physical and Failure Boundaries

## Slide 21｜Scale-up 与 scale-out 是两套可靠性预算

| | 短距 scale-up / local fabric | 长距 scale-out / routed fabric |
|---|---|---|
| 常见范围 | package、server、rack、supernode | 多 rack、data center、跨园区 |
| 拓扑与 RTT | 较固定、较短、常为一层交换 | 多跳、多路径、RTT 与抖动更大 |
| 语义倾向 | transaction、load/store、atomic、fence | message、RDMA、packet transport |
| 常用保护 | FEC、link replay、credit/lossless flow control | multipath、端到端 ACK/retry、congestion control |
| 主要代价 | XPU die area、短距 replay/queue buffer | per-flow state、timer、reorder、长 BDP buffer |

讲师说明：边界并不由“是否使用 Ethernet”自动决定。工程上常把问题重写为 local/in-rack 与 inter-rack：前者可以用简单、低状态的链路级保护，后者必须容忍更多路径、故障与排队。UALink、SUE、UET/RDMA 的差异，本质上是可靠性状态放在哪里、覆盖多大故障域。[A13][A32][A33][A34]

---
# 2. What the Fabric Guarantees: Semantics, Transport and Reliability (38-62 min)

## 2.1 Memory Semantics vs. RDMA Message Semantics

## Slide 22｜Memory semantic 与 RDMA message semantic：比较完整路径

| 维度 | Memory / transaction semantic | RDMA message / verbs semantic |
|---|---|---|
| 发起 | load/store/atomic/fence 或专用 copy engine | WQE、doorbell、SEND/WRITE/READ/atomic |
| 放置 | 地址直接选择目标位置 | 注册 buffer、RKey/QP/receive queue 等状态 |
| 完成 | response、counter、fence、signal | ACK、CQE、immediate、event |
| 优势 | 细粒度、容易嵌入 kernel dataflow | bulk transfer、隔离、成熟 verbs 生态 |
| 隐性成本 | outstanding transaction、ordering、remote latency | WQE/CQ progress、queue state、completion polling |

讲师说明：不能简单说 memory semantic 总是更快。GPU 上构造 WQE、敲 doorbell、处理 CQE 的确可能增加指令、HBM 与调度开销，但 GPU-initiated API、persistent communication kernel 和 NIC offload 可以减少这些成本；反过来，远端 load/store 也会占用 load queue、cache/MSHR、TMA slot 或 transaction buffer。正确比较单位是“从 producer 数据就绪到 consumer 可安全使用”的完整路径。

---
## 2.2 Reliability as Four Separate Problems

## Slide 23｜“可靠”至少要拆成四个问题

```text
Delivery:   packet / flit 是否到达？缺失如何检测和恢复？
Placement:  乱序到达的 bytes 应写入哪里？
Completion: 何时可以通知 producer/consumer 操作完成？
Ordering:   哪些事务必须先可见，何时允许 fence/commit？
```

讲师说明：这四件事经常被一个“可靠传输”词汇混在一起。支持 out-of-order arrival 不代表允许 out-of-order completion；数据已经写入目标地址，也不代表 memory model 已允许消费者观察它。Scale-up 还要把 completion 与 acquire/release、scope、atomicity 和错误响应对齐。

## Slide 24｜可靠性是分层覆盖，不是一个开关

| 层次 | 主要覆盖 | 不能单独解决 |
|---|---|---|
| PHY FEC / CRC | 有界物理位错误、检测损坏 | 拥塞丢包、交换机/端点故障 |
| Link-level replay / LLR | 相邻链路上的损坏或缺失 frame/flit | 跨多跳的不可恢复错误、端点重启 |
| PFC / CBFC / credit | 配置正确时避免接收 buffer overflow | 数据损坏、路由黑洞、永久故障 |
| End-to-end transport | 缺失检测、ACK/retry、duplicate handling | 节点进程状态丢失、语义级回滚 |
| Runtime / application | rank failure、checkpoint、idempotence | 纳秒级链路恢复 |

讲师说明：因此“lossless”不是“end-to-end reliable”的同义词。UALink 1.0 的正常路径由 FEC/CRC、每段 link-level replay 与 flow control 组成，但规范也定义了 drop、isolation 和 completion timeout 来处理不可透明恢复的错误；这比宣称“永不丢包”准确得多。[A33]

## Slide 25｜Lossless 能减少 drop，但可能放大排队故障

屏幕正文：

```text
PFC / credit backpressure
    ↓ fewer congestion drops
    ↑ head-of-line blocking / congestion spreading / config coupling
```

讲师说明：IRN 的核心贡献不是说 PFC 永远无用，而是证明 RDMA 并不从原理上必须依赖 PFC；在其研究配置中，有限 NIC 状态、选择性重传和 BDP flow control 可以在 lossy fabric 上工作。论文报告的资源与性能结果依赖其模型和配置，不能外推成所有 RNIC 的固定成本。UEC 1.0 同时支持 best-effort 与 lossless 网络，并在 best-effort 路径采用 endpoint reliability 与 congestion control。[A29][A32]

---
## 2.3 Multipath, Out-of-Order and Direct Placement

## Slide 26｜Multipath：允许乱序到达，维持所需的完成顺序

```text
one message / transaction
   ├─ packet 0 → path A ─┐
   ├─ packet 1 → path B ─┼→ direct placement / gap tracking
   └─ packet 2 → path C ─┘→ completion only after required bytes arrive
```

讲师说明：多路径的目标是减少 ECMP hash collision、避开拥塞和故障路径。代价不是一定要把全部 payload 暂存在巨型 reorder buffer，而是每个分段必须携带足够的 identity/offset，接收端还要跟踪 gap、duplicate 与 completion。UEC 明确规定跨不同路径不保证到达顺序；Google Falcon 与 OpenAI MRC 也把 multipath 和可靠连接语义结合起来。[A9][A10][A31][A32]

## Slide 27｜DDP 的真正启示：把 placement 与 arrival order 解耦

| RFC 5041 DDP model | 分段携带的关键定位信息 |
|---|---|
| Tagged Buffer | `STag + Tagged Offset`，直接放入已 advertised buffer |
| Untagged Buffer | `Queue Number + MSN + Message Offset`，定位 queued message buffer |

讲师说明：不要笼统地说“iWARP 每个包都有 MSN+MO”；它们属于 Untagged Buffer header，Tagged Buffer 使用 STag 与 Tagged Offset。DDP 的重要启示是：显式 placement metadata 可使“数据落点”不依赖分段的自然到达顺序。不过 RFC 5041 本身仍规定可靠、按序 delivery，因此也不能把“DDP”直接等同于任意乱序 transport；后续协议是在复用这一设计思想。[A30]

## Slide 28｜OpenAI MRC：从 flow pinning 到 per-packet multipath

屏幕正文：

```text
Traditional RC/RoCE deployment:
  one connection → a small number of paths

MRC direction:
  reliable connection semantics + packet spraying over many paths
  + static SRv6 path encoding + fast failure handling
```

讲师说明：截至 2026-08，OpenAI 已公开 MRC（Multipath Reliable Connection）及生产经验论文。它的意义不是又发明一个 collective，而是让 endpoint/transport 更充分利用多平面 Ethernet fabric，并降低单链路/单交换机故障对大训练作业的影响。[A9][A10]

## Slide 29｜Go-Back-N、Selective Retry 与 SACK 各自买了什么

| 恢复方式 | 优点 | 代价/风险 |
|---|---|---|
| Go-Back-N | 接收端状态简单、实现紧凑 | 一个 gap 重放后续窗口，长 BDP 下放大流量 |
| Selective Retry | 只重传缺失分段 | 需要精确 gap/duplicate/placement tracking |
| SACK / bitmap | 告知已收到范围，尽快释放发送 buffer | ACK state、bitmap、timer 与协议字段增加 |
| Time-based loss detection / probe | 区分延迟、乱序与真实丢失 | 依赖 RTT 模型，错误阈值会误重传或恢复过慢 |

讲师说明：SACK 不只为了“更快重传”，也用于让发送端更早释放 replay buffer。UEC 的 RUD 路径要求处理 SACK bitmap；ROD 除 probe 外可选。Falcon 公开材料强调 fast and accurate retransmissions。RACK/TLP 可作为现代时间型检测思想介绍，但不要说成 UEC 或 Falcon 必然逐条采用 TCP 的同名实现。[A31][A32]

---
## 2.4 Congestion Control, Retry and State Placement

## Slide 30｜拥塞控制：rate/window/credit/telemetry 是设计轴

| 设计轴 | 典型选择 |
|---|---|
| 控制量 | pacing rate、packet/byte window、receiver credits |
| 信号 | ECN、RTT、queue telemetry、packet trimming、ACK/NACK |
| 状态范围 | per-flow、per-destination、per-path、shared CC context |
| 实现位置 | 固定 ASIC、programmable NIC/DPA、host/runtime |

讲师说明：不能把“rate-based 必然差、window-based 必然好”当结论。窗口更直接约束 in-flight bytes；rate/pacing 对突发塑形有效；receiver credit 保护接收端；telemetry 可以加快反馈但增加数据面与控制逻辑。UEC 同时定义 network-signal CC、receiver-credit CC、transport flow control 与 packet window。Falcon 使用细粒度 RTT、硬件 traffic shaping、快速重传与 multipath；ConnectX-8 官方文档可确认 advanced routing 和 telemetry-based congestion control，DOCA DPA 还暴露 programmable congestion-control events，但本稿不反推未公开的 PSA 内部流水线。[A31][A32][A35][A36]

## Slide 31｜四种 profile：可靠性成本放在不同位置

| Profile | 正常交付与恢复 | 多路径/乱序 | 端点状态取舍 |
|---|---|---|---|
| UALink 1.0 | FEC/CRC + accelerator↔switch 每段 LLR + credit FC | 单层 switch；正常路径 lossless | link RTT replay buffer；高层错误走 RAS/drop/isolation |
| SUE full | LLR + PFC/CBFC + end-to-end Go-Back-N | 每 plane 单路径，可由外部跨接口均衡 | reliable transport + fixed-window CC |
| SUE Lite | LLR + lossless traffic class | 假定每 plane 按序 | 无 end-to-end reliable transport、无 CC |
| UET 1.0 | endpoint ACK/NACK、SACK、retry，可运行于 best-effort/lossless | multipath + RUD/ROD | 更丰富 PDC/CCC、timer 与 tracking |

讲师说明：这些不是同层、同目标产品的跑分表。UALink/SUE 面向短距 scale-up，UET 1.0 的重点是 backend scale-out。Broadcom 官方规范称 SUE Lite 通过移除 reliable transport、congestion control、AXI datapath 等简化，使“整个 SUE IP”最多缩小 50%；MAC/Link/PHY 大小不变，也不等于整个 XPU I/O die 减半。[A32][A33][A34]

## Slide 32｜BDP 最终会变成 buffer、状态与 Die 面积

```text
in-flight bytes ≈ bandwidth × RTT

800 Gb/s × 20 μs ≈ 2 MB
1 TB/s   ×  2 μs ≈ 2 MB
```

需要付费的并不只有 payload buffer：

- replay buffer 与 ACK release state；
- gap/duplicate/reorder 或 direct-placement metadata；
- per-destination packing queues 与 RX/TX queues；
- QP/PDC/CCC、timer、outstanding transaction 与 protection metadata。

讲师说明：Little's Law 只给出数量级下界，不能由带宽直接反推某个 IP 的 mm²。状态也不都按相同维度增长：per-link replay、per-destination queue、per-QP context、per-subflow context 的扩展性完全不同。UALink 还明确要求 TxReplay 覆盖 link RTT；其规范示例中 200 Gb/s link、1 μs RTT 对应约 25 KB，也就是约 40 个 640-byte data-link flit。[A33]

## Slide 33｜Scale-up / scale-out 融合的关键：可靠性边界放在哪里

```text
XPU local memory fabric
   ↕ short-RTT transaction / simple link protection
I/O memory or communication appliance
   ↕ buffered, reliable, multipath inter-rack transport
remote I/O memory or communication appliance
   ↕ short-RTT transaction
remote XPU
```

讲师说明：不必强迫一套协议同时覆盖片内、机柜内与跨机柜。把 buffer、重传、协议转换和 collective/KV offload 放到独立 I/O memory/DPU/communication appliance，可以减少 XPU die 上的长 BDP 状态，并把长距失败隔离在边界外；代价是 staging/copy、额外 hop、ownership、ordering、backpressure 与设备自身故障域。NetDAM 可作为这种架构思想的研究原型案例，而不是已成为行业标准的事实。[A39]

---
# 3. Who Moves the Data: Communication Software & Execution (62-94 min)

## 3.1 Control Plane, Data Plane and Collective Libraries

## Slide 34｜软件栈不是一条线，而是控制面 + 数据面

```text
framework / scheduler / parallel strategy
          ↓ control: groups, routes, placement, lifecycle
collective / P2P / EP APIs
          ↓ data: copy, reduce, signal, wait
transport backend / device API
```

## Slide 35｜MPI：通信语义来自科学计算

屏幕正文：

```text
point-to-point + collectives + communicator + progress semantics
```

讲师说明：MPI 的价值不是“老”，而是给出了成熟的 communicator、collective、topology 与 correctness 模型。GPU-aware MPI 可直接接受 device buffer，但实际路径取决于具体 MPI 实现、UCX/libfabric、GPUDirect 与 NIC；GPU-aware 并不是 MPI 标准对某条硬件路径的保证。[A38]

## Slide 36｜NCCL：GPU collective 的 topology-aware library

屏幕正文：

```text
API: AllReduce / AllGather / ReduceScatter / Broadcast / P2P
planner: topology + channels + protocol + algorithm
execution: CUDA kernels + transport plugins
```

讲师说明：NCCL 的用户看到 collective，内部却要决定 ring/tree、channel、LL/LL128/Simple、NVLink/PCIe/NET 等路径。性能问题要区分算法选择、拓扑发现、transport 和 kernel schedule。[A15]

## Slide 37｜CPU-initiated vs GPU-initiated

| | CPU initiated | GPU/device initiated |
|---|---|---|
| 发起 | host API / CPU progress | GPU kernel/device API |
| 优点 | 通用、调试容易 | 减少 launch gap，可 kernel 内协同 |
| 风险 | CPU jitter、launch serialization | persistent resources、memory ordering、debug complexity |

讲师说明：NCCL Device API 的 LSA/GIN、NVSHMEM、SHMEM-style put/get/signal 都服务于后一方向。NCCL EP 已公开基于 LSA 与 GIN 的 GPU-initiated 路径；NVSHMEM 则提供 CUDA kernel/stream 内的一侧通信模型。两者的 API、progress 与支持拓扑不能互相替代。[B1][B13]

## Slide 38｜DOCA 放在哪里

屏幕正文：

```text
DOCA = BlueField/DPU infrastructure and acceleration SDK
NCCL/MPI = application communication abstractions
```

讲师说明：DOCA 可以承载网络、存储、安全、DMA 等 offload，但不能直接把它讲成 NCCL 的替代品。真正的共同主题是把 CPU critical path 移到 DPU/NIC/device engine。[A6]

---
## 3.2 Where Should Reduction Execute?

## Slide 39｜In-network reduction 的价值不只是在链路上少发 bytes

```text
Ring AllReduce per-rank traffic ≈ 2 × (p-1)/p × message_size

endpoint partials → aggregation tree / multicast-reduce engine → result
```

| Reduce 位置 | 主要收益 | 主要约束 |
|---|---|---|
| GPU kernel | 最灵活 | 占 SM、HBM/L2 traffic、同步 |
| NIC/DPU | endpoint offload | NIC state、数据类型与编程接口 |
| Switch / SHARP | 减少重复 fabric traffic | 资源、树、算子与故障恢复限制 |
| Shared-memory fabric / NVLS 类 | 减少 endpoint 搬运与 HBM 干扰 | memory semantic、counter、地址域耦合 |
| Dedicated on-package collective engine（设计点） | 距计算更近 | silicon area、协议耦合、可编程性 |

讲师说明：对 AI workload，更重要的收益有时是少占 HBM/L2/SM，而不只是缩短一次 AllReduce。固定、可结合的 reduction 容易下沉；DeepEP 式动态 token dispatch、路由和大量状态并不天然适合交换机。SHARP 与 NVSwitch shared-memory collective 论文可作为两类公开案例。`on-package collective engine` 在本页只是一个设计点；当前采用的一手资料不足以确认所谓 Ascend 950 CCU 的内部微架构，因此不把它作为已披露产品事实。[A14][A37]

---
## 3.3 P2P and Object/State Movement

## Slide 40｜P2P 已从 send/recv 变成 object movement

屏幕正文：

```text
tensor pointer + metadata + placement + lifetime + retry + ownership
```

讲师说明：PP activation、PD KV、RL 权重、remote cache 都需要 P2P，但它们对对象生命周期、内存注册和失败恢复的要求不同。

## Slide 41｜Mooncake：Transfer Engine 与 distributed store

屏幕正文：

```text
Transfer Engine: heterogeneous zero-copy data movement
Mooncake Store: distributed object/KV storage + placement/lifecycle
```

讲师说明：Mooncake 不能只被描述成“P2P 库”。它把 RDMA/TCP/NVLink 等数据搬运与 KV/object storage control plane 结合，可用于 PD、KV cache、hidden state、权重等对象。[A16][B2]

## Slide 42｜P2P 在 PP 与 PD 分离中的不同

| | Pipeline Parallel | Prefill–Decode disaggregation |
|---|---|---|
| 对象 | activation | KV cache/state |
| 生命周期 | 单 microbatch/stage | 请求级、可复用、可持久化 |
| 关键风险 | bubble、backpressure | placement、cache miss、decode admission |

讲师说明：PD 不是把 PP send/recv 复用一次。KV 体量、生命周期与复用使它更像 memory/storage system。

## Slide 43｜DualPath：Storage→P 与 Storage→D 同时取数

屏幕正文：

```text
traditional: storage → prefill → decode
DualPath:    storage → prefill
             storage → decode
             dynamic load balancing between paths
```

讲师说明：DualPath 面向 agentic/multi-turn inference 的 KV-cache loading bottleneck。关键创新是增加 storage-to-decode path，以两侧 NIC/存储路径聚合带宽，而不是把所有加载压在 prefill 实例。[A17]

---
## 3.4 EP and MoE Communication

## Slide 44｜All-to-all 只是表面 API

屏幕正文：

```text
route → count → prefix/layout → dispatch → grouped GEMM → combine
```

讲师说明：MoE 通信的成本包括 token packing、metadata、remote write/read、expert-major layout、padding、combine reduction；只测裸 all-to-all 会漏掉大量 critical path。

## Slide 45｜DeepEP：把 dispatch/combine 做成专用 GPU 通信 kernel

讲师说明：DeepEP 提供 high-throughput 与 low-latency EP 路径，V2 公开方向转向 NCCL GIN backend、统一 ElasticBuffer，并强调更少 SM、scale-up/scale-out hybrid path。项目的性能数字必须连同 shape、精度、NIC 和 SM 占用引用。[B3]

## Slide 46｜NCCL EP：专用 EP 进入 NCCL 生态

屏幕正文：

```text
LL: direct P2P all-to-all for latency-sensitive inference
HT: NVLink intra-node aggregation + RDMA inter-node hierarchy
LSA + GIN: GPU-initiated data path
```

讲师说明：这是“通用 collective 库吸收 workload-specific primitive”的信号。NCCL EP 仓库仍明确标注持续演进，接口和性能应绑定版本。[B1]

## Slide 47｜UltraEP 与 MoonEP：负载均衡进入通信 critical path

| 项目 | 核心决策 |
|---|---|
| UltraEP | 基于当前 post-gating load 实时复制热点 expert，并在 scale-up domain 内 reroute |
| MoonEP | dynamic redundant experts + symmetric-memory weight layout，目标是固定 rank compute load |

讲师说明：传统 auxiliary loss/EPLB 偏慢时间尺度；UltraEP/MoonEP 把 replica placement、weight sync、reroute 做到 layer/microbatch critical path。收益与代价必须一起讲：额外权重搬运、slot、gradient reduction、计划求解。[B4][B5]

## Slide 48｜Scale-up domain 决定 expert replication 的边界

屏幕正文：

```text
replicate hot experts inside fast domain
route bulk tokens across slower domain only when necessary
```

讲师说明：UltraEP 的公开实现把复制与 reroute 约束在其支持的 NVLink scale-up domain；这说明 EP placement 不能脱离硬件域。更大的 rack-scale fabric 可能改变“一个 rank 固定拥有一个 expert”的默认假设，但仍要同时计入权重同步、故障域和调度复杂度。[B4]

## Slide 49｜EP 设计决策表

| 决策 | 低延迟偏好 | 高吞吐偏好 |
|---|---|---|
| dispatch | direct P2P | hierarchical aggregation |
| layout | 少 metadata / 固定 buffer | expert-major / padding 友好 GEMM |
| load balance | replica / quota | 更大 batch 平滑 |
| resources | 少 SM、低 startup | 更多 pipeline、channel、buffer |
| precision | BF16/FP8/FP4 traffic | 精度与 packing 开销权衡 |

---

---
# 4. How We Shorten the Critical Path: Overlap and Co-design (94-128 min)

## 4.1 Topology, NUMA and Locality-Aware Placement

## Slide 50｜MCM 的三角约束：数据、任务与缓存必须一起放

```text
address / page placement
        ↕
CTA / tile placement  ↔  cache placement and sharing
```

| 选择 | 收益 | 代价 |
|---|---|---|
| 地址均匀交错 | 容量和内存通道更易均衡 | 更多访问可能跨 Die |
| 强任务亲和性 | 提高 local reuse、减少跨 Die traffic | 尾部 CTA 或不规则 workload 可能失衡 |
| 缓存远端数据 | 降低重复远端流量 | 占用容量，并引入 lifetime / coherence 管理 |

讲师说明：这不是只把 die-to-die link 做宽就结束。2017 年 MCM-GPU 论文把问题明确拆成 remote-only L1.5 cache、distributed CTA scheduling 和 first-touch page placement；三者组合才显著降低 inter-GPM traffic。它们是研究方案，不是 Blackwell 实现披露，但揭示了可迁移的原则：`where data lives`、`where work runs` 与 `where reuse is captured` 必须协同设计。[A24]

## Slide 51｜从 NUMA 论文得到的通信设计原则

| 研究路线 | 解决的问题 | 对今天的启发 |
|---|---|---|
| MCM-GPU / first touch | page 与 CTA 缺少亲和性 | placement 是通信优化的一部分 |
| CARVE | remote working set 大于片上 LLC | 可用本地显存换远端带宽，但要管理一致性与容量 |
| HMG | hierarchy 下 flat sharer tracking 太贵 | coherence / consistency 应利用 scope 与拓扑层次 |
| PROACT / FinePack | sub-cacheline P2P 低效，bulk DMA 又阻塞流水 | 跟踪 readiness，并把细粒度写聚合成链路友好的 message |

讲师说明：这里要严格区分四件事：NUMA locality 是访问距离；cache coherence 是副本值如何保持一致；memory consistency/scope 规定线程何时必须观察到写入；kernel boundary flush/invalidation 只是某类实现机制。CARVE、HMG、PROACT、FinePack 都是论文提出或评估的设计，不应说成 GB200 已采用。主线只吸收一个结论：scale-up 的性能由 placement、transfer granularity、completion 和 consistency 共同决定，不只是峰值链路带宽。[A25][A26][A27][A28]

建议图示：横向画 `fine-grained load/store → coalesce/track readiness → efficient message → remote placement/cache`；下方单独放四个标签 `locality / granularity / completion / consistency`。

---
## 4.2 Compute-Communication Overlap and Async Data Movement

## Slide 52｜Overlap 的目标是缩短 critical path

屏幕正文：

```text
Bad:  communicate all → compute all
Good: tile/chunk i communicates while tile/chunk i-1 computes
```

讲师说明：有两个前提：依赖允许分块；资源不互相完全争抢。两个任务同时运行不等于有效 overlap。

## Slide 53｜Multi-stream 是机制，不是方案

屏幕正文：

```text
stream + event express dependency
chunking creates independent work
resource partitioning makes concurrency real
```

讲师说明：如果通信 kernel 占满 SM、compute 饱和 HBM，或 event 放错，multi-stream 只会增加抖动。验证要看 timeline 和 achieved overlap，而不是代码里是否创建了两个 stream。

## Slide 54｜三类 overlap

| 类型 | 例子 | 调度单位 |
|---|---|---|
| inter-kernel | GEMM 与 ReduceScatter 多 stream | chunk/kernel |
| fused producer-consumer | GEMM epilogue 发通信 | tile |
| persistent distributed kernel | kernel 内 load/store/signal/wait + compute | task/tile/warp role |

## Slide 55｜Data Movement 演进：从线程搬运到异步数据流

| 代际 | 关键变化 | 对 kernel 的含义 |
|---|---|---|
| Volta / Turing | Tensor Core fragment 与 accumulator 主要驻留寄存器 | 计算吞吐提高，但寄存器搬运与压力上升 |
| Ampere | `cp.async`：global → shared 的异步 copy | 供数不必先经普通寄存器 staging，可显式做多级流水 |
| Hopper | TMA + Tensor Map + `mbarrier` + async proxy | 地址生成、bulk tensor copy 与 completion 从计算 warp 中分离 |
| Blackwell | `tcgen05` + TMEM | accumulator 从 RF 移入专用 Tensor Memory，MMA、供数与 epilogue 更易解耦 |
| Rubin（公开预览） | runtime TMA override、细粒度 dependent coordination、counted scale-up completion | 同一套异步 dataflow 从片上内存继续延伸到跨 kernel 与远端 GPU |

讲师说明：这些机制是叠加而不是替换：Rubin 仍使用 TMA、TMEM 与 `tcgen05`。NVIDIA 公开口径还给出 Rubin 的 HBM4 峰值带宽最高 22 TB/s、NVLink 6 scale-up 带宽 3,600 GB/s、NVLink-C2C 1,800 GB/s、PCIe Gen6 x16 256 GB/s；这里按官方数字原样引用，不自行解释单向或双向口径。[A19][A20][A22]

建议图示：一条从 `RF → SMEM → TMEM → L2/HBM → NVLink peer memory` 向右展开的时间轴，每代只突出一个新增的数据通路。

## Slide 56｜一次“搬运”其实有三个问题

```text
Payload:     bytes 最终写到哪里？
Completion:  谁知道搬运完成、何时可以消费？
Lifetime:    buffer / cache line 何时可以复用或驱逐？
```

讲师说明：单卡 kernel 常把三者压在同一个线程控制流里；TMA、TMEM 和远端通信把它们拆开。`mbarrier` 回答本地异步操作何时完成；remote counter/flag 回答对端数据何时可见；cache eviction priority 管的是数据生命周期提示。通信进入 kernel 后，优化对象不再只是 payload bandwidth，而是 payload、completion 与 lifetime 三条路径能否一起流水。

## Slide 57｜Rubin MoE：一个 layout，运行时选择 expert

屏幕正文：

```text
shared Tensor Map: dtype / rank / layout / swizzle
        + runtime address / dimension / stride override
        ↓
TMA loads the selected expert tile
        ↓ repeated reuse with an L2 cache policy
last use → applypriority.async.bulk.tensor(...evict_normal)
```

讲师说明：Rubin 官方称之为 TMA inline descriptor update。PTX 9.4 为 `cp.async.bulk.tensor`、`cp.reduce.async.bulk.tensor` 和 tensor prefetch 增加 `.override::global_address` / `.override_attribute`，最低为 `sm_107f` family。它避免为相同 layout、不同地址的 expert 反复改写 Tensor Map；其中 attribute override 只覆盖 global dimension/stride，且必须连同 address override 使用。新的 `applypriority.async.bulk(.tensor)` 可在 last-use 后把一段数据的 L2 priority 恢复为 `evict_normal`，但 cache priority 只是 hint，不保证 expert 权重常驻。[A19][A20]

建议图示：左边画基线软件设计“每个 expert 一份 descriptor，或在使用前更新 descriptor”，右边画公开预览方向“一个公共 descriptor + router 提供运行时字段”。不要把基线画成 Blackwell 硬件限制。

## Slide 58｜Dependent launch：把 producer–consumer 边界缩小

屏幕正文：

```text
Existing grid-level PDL (sm_90+):
  prerequisite grid collectively triggers → dependent grid may start
  consumer waits before reading prerequisite output

Rubin public claim:
  required tile becomes ready → corresponding consumer work can start earlier
```

讲师说明：现有 `griddepcontrol.launch_dependents/wait` 从 PTX 7.8、`sm_90+` 就存在，但触发条件仍是 prerequisite grid 的所有 CTA 已执行 trigger 或结束。Rubin 官方博客展示更细粒度的 tile/thread-block producer–consumer coordination；截至 PTX 9.4 Developer Preview，完整 CUDA Runtime API、调度指令与 memory-ordering 示例尚未公开。因此不要把“consumer polling 某个 flag”讲成已确认实现，也不要推导成 megakernel 已经没有价值。资源竞争、跨 tile layout 和中间数据落点仍决定实际收益。[A19][A20][A21]

## Slide 59｜Counted writes：让 payload 自带远端完成计数

屏幕正文：

```text
sender kernel
  └─ fabric put / reduction ──→ remote data
                               └→ remote byte counter += accessed bytes

receiver observes expected counter value → applies required ordering → consumes data
sender-side mbarrier → tracks local completion / error report
```

讲师说明：counted completion 把目标数据访问与目标端 counter 更新绑定，减少另发 acknowledgment、remote atomic flag 等协调流量；receiver 仍须等待 counter 达到最终值。PTX 要求 counter 为 8 字节且 256 字节对齐，更新粒度未规定。最重要的版本边界是：`fabric.try_put/try_red ... counted::bytes` 在 PTX 9.3 已引入、最低 `sm_100`，并非 Rubin 独占 ISA；Rubin 官方材料把 counted writes 作为 device-initiated NVLink fused communication 的重点优化。Fabric 指令使用 CUDA CFT logical endpoint，也不是任意 raw pointer store。[A19][A20]

建议图示：对比“data write → fence → remote flag/ack”与“data write + counted completion”两条时序，不画成 receiver 无需同步。

---
## 4.3 Distributed Kernels and MegaMoE

## Slide 60｜Distributed Kernel：把网络加入 kernel memory hierarchy

屏幕正文：

```text
local registers/shared/HBM
remote symmetric memory / NIC queues
signals, barriers, credits
```

讲师说明：设计理念仍是 asynchronous execution + pipeline overlap，但多了 remote completion、跨 rank memory ordering、故障与 backpressure。它是单卡 kernel dataflow 的延伸，不是完全不同的优化学科。回扣 Slide 56：分布式 kernel 同样要分别设计 payload、completion 与 buffer/cache lifetime；Rubin counted writes 只是 scale-up completion 的一个具体例子。

## Slide 61｜DSL 与项目版图

| 方向 | 公开案例 | 这一层实际融合什么 |
|---|---|---|
| Distributed DSL / compiler | TileLink；Triton-distributed | tile 调度、通信 primitive、compute–communication overlap |
| Collective–GEMM fusion | FLUX；distributed GEMM / GEMM+AR/RS | collective chunk 与 GEMM tile/epilogue |
| Single persistent distributed MoE | FlashMoE | dispatch、expert compute、combine 的全局任务调度 |
| SM100 MegaMoE 实现 | DeepGEMM MegaMoE；FlashInfer CuTeDSL MegaMoE | FC1+activation/requant+FC2 与 token communication hooks |
| Device communication primitive | NVSHMEM；NCCL Device API LSA/GIN | symmetric memory、signal/barrier、device-side collective |

讲师说明：这些项目不能合并成一个“MegaMoE”品牌。DeepGEMM MegaMoE 是 SM100 上的 FP8 activation × FP4 weight 路径，PR #304 给出 CUDA/PTX 实现，PR #328 又修改了 kernel、layout、barrier 和 heuristics；FlashInfer 仓库中的 CuTeDSL MegaMoE 是另一条代码线，其致谢文件明确说明相关 kernel 由 NVIDIA CuTeDSL MegaMoE 团队开发后 vendored 进入仓库，公开目录覆盖 SM100 NVFP4/MXFP8 与 SM90 FP8 变体。FlashMoE 是另一项“single kernel distributed MoE”工作，Triton-distributed/TileLink 更偏编译与 DSL。引用时必须带项目名、版本、GPU 和 dtype。[A18][B6][B7][B10][B11][B12][B13][B14][B15]

## Slide 62｜DeepGEMM MegaMoE：真正融合的是端到端数据流

屏幕正文：

```text
EP dispatch / remote pull
        ↓
Linear1 gate/up GEMM (FP8 × FP4)
        ↓
SwiGLU + amax + FP8 requantization
        ↓
Linear2 GEMM
        ↓
remote BF16 combine-buffer writes
        ↓
final top-k combine reduction
```

实现抓手：

```text
persistent kernel + symmetric workspace
receive counters / arrival masks / token metadata
wave-and-phase scheduler
TMA + TMEM + two-CTA tcgen05 MMA
```

讲师说明：它的价值不只是减少 kernel launch，而是把 dispatch、两个 GEMM、激活/重量化、远端 write-back 和最终 combine 放进同一个进度系统。代价也由此而来：workspace 中的 counter、arrival phase、source token/top-k metadata 都成为正确性协议；phase 复用错误可能死锁，metadata 错误可能写错 combine slot。PR #304 中的 tile/thread 常数只描述该版本，PR #328 已继续调整调度与 heuristics；本稿没有本地 B200 复现，因此不引用项目 benchmark 作为通用性能结论。FlashInfer CuTeDSL MegaMoE 是独立实现，不能用其代码或结果替 DeepGEMM 背书。[B10][B11][B12]

建议图示：画出上述六段 dataflow，并在下方把 symmetric workspace 标成 control plane；不要只画一个写着 “fused kernel” 的大方框。

---
## 4.4 Communication-Memory-Storage Co-design

## Slide 63｜KV cache 已跨越四层介质

屏幕正文：

```text
GPU HBM ↔ CPU pinned DRAM ↔ remote memory ↔ SSD / context-memory tier
```

讲师说明：每下降一层，容量增加、单位成本降低，但 latency、带宽和调度复杂度上升。系统要决定 placement、prefetch、eviction、replication 与 recovery。

## Slide 64｜HiSparse：SGLang serving 内部的分层 KV feature

屏幕正文：

```text
Decode GPU: fixed-size hot KV buffer
Decode CPU pinned memory: complete KV
sparse-attention top-k: on-demand host → device swap-in
```

讲师说明：HiSparse 不是独立 P2P 库，而是 SGLang 的 decode-side serving feature。当前公开实现把 coordinator、scheduler staging、host/device pool、LRU/swap-in JIT kernel 和 CUDA Graph 路径整合在 SGLang 内；适用于原生 sparse-attention/DSA 与 DeepSeek V4 路径。[B8]

## Slide 65｜HiSparse + PD：直接写 Decode host pool

屏幕正文：

```text
Prefill GPU ──RDMA──> Decode CPU pinned host pool
                            ↓ on demand
                       Decode GPU hot buffer
```

讲师说明：SGLang 文档明确描述 direct-to-host：避免 Decode GPU 的瞬时 KV staging 和额外 DMA。Prefill 实例不感知 HiSparse，HiSparse 运行在 decode side；当前文档要求 PD disaggregation。DeepSeek V4 路径还区分 C4 与其他 KV 部分。[B8]

## Slide 66｜DualPath 与 HiSparse 解决不同层次的问题

| | DualPath | HiSparse |
|---|---|---|
| 主要瓶颈 | storage loading bandwidth | decode GPU KV capacity |
| 路径变化 | 增加 Storage→Decode | Host full KV→GPU hot subset |
| 决策主体 | distributed serving scheduler | SGLang decode scheduler/coordinator |
| 可组合性 | 可为 decode 端供数 | 可消费进入 host pool 的 KV |

## Slide 67｜Mooncake/HiCache：把 KV 当分布式对象管理

讲师说明：Mooncake Store 为 KV/object 提供 placement、replica、eviction 与多介质后端；SGLang HiCache 可接 Mooncake backend。当前 SGLang Mooncake store 文档还描述了 HiSparse host pool / DSV4 C4 side pool 的 layer-first multi-buffer zero-copy 存取接口。这是“通信系统与缓存系统边界消失”的具体例子。[B2][B9]

## Slide 68｜ICMS/CMX：网络开始连接新内存层级

屏幕正文：

```text
HBM (G3) ↔ Ethernet-attached context memory / flash tier (G3.5) ↔ storage
```

讲师说明：NVIDIA 在 Rubin 平台公开的 ICMS，后续公开材料使用 CMX Context Memory Platform 品牌，目标是为 KV cache 提供 BlueField-4 驱动的网络化 flash/context-memory tier。它更适合放在“通信–内存–存储协同”，此处只预埋概念。[C2]

## Slide 69｜ICMS/CMX 与跨机房分离式部署

屏幕正文：

```text
local HBM shortage → rack/pod context tier → remote DC / regional placement
```

讲师说明：跨机房不能只按带宽判断，RTT、尾延迟、故障恢复与数据一致性同样会进入 critical path。可跨机房拆分 control、replica 或 prefix storage，但逐 token 同步或细粒度 TP/EP 通常难以跨 WAN。NVIDIA ICMS/CMX 的公开定位是 context-memory tier，不应直接等同跨地域存储。[C2]

---
## 4.5 How Communication Shapes Hardware Evolution

## Slide 70｜Co-design 的最终优化对象

屏幕正文：

```text
Minimize bytes on critical path,
not merely maximize link utilization.
```

讲师说明：最好的通信可能是避免通信：prefix reuse、expert placement、recompute vs transfer、compression、direct-to-host、zero-copy、in-network reduce 都是在改变 bytes 的产生与落点。

---

## Slide 71｜硬件演化结论：可靠性、语义与 locality 必须一起设计

1. 短距、受控拓扑可以偏向 FEC、link replay、credit 和低状态 transaction path。
2. 更大故障域通常需要 explicit placement、multipath、selective recovery 与端点 congestion control。
3. Memory semantic 与 message semantic 会长期并存，边界取决于 granularity 与 failure model。
4. 可编程 NIC/DPA 的价值是承载 telemetry、policy、virtualization 与慢速异常路径，不只是“多几个核”。
5. Buffer/reliability boundary 是系统架构决策；同步 AI 系统还必须控制 variance，因为 step time 由最慢 rank 决定。

讲师说明：硬件已经从只追逐大消息峰值带宽，转向同时优化 path utilization、tail latency、device-side initiation、completion、remote-memory locality 与故障恢复。最终问题不是“Ethernet 或专用互联谁赢”，而是哪一层用多少状态，换取多大的故障覆盖、可编程性和利用率。

---

---
# 总结（128–130 min）

## Slide 72｜九句话带走

1. 先从模型 dataflow 出发，再选 collective 和硬件。
2. 节点内至少有 memory、GPU scale-up、PCIe I/O 三类 fabric。
3. 一个逻辑 GPU 仍可能存在非均匀的物理路径；地址、任务与缓存 placement 必须协同。
4. scale-up 与 scale-out 的核心差异是语义、RTT、失败模型，以及可靠性状态放在哪里。
5. 可靠传输必须拆成 delivery、placement、completion 与 ordering；lossless 不是端到端可靠的同义词。
6. 多路径与更高带宽会转化为 BDP buffer、状态和 tail-latency 成本，不能只看峰值吞吐。
7. EP 库已经同时处理通信、布局、kernel 与负载均衡。
8. distributed kernel 是异步流水线跨越远端边界后的延伸，completion 与 bytes 同样重要。
9. KV cache 让通信、内存和存储成为同一个系统问题。

---

---
# 建议增加的 Demo

## Demo A｜读拓扑而不是背带宽

```bash
nvidia-smi topo -m
nvidia-smi nvlink --status
ibdev2netdev
ibstat
```

展示：GPU↔GPU、GPU↔NIC affinity；然后预测 NCCL ring/rail mapping。

## Demo B｜Ring AllReduce 动画

做一个 4-rank、8-chunk 的可视化：逐步切换 ReduceScatter 与 AllGather，并提供“GPU reduce / switch reduce”按钮，对比 bytes traversing links。

## Demo C｜Overlap timeline

三条 timeline：串行、multi-stream 但资源争用、chunked genuine overlap。用同一总工作量解释为什么 overlap 可能无收益。

## Demo D｜MoE skew simulator

滑块控制 expert load CV/max-to-mean；显示最热 rank、dispatch tail、复制一个 hot expert 后的变化，以及复制权重的额外成本。

## Demo E｜HiSparse hot-buffer simulator

输入 context length、top-k、device buffer size、host/device bandwidth；显示 hit/miss、swap-in bytes 与 decode concurrency。

## Backup Slide M1｜MCM / NUMA 研究路线：不要当成 GB200 框图

| 年份 | 工作 | 关键思想 |
|---:|---|---|
| 2017 | MCM-GPU | remote cache + distributed CTA scheduling + first-touch page placement |
| 2018 | CARVE | 在本地 video memory 划出 remote-data cache，容量换互联流量 |
| 2020 | HMG | 以 scoped GPU memory model 构建 hierarchical sharer tracking |
| 2021 | PROACT | 编译期 instrumentation + data-block readiness，流水化链路友好传输 |
| 2023 | FinePack | 透明聚合并压缩 4–32 B P2P stores，降低 packet/protocol overhead |

讲师说明：这条时间线说明研究问题如何从“把多芯片做成一个逻辑 GPU”逐渐走向“细粒度 remote memory 如何像本地 load/store 一样可编程，又像 bulk DMA 一样高效”。所有方框都标 `research proposal`；不要画箭头暗示某篇论文已经落入 Blackwell。MCM-GPU 论文报告三个 locality 机制组合后将 inter-GPM bandwidth 降低 5×；CARVE 摘要报告用 3% GPU memory 接近理想 NUMA；HMG、PROACT 与 FinePack 的性能数字均只在各论文模拟或实验配置下成立，不进入主讲横向对比。[A24][A25][A26][A27][A28]

## Backup Slide T1｜Link replay、端到端 retry 与应用恢复覆盖什么

| 故障/事件 | FEC / link replay | End-to-end transport | Runtime / application |
|---|---|---|---|
| 单链路随机 bit error | 主要处理层 | 可作兜底 | 通常无感 |
| 接收 buffer 即将溢出 | flow control，非 replay 本身 | CC/window/credit | backpressure policy |
| fabric drop、route churn | 覆盖不了完整路径 | ACK/NACK、retry、multipath | timeout policy |
| 永久 link/switch failure | 本链路无法继续 | reroute/fail connection | communicator repair |
| endpoint reset / process death | 无法解决 | connection error | rank recovery/checkpoint |
| 上层 silent corruption | CRC 覆盖范围外可能漏过 | end-to-end integrity 可检测一部分 | checksum、validation、rollback |

讲师说明：可靠性需要明确“保护边界”和“错误是否可重放”。UEC LLR 规范甚至定义 poisoned FCS：当 replay RAM 或上游数据已不可恢复时，应传播错误而不是反复重放错误副本。UALink 也把 link-correctable error 与 transaction/RAS error 分开处理。[A32][A33]

## Backup Slide T2｜细粒度 transaction：wire efficiency 与 packing latency 的交换

```text
wire efficiency = useful payload bytes / total wire bytes

4–32 B load/store + fixed headers  →  low efficiency
pack many operations               →  better efficiency, extra wait/state
fixed-size flit                     →  simple scheduling, possible padding
compressed header                  →  less overhead, tighter fabric coupling
```

需要同时回答：

- 按 destination、VC 还是 ordering domain 建 packing queue？
- 什么条件触发发送：size、timer、barrier、credit 还是显式 flush？
- 一个慢 destination 是否阻塞同队列内其他 transaction？
- packet 丢失后，重放的是整个 pack 还是单个 operation？

讲师说明：Ethernet small-message efficiency 不能只用一个百分比概括；VLAN/IP/UDP、header 格式、FCS/IFG、FEC 与最小帧配置都会改变结果。SUE 选择按 destination/VC packing，SUE Lite 将 packing 上限限制为 1 KB；FinePack 则研究如何透明聚合细粒度 P2P store。[A28][A34]

## Backup Slide T3｜Scale-up domain 不是越大越好

```text
addressable accelerators ≠ efficient participants of every operator
```

决定有效域大小的因素：

1. TP/EP/PP/sequence-parallel 的实际 group size。
2. 一层还是多层交换、bisection bandwidth 与每跳延迟。
3. remote outstanding window、SRAM/HBM 配比与 overlap 能力。
4. collective barrier tail、expert skew 与 failure blast radius。
5. placement、partition 和调度器能否保持 locality。

讲师说明：UALink 1.0 的公开目标支持最高 1,024 accelerators，这是 addressability/system capability，不代表每个算子都应跨 1,024 卡。设计时应从模型通信 group 和故障域反推 scale-up domain，而不是从最大地址位宽正推应用规模。[A13][A33]

## Backup Slide T4｜远端延迟最终占用 XPU 的微架构窗口

```text
required outstanding bytes ≥ target bandwidth × observed latency
```

| 操作 | 延迟变大时被占住的资源 |
|---|---|
| remote load | load queue、MSHR/transaction entry、destination registers/buffers |
| remote store | store/commit state、credit、fence dependency、source buffer lifetime |
| TMA / DMA | descriptor、pipeline slot、staging buffer、barrier/counter |
| reliable transfer | replay buffer、sequence/gap state、timer、completion metadata |

讲师说明：异步引擎能把等待移出计算 warp，但不会消除 Little's Law。为了隐藏更长延迟，要增加并发、buffer 或分块；这些都会与 register、SMEM/L2、Tensor Core 和 I/O die area 竞争。公开资料不足以把这种 trade-off 换算成某个产品固定的 300–400 mm²，因此只讲资源方向，不给臆测面积。

## Backup Slide R1｜Rubin sparse Attention：减少 movement，但不是透明压缩

```text
dense QKᵀ scores in TMEM
  → tcgen05.ld{.red}.spcompress: select 2 of every 4 + metadata
  → sparse softmax on retained values
  → dtype/layout staging
  → sparse P × dense V
```

讲师说明：PTX 9.4 的 `tcgen05.ld{.red}.spcompress` 为 `sm_107a` architecture-specific feature，从 TMEM 读取 FP32 数据时执行 2:4 选择，输出压缩数据和位置 metadata；`.red` 还能返回 min/max reduction，但不等于完整 softmax。它减少 TMEM→register movement、保留值的 exponent/normalization 和后续 sparse MMA 工作，却仍有 conversion、layout repack、metadata staging 与同步成本。更关键的是，被删掉的 logits 通常不为零，Attention 语义和精度可能改变，所以不能宣称“免费 2× Attention”。[A19][A20]

放入备份页的原因：这能很好说明“算法改变 bytes”，但主线更关注通信；只有在讲到 compression 与 communication volume 时再展开。

---

# 制作图表清单

1. PCIe + NVLink/NVSwitch + NIC 的节点内物理图。
2. AMD xGMI/Infinity Fabric、Ascend HCCS 的同层对照图。
3. CloudMatrix 384/SuperPoD 独立画成跨 server/rack scale-up，不放入“单机”图。
4. Blackwell 双 compute-die 图：物理 die + HBM 资源 + NV-HBI，外框标 unified single GPU；不画未经披露的 HBM/L2 精确归属或 coherence 结构。
5. `address placement ↔ CTA placement ↔ cache placement` 三角图，并列出 locality 与 load balance 的冲突。
6. MCM-GPU→CARVE→HMG→PROACT→FinePack 时间线，所有节点明确标 research proposal。
7. Volta→Ampere→Hopper→Blackwell→Rubin data-movement 时间轴，统一画出 RF/SMEM/TMEM/HBM/remote GPU。
8. Rubin TMA descriptor sharing：per-expert descriptor vs shared descriptor + runtime override。
9. Blackwell bulk PDL 与 Rubin tile-level dependent coordination 的 timeline；Rubin 内部实现标“未披露”。
10. 普通 remote write+flag 与 counted write 的完成通知对照图。
11. Fat Tree、rail-optimized、3D torus 三图使用同一 endpoint 数量与图例。
12. Ring AllReduce 与 SHARP aggregation tree 的 reduce-location 对照。
13. reliability stack：FEC/LLR、flow control、E2E retry、runtime recovery 的故障覆盖矩阵。
14. multipath direct placement：三条乱序路径写入不同 offset，最后统一 completion。
15. Go-Back-N、selective retry、SACK bitmap 的发送/接收 buffer timeline。
16. BDP→replay/reorder/QP/PDC state→Die area 的资源流图；不标未经披露的 mm²。
17. Scale-up/scale-out reliability boundary：XPU—local fabric—I/O memory appliance—routed fabric。
18. DeepEP/NCCL EP/UltraEP/MoonEP 二维图：通信路径 × 负载均衡策略。
19. DualPath 与 HiSparse 用两张不同层次的数据流图，避免合并。

---

# 事实边界与演讲限定

- `Blackwell 双 Die / NV-HBI`：官方可讲“two reticle-limited dies”“10 TB/s chip-to-chip interconnect”“single, unified GPU”。这三个短语不能外推为所有路径等距、完整硬件 cache coherence、具体 cross-die latency、链路单向/双向拆分或 CTA affinity 实现。
- `MCM-GPU / CARVE / HMG / PROACT / FinePack`：均作为研究路线讲，不作为 GB200 内部实现证据。尤其不能把 L1.5、RDC、hierarchical directory、remote write queue 直接画进 Blackwell 产品框图。
- `coherence vs consistency`：cache coherence 管副本值，memory consistency/scope 管可观察顺序；kernel-boundary flush/invalidation 是机制，NUMA locality 是访问距离。正式 PPT 中四个术语不能混用。
- `CloudMatrix384`：华为官方可确认它是构建在 Atlas 900 A3 SuperPoD 上的云服务实例，后者最多包含 384 个 Ascend 910C；板级布线和交换结构如使用第三方图，页脚必须注明来源、发布日期和“非官方拓扑”。
- `Ascend 950 / collective engine`：华为官方发布页可确认 Ascend 950 路线、2 TB/s interconnect 和 UnifiedBus 方向，但本稿采用的一手资料不足以确认所谓 CCU 的内部微架构；主讲只保留“dedicated engine”作为设计空间，不画产品内部框图。
- `ICMS`：2026 公开材料中又出现 `CMX Context Memory Platform` 品牌。讲稿应说明名称演进，不把二者写成两个独立产品。
- `MegaMoE`：DeepGEMM 与 FlashInfer 是两个独立实现。DeepGEMM 主讲证据固定到 PR #304（merge `7f2a703e`）及后续 PR #328（merge `67fc6486`）；FlashInfer CuTeDSL 路径固定到审校时 commit `bac0eb790e93221a477cca7fcc1c505210b5bb92`。所有描述绑定 GPU 架构、dtype 与版本，不把项目 benchmark 当通用性能结论。
- `HiSparse`：按 SGLang feature 讲。引用固定到审校时 SGLang commit `22e4b3a81f6362123faac44d87e548a29e8f679f` 及列出的功能 PR；后续接口变化不反向修改本稿事实。
- `MoonEP/UltraEP`：均为 2026 新项目。项目自报性能只可作为各自配置下结果，不能直接横向比较。
- `Rubin tile-level dependent coordination`：官方只公开行为与 timeline；截至 PTX 9.4 Developer Preview，完整 runtime/PTX 接口与硬件调度实现未披露，不画 polling/barrier 微架构猜测图。
- `Counted writes`：Rubin 官方把它作为 NVLink 通信优化，但 `fabric.* counted::bytes` 已在 PTX 9.3、`sm_100+` 出现；必须区分“Rubin 官方重点能力”与“ISA 首次出现”。
- `TMA runtime override / applypriority async bulk`：PTX 9.4、`sm_107f` family-specific；`tcgen05.ld{.red}.spcompress` 是 `sm_107a` architecture-specific。不要把两类 target 混写。
- `Rubin 频率、L2 容量、I/O die 面积收益`：当前没有足够官方证据，不进入主讲结论；由峰值算力反推频率只可作为个人假设。Blackwell NV-HBI 的官方 10 TB/s 产品口径已单独用于 Slide 14，不把该数值外推到 Rubin。
- `lossless vs reliable`：PFC/CBFC/credit、LLR、端到端 retry 和应用恢复覆盖不同故障。正式 PPT 不用“无损即可保证永不丢包”或“LLR 可替代所有端到端可靠性”这类绝对表述。
- `RFC 5041 DDP`：Tagged Buffer 使用 STag + Tagged Offset；Untagged Buffer 使用 Queue Number + MSN + Message Offset。不要写成所有 iWARP/DDP packet 都带 MSN+MO；RFC 本身仍要求可靠、按序 delivery。
- `SUE / SUE Lite`：Broadcom 2025-09-26 官方 framework 可确认 full SUE 的 Go-Back-N、fixed-window CC，以及 SUE Lite 移除 end-to-end reliable transport/CC、只保留 hop-by-hop LLR。`up to 50%` 指 SUE IP，且 MAC/Link/PHY 大小不变；不能扩写为整个 I/O die 或 XPU 面积减半。
- `UALink 1.0`：可确认 accelerator↔switch 每段 link-level replay、credit flow control、正常路径 lossless，以及更高层的 RAS/drop/isolation/timeout。`end-to-end data protection` 不等于存在一个覆盖所有故障的透明 end-to-end retransmission protocol。
- `UEC 1.0`：规范的重点是 backend scale-out；它定义 RUD/ROD、SACK、packet window、multipath 与多种 CC。不要把它当成 UALink/SUE 的同层替代，也不要声称其所有实现都采用某个单一 rate-或window-based 算法。
- `Falcon`：官方可讲 lossy Ethernet、multipath、细粒度 RTT、hardware-enforced traffic shaping、fast retransmission、flexible ordering 与多 ULP。论文中的吞吐、Mops、tail 或丢包结果必须连同实验配置引用，不能提升为产品通用保证。
- `ConnectX-8 PSA/DPA`：官方公开材料可确认 advanced routing、telemetry-based congestion control，以及 DOCA DPA programmable congestion-control events；当前证据不足以画 PSA 内部流水线、八平面实现或断言某段算法一定运行在哪个处理器上。
- `Scale-up/scale-out fusion`：通过 I/O memory/DPU/communication appliance 放置可靠性边界是架构选项。NetDAM 只能标为作者方案/研究设计；需要同时说明 staging、ownership、ordering、backpressure 和新增故障域。
- `未经采用的量化数字`：不使用“5% 丢包仍 90% goodput”“Scale-Up IP 300–400 mm²”“TPU 单算子最多 512 卡”等未完成一手核验或强依赖配置的数字。

---

# 主要参考资料

## 硬件、网络与协议

- [A1] NVIDIA, *NVLink and NVSwitch* product/architecture documentation: https://www.nvidia.com/en-us/data-center/nvlink/
- [A2] NVIDIA, *DGX/HGX platform architecture documentation*: https://docs.nvidia.com/dgx/
- [A3] AMD ROCm, *AMD Instinct MI300 Series microarchitecture*, including MI300 package and eight-GPU node-level Infinity Fabric topology: https://rocm.docs.amd.com/en/latest/reference/gpu-arch/mi300.html
- [A4] Huawei, *Groundbreaking SuperPoD Interconnect: Leading a New Paradigm for AI Infrastructure*, 2025-09-18: https://www.huawei.com/en/news/2025/9/hc-xu-keynote-speech
- [A5] NVIDIA Networking, ConnectX / BlueField / Spectrum documentation: https://docs.nvidia.com/networking/
- [A6] NVIDIA DOCA documentation: https://docs.nvidia.com/doca/
- [A7] AWS, *Elastic Fabric Adapter*: https://aws.amazon.com/hpc/efa/
- [A8] AWS Neuron documentation: https://awsdocs-neuron.readthedocs-hosted.com/
- [A9] OpenAI, *Supercomputer networking to accelerate large scale AI training*, 2026-05-05: https://openai.com/index/mrc-supercomputer-networking/
- [A10] *Resilient AI Supercomputer Networking using MRC and static SRv6*, arXiv:2605.04333: https://arxiv.org/abs/2605.04333
- [A11] NCCL documentation and topology-aware collective literature: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/
- [A12] Google Cloud, TPU system architecture documentation: https://cloud.google.com/tpu/docs/system-architecture-tpu-vm
- [A13] UALink Consortium specifications/news: https://ualinkconsortium.org/
- [A14] NVIDIA, SHARP documentation: https://docs.nvidia.com/networking/display/sharpv320
- [A15] NVIDIA NCCL User Guide: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/
- [A19] NVIDIA, *Inside NVIDIA Rubin GPU Architecture: Powering the Era of Agentic AI*, 2026-07-21: https://developer.nvidia.com/blog/inside-nvidia-rubin-gpu-architecture-powering-the-era-of-agentic-ai/
- [A20] NVIDIA, *PTX ISA 9.4 — CUDA 13.4 Developer Preview*: https://docs.nvidia.com/cuda/developer-preview/13.4/parallel-thread-execution/index.html
- [A21] NVIDIA, *CUDA Programming Guide: Programmatic Dependent Launch and Synchronization*: https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/programmatic-dependent-launch.html
- [A22] NVIDIA, *CUDA Toolkit 13.4 Developer Preview Release Notes*: https://docs.nvidia.com/cuda/developer-preview/13.4/cuda-toolkit-release-notes/index.html
- [A23] NVIDIA, *NVIDIA Blackwell Architecture* / Blackwell launch announcement. Official wording: “two reticle-limited dies connected by a 10 terabytes per second (TB/s) chip-to-chip interconnect in a unified single GPU”: https://www.nvidia.com/en-us/data-center/technologies/blackwell-architecture.md and https://nvidianews.nvidia.com/news/nvidia-blackwell-platform-arrives-to-power-a-new-era-of-computing
- [A29] Mittal et al., *Revisiting Network Support for RDMA* (IRN), SIGCOMM 2018, DOI 10.1145/3230543.3230557: https://arxiv.org/abs/1806.08159
- [A30] IETF RFC 5041, *Direct Data Placement over Reliable Transports*, October 2007: https://www.rfc-editor.org/rfc/rfc5041.html
- [A31] Singhvi et al., *Falcon: A Reliable, Low Latency Hardware Transport*, SIGCOMM 2025, DOI 10.1145/3718958.3754353: https://dl.acm.org/doi/10.1145/3718958.3754353 ; Google Cloud overview: https://cloud.google.com/blog/topics/systems/introducing-falcon-a-reliable-low-latency-hardware-transport
- [A32] Ultra Ethernet Consortium, *Ultra Ethernet Specification 1.0*, June 2025: https://ultraethernet.org/wp-content/uploads/sites/20/2025/06/UE-Specification-6.11.25.pdf
- [A33] UALink Consortium, *UALink 200G Specification Rev 1.0 — Evaluation Copy*, April 2025: https://ualinkconsortium.org/wp-content/uploads/2025/04/UALink200_Specification_v1.0_Evaluation_Copy.pdf
- [A34] Broadcom, *Scale-Up Ethernet Framework Specification*, Scale-Ethernet-RM104, 2025-09-26: https://docs.broadcom.com/docs/scale-up-ethernet-framework
- [A35] NVIDIA, *ConnectX-8 SuperNIC User Manual — Introduction*: https://networking-docs.nvidia.com/connectx8hw/introduction
- [A36] NVIDIA DOCA, *DPA Development* documentation, including Programmable Congestion Control events: https://networking-docs.nvidia.com/doca/archive/3-4-0/dpa-development
- [A37] Graham et al., *An In-Network Architecture for Accelerating Shared-Memory Multiprocessor Collectives*, ISCA 2020, DOI 10.1109/ISCA45697.2020.00085: https://doi.org/10.1109/ISCA45697.2020.00085
- [C2] NVIDIA Rubin/BlueField-4 ICMS/CMX public materials: https://resources.nvidia.com/en-us/accelerated-networking-resource-library/cmx-tech-blog

## 软件、论文与开源项目

- [A16] *Mooncake: A KVCache-centric Disaggregated Architecture for LLM Serving*, FAST 2025 / arXiv:2407.00079: https://arxiv.org/abs/2407.00079
- [A17] *DualPath: Breaking the Storage Bandwidth Bottleneck in Agentic LLM Inference*, arXiv:2602.21548: https://arxiv.org/abs/2602.21548
- [A18] Zheng et al., *TileLink: Generating Efficient Compute-Communication Overlapping Kernels using Tile-Centric Primitives*, MLSys 2025 / arXiv:2503.20313: https://arxiv.org/abs/2503.20313
- [A24] Arunkumar et al., *MCM-GPU: Multi-Chip-Module GPUs for Continued Performance Scalability*, ISCA 2017, DOI 10.1145/3079856.3080231: https://research.nvidia.com/publication/2017-06_mcm-gpu-multi-chip-module-gpus-continued-performance-scalability
- [A25] Young et al., *Combining HW/SW Mechanisms to Improve NUMA Performance of Multi-GPU Systems* (CARVE), MICRO 2018, DOI 10.1109/MICRO.2018.00035: https://research.nvidia.com/publication/2018-10_combining-hwsw-mechanisms-improve-numa-performance-multi-gpu-systems
- [A26] Ren et al., *HMG: Extending Cache Coherence Protocols Across Modern Hierarchical Multi-GPU Systems*, HPCA 2020, IEEE 9065597: https://research.nvidia.com/publication/2020-02_hmg-extending-cache-coherence-protocols-across-modern-hierarchical-multi-gpu
- [A27] Muthukrishnan et al., *Efficient Multi-GPU Shared Memory via Automatic Optimization of Fine-Grained Transfers* (PROACT), ISCA 2021, DOI 10.1109/ISCA52012.2021.00020: https://research.nvidia.com/publication/2021-06_efficient-multi-gpu-shared-memory-automatic-optimization-fine-grained-transfers
- [A28] Muthukrishnan et al., *FinePack: Transparently Improving the Efficiency of Fine-Grained Transfers in Multi-GPU Systems*, HPCA 2023, DOI 10.1109/HPCA56546.2023.10070949: https://doi.org/10.1109/HPCA56546.2023.10070949
- [A38] MPI Forum, *MPI: A Message-Passing Interface Standard, Version 4.1*, November 2023: https://www.mpi-forum.org/docs/mpi-4.1/mpi41-report.pdf
- [A39] Fang and Peng, *NetDAM: Network Direct Attached Memory with Programmable In-Memory Computing ISA*, arXiv:2110.14902, 2021: https://arxiv.org/abs/2110.14902
- [B1] NVIDIA NCCL Extensions / NCCL EP, commit `9f47d6eb3b60962d8157a579b4caaaa4ae6b19f4`: https://github.com/NVIDIA/nccl-extensions/tree/9f47d6eb3b60962d8157a579b4caaaa4ae6b19f4
- [B2] Mooncake repository, commit `51e594d3a21660bdf2f6f1f11ec544b7cfb06932`: https://github.com/kvcache-ai/Mooncake/tree/51e594d3a21660bdf2f6f1f11ec544b7cfb06932
- [B3] DeepEP repository, commit `01dc3aaac82068020353dce2c302e38153c0bfaa`: https://github.com/deepseek-ai/DeepEP/tree/01dc3aaac82068020353dce2c302e38153c0bfaa
- [B4] UltraEP repository, commit `94cab099b44fffa99a82fea99e7c12d89cf65e4f`: https://github.com/Dots-Infra/UltraEP/tree/94cab099b44fffa99a82fea99e7c12d89cf65e4f
- [B5] MoonEP repository, commit `7745ffa00532d9086b49bab84a65b17f687ede14`: https://github.com/MoonshotAI/MoonEP/tree/7745ffa00532d9086b49bab84a65b17f687ede14
- [B6] Triton-distributed repository, commit `8260bc34398c2b8f36dc840fd22f741ca9294584`: https://github.com/ByteDance-Seed/Triton-distributed/tree/8260bc34398c2b8f36dc840fd22f741ca9294584
- [B7] FlashInfer MoE EP / CuTeDSL MegaMoE, repository commit `bac0eb790e93221a477cca7fcc1c505210b5bb92`: https://github.com/flashinfer-ai/flashinfer/tree/bac0eb790e93221a477cca7fcc1c505210b5bb92/flashinfer/moe_ep/kernel_src
- [B8] SGLang HiSparse implementation at commit `22e4b3a81f6362123faac44d87e548a29e8f679f`; initial sparse-attention integration PR #20343, PD direct-to-Decode-DRAM PR #21591, DeepSeek V4 direct-to-host PR #24880: https://github.com/sgl-project/sglang/tree/22e4b3a81f6362123faac44d87e548a29e8f679f
- [B9] SGLang Mooncake Store integration at the same pinned commit: https://github.com/sgl-project/sglang/tree/22e4b3a81f6362123faac44d87e548a29e8f679f/python/sglang/srt/mem_cache/storage/mooncake_store
- [B10] DeepSeek, DeepGEMM PR #304, *Introducing Mega MoE, FP4 Indexer and other features/fixes*, merged as `7f2a703e`: https://github.com/deepseek-ai/DeepGEMM/pull/304
- [B11] DeepSeek, DeepGEMM PR #328, *Mega MoE optimizations & benchmarks*, merged as `67fc6486`: https://github.com/deepseek-ai/DeepGEMM/pull/328
- [B12] FlashMoE, *Fast Distributed MoE in a Single Kernel*, NeurIPS 2025 / arXiv:2506.04667; code commit `9cc0c32443d2a2da6825a68af5ef83060329483b`: https://github.com/osayamenja/FlashMoE/tree/9cc0c32443d2a2da6825a68af5ef83060329483b ; paper: https://arxiv.org/abs/2506.04667
- [B13] NVIDIA NVSHMEM repository, commit `f86be2c6c390448cc4e0c32db9f27f5dbc345b67`: https://github.com/NVIDIA/nvshmem/tree/f86be2c6c390448cc4e0c32db9f27f5dbc345b67
- [B14] ByteDance FLUX, a communication-overlapping library for tensor/expert parallelism, commit `19831ca2d820e3e782ed1d15d8b52d0898b78b26`: https://github.com/bytedance/flux/tree/19831ca2d820e3e782ed1d15d8b52d0898b78b26
- [B15] NVIDIA CUTLASS distributed GEMM examples, commit `dcf215af68a2d08d305076c152a06f201728cd53`: https://github.com/NVIDIA/cutlass/tree/dcf215af68a2d08d305076c152a06f201728cd53/examples/65_distributed_gemm

---

# 特别鸣谢

特别感谢微信公众号 **zartbot** 长期整理并分享 GPU 多 Die、缓存一致性、RDMA、Scale-Up/Scale-Out 与可靠传输相关资料。本文在确定问题脉络和扩展阅读范围时重点参考了以下文章（微信公众号文章未找到稳定公开永久链接，按标题与来源记录，访问日期 2026-08-12）：

- 《英伟达 GB200 架构解析 4：BlackWell 多 die 和 Cache 一致性相关的分析》
- 《谈谈 RDMA 和 ScaleUP 的可靠传输》

具体产品事实、协议字段和量化数字仍尽量回溯至上列官方文档、标准、论文和固定版本的开源仓库。文中若有疏漏，由本稿作者负责。
