# 前序演讲对齐说明

审校日期：2026-08-13

## 输入材料与核验范围

本说明对照用户更新的 `Towards Modern Networking System.pptx`：

- 64 页，无隐藏页；17 个 notes part 未包含实质讲者备注；
- SHA-256：`2E3BE00DCDC00F8A80A792E34C83877560E6673AA605B55F52563E28AD97211C`；
- 已提取全部 OOXML 文本，并把 64 页逐页渲染后完成视觉检查；
- 新版已经补齐旧 PDF 缺失的 management/domain、network microarchitecture 和 tile-based computing 正文。

第 44–48 页仍明显带有工作稿特征：重复的 prior/posterior 页、未完成的 audio/gaming 句子、仅放一张 SQ/CQ 图，以及只有关键词的 Ethernet 页。本场不依赖这些页建立结论，也不在衔接中复述其具体例子。

前序演讲的完整叙事是：

1. `Behind the Monolith`：从 wire、flow control、credit/replay、router/VC 推导到 domain 与 connection；
2. `Inside the Monolith`：批评传统 RC QP 把身份、顺序、可靠性、路径与 SQ/RQ/CQ progress 耦合，主张 software connection、reliable tunnel 与 physical path 分层；
3. `Beyond the Monolith`：提出 bounded transaction、Tile Load/Store、显式 Fence、地址空间化设备和 unified system 作为未来架构方向。

## 与本场的分工

两场内容没有实质性冲突，但不能用“前序讲网络、本场讲软件”简单切分。更准确的分工是：

| 前序内容 | 本场承接位置 | 本场新增的问题 |
|---|---|---|
| p.19–24：credit、replay、lossless/lossy、failure/rot、PCIe | Slide 10–12、22–25、32、Backup T1 | 先把机制放进 GPU A→GPU B 的物理路径，再把 delivery、placement、completion、ordering 和 runtime recovery 分层，并量化 BDP/state |
| p.27–41：router、HOL/VC、causation、Orderlock、InfiniBand、lossy router | Slide 25–31、Backup T1/T5 | 进入 multipath、DDP、SACK、IRN、UET、Falcon、UCCL 与 congestion control |
| p.43：Domain and Connection | Slide 21–22、33–34 | 区分管理域、一致性/内存真相域、RTT/故障域与通信 connection；解释透明层次不等于状态消失 |
| p.50：RC QP “Network Jar Pit” | Slide 26–31、34、37、Backup T5 | 用现有 RNIC、UET、Falcon、UCCL 检查连接、可靠状态与路径究竟能拆到什么程度 |
| p.51–53：按粒度/时效选择可靠性、百万连接、事务与 tracker 成本 | Slide 24–33、44–49 | 把策略落到 collective、P2P、EP/MoE 的 burst、incast、tail 与资源预算 |
| p.55–60：tile、Tile Load/Store、SQ/CQ 批评、同步与 memory hierarchy | Slide 52–62、Backup T2 | 用 TMA、NVSHMEM、NCCL Device API、TileLink、distributed GEMM、MegaMoE 检查可实现路径 |
| p.61：SUE/DMA/Aggregation/NIC unified system | Slide 33、39、60–71 | 比较 endpoint、switch、DPU/I/O memory、collective engine 与 KV/context-memory placement |

因此，本场不重复证明 credit、VC 或 SQ/CQ 的存在，而是先让零基础听众跟踪一个 tensor chunk，再把前序提出的架构原则放进真实 AI dataflow 中做压力测试：性能是否来自少一次 staging、少一个 completion、更多 path entropy，还是把状态转移到了 CPU、GPU、NIC SRAM、DPA 或远端 memory appliance。

## 一致的核心结论

1. `lossless`、链路可靠、端到端可靠和应用恢复不是同一个层次。
2. 多路径必须与 direct placement、gap/duplicate tracking、completion 和 fence 一起设计。
3. connection identity、reliability state 与 physical path 值得解耦；UET、Falcon 和 UCCL 是不同层次的实例。
4. 同步成本随距离增大，distributed kernel 必须把 payload、completion 与 lifetime 一起流水。
5. 大块有界工作单元有利于 amortize packet/control overhead，但最佳粒度取决于 workload 与硬件。
6. aggregation/reduction 的放置必须结合流量形态、状态规模、失败回退和内存路径判断。

## 必须保留的科学边界

前序后半部分包含明确的架构立场。为避免两场连讲后被听众理解成“行业已经统一采用”，本场采用以下限定：

1. `Domain` 不是单一通用名词。前序术语表中的 `Management Domain` 是一个 OS 最终裁决资源的范围；p.43 的 `Domain` 又强调共享同一份内存真相。本场的 scale-up/scale-out domain 主要按 RTT、拓扑、语义和故障预算划分，三者可能重合但不等价。并且“同一台计算机”并不自动意味着所有 CPU、离散 GPU、NIC 和私有 HBM 共享一个 coherent memory truth；还要检查 addressability、coherence、consistency scope、IOMMU/PASID 与 ownership。
2. `Software Connection`、`Reliable Tunnel`、`DMA Context`、`Bounded Transaction` 是前序架构中的对象，不直接等同为 RDMA QP/RC、UET PDC/CCC、UCCL connection/chunk 或 compute tile。
3. p.50 对 RC QP 的描述适合作为“传统或常见实现的耦合问题”，不适合作为所有 RC/RNIC 的永久定义。不同实现已有 SRQ、DC、adaptive routing、selective recovery 和厂商扩展。
4. p.50 所说 UEC “连接状态仍驻 NIC”是可能的实现成本，不是 UEC wire specification 对 SRAM residency 的规定。UET 定义协议对象和行为，具体状态可以由 ASIC、firmware、DPA 或外部 memory hierarchy 实现。
5. p.51 的逐 region 可靠/冗余/尽力而为策略，以及 p.52 的“白牌交换机默认即最优、无需调参”，是目标架构，不是当前 Ethernet、UEC、SUE 或 UALink 已共同保证的产品事实。
6. p.52 关于 exactly-once 的警告应限定为：仅靠不可靠网络传输无法在不确定故障后判断远端应用动作是否执行；带 durable state、deduplication、transactions 或 consensus 的系统仍可在明确故障模型下提供 exactly-once effect，不能由“两将军问题”推出一切 exactly-once 语义都不可能。
7. p.53 的 128 KiB transaction、1 KiB packet、DMA context/QP/tunnel 数量是配置示例，不是协议固定值。状态规模要分别按 per-link、per-path、per-destination、per-connection 和 per-transaction 计算。
8. p.55 的 `32–128 KiB tile` 是建议设计范围，不是普适最优值。UCCL 的 32 KiB chunk、GEMM tile、EP token payload、KV block 与 wire transaction 都有不同约束；同页的 `ACE` 含义也需要讲者给出明确展开和一手来源，本场不复用该缩写。
9. `Tile Load/Store` 可以把 SQE/CQE bookkeeping 隐藏在 compiler/runtime/device engine 后面，但不会消灭底层有限 queue、credit、translation/protection、retry、completion 和 backpressure。
10. “加速器直接传输、不经内存中转”应理解为避免 CPU/host staging；源和目标数据仍处于某种 register/cache/SRAM/HBM/DRAM 层级，并受其带宽、生命周期与可见性约束。
11. p.58 的同步延迟表是数量级示意，不能作为跨平台定量结论；`cp.async` 是 GPU 内部 global-to-shared 异步 copy，不是通用 CPU core↔device doorbell 的代表。
12. 把远端资源放进地址空间不会自动获得本地内存的 failure/coherence semantics。跨管理域仍需 capability、撤销/generation、partial completion、unknown result、endpoint reset 和 memory scope；“新设备只需占一段地址、从不需要新指令”也只是抽象目标，实际仍可能需要专用 operation、cacheability attribute、fence、privilege 与 error protocol。
13. p.57 的“SQ/CQ programming world is crashing”和 p.62 的 memory-wall 结论属于演讲者的趋势判断与修辞。本场承接其问题意识，但不把它们引用成已证明的定理。
14. p.44–48 的 audio timer、gaming 和 Ethernet 内容仍是草稿。特别是“音频设备不用中断、timer polling 消灭并发面”只在特定 polling/periodic design 下可能成立，不能作为通用设备或网络模型结论。

## Orderlock 的精确口径

前序第 38 页的三元组来自 Jiang et al., *Orderlock*（SIGCOMM 2025）。原论文的限定是：在其模型中，`in-order delivery`、`lossless transmission` 与 `out-of-order capability` 同时成立，是该类 Orderlock 死锁的必要充分条件。本场只使用这个限定结论，不说成“任何乱序与无损组合都会死锁”。

因此，direct placement 只解决“乱序数据写到哪里”；它不取消 completion、fence、buffer 上限，也不自动消除 Orderlock 风险。

## 建议开场衔接

建议用 90–120 秒：

> 上一场已经从 wire、credit、replay 和 router 推导出网络为何需要流控、可靠性与显式因果，又进一步提出 connection/path 解耦和 tile transaction 的未来抽象。我们这一场先用一个 GPU A→GPU B 的 tensor chunk 建立端到端坐标系，再把这些抽象放进 AI workload：collective、P2P、MoE、distributed kernel 和 KV movement 分别产生什么依赖，现有 UET、Falcon、UCCL、NCCL/DeepEP 与 GPU 异步机制已经做到哪一步，以及那些被抽象隐藏的 queue、buffer、completion 和 failure state 最终由谁付费。

这段衔接既承认前序已经建立的体系结构主线，也明确本场的任务是 workload-to-implementation verification，而不是重复或替代前序方案。
