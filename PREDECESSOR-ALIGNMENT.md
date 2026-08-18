# 前序演讲对齐说明

审校日期：2026-08-18

## 输入材料与核验范围

本说明对照用户提供的 `Towards Modern Networking System.pdf`：

- 79 页；标题页日期为 2026-08-15；
- SHA-256：`EE50AE75C12FB2B263ADA21EA8AFEC95E7A228BCE9FD78125FAD75F92BDB1A6F`；
- 已提取全部页面文字，并完成逐页视觉检查；
- 源 PDF 不收入公开仓库，只记录版本指纹和两场内容的边界。

需要先说明一个影响衔接方式的事实：新版不只是目录预告。它在 p.64–70 初步展开了网络分层、RC QP 耦合的批评、multi-plane/SRv6 风格路径，以及在 p.71–78 展开了 Tile-based Computing、Stateful Operation、`CPU owns setup. xPU owns issue.`、Tile Load/Store、Descriptor、Atomic、Barrier、Commit、Wait 和 Unified System。因此，本场不应再声称这些内容“尚未讲授”；正确的承接是把前序提出的抽象放入 GPU tensor、RDMA、MoE、KV 和 distributed-kernel 的具体数据路径，并与公开标准/实现对照。

## 前序实际覆盖的内容

| 页码 | 已展开的内容 | 本场如何承接 |
|---|---|---|
| p.15–25 | VALID/READY、长连线与缓冲、credit、replay、lossless/lossy、数据损坏、PCIe link layer | Slide 10–12、22–25 快速 recall，再放入 GPU A→GPU B 的完整事件链 |
| p.27–42 | router、HOL、VC、FLIT、因果依赖、deadlock/Orderlock、InfiniBand、lossy router 问题 | Slide 25–31 继续讲 multipath、乱序放置、恢复、拥塞与状态位置 |
| p.43–51 | Domain、NVL72、状态与计算、同步、prior/posterior、audio timer、SQ/CQ 生命周期 | Slide 4–8、15–16、21–22、34–37 用真实 tensor transfer 区分 initiator、progress、doorbell、completion 和 consumer wait |
| p.52–59 | Ethernet、IP、ARP、TCP 的入门层次 | 本场不重讲通用协议栈，直接进入 RDMA/AI transport 特有的 placement、ordering、multipath 和 recovery |
| p.64–70 | InfiniBand 与 TCP/iWARP 的 worldview、大规模 AI 网络问题、RC QP 耦合批评、semantic/connection/execution/transaction/tunnel/path 分层、multi-plane/SRv6 风格架构 | Slide 26–33 将这些抽象落成 MRC、Falcon、UET、UCCL 的具体 transport 与故障案例，不把前序候选对象冒充标准对象 |
| p.71–78 | Tile-based Computing、Stateful Operation、`CPU owns setup. xPU owns issue.`、Tile Load/Store、Descriptor、Atomic、Barrier、Commit、Wait、Unified System/Scale-Up/Scale-Out | Slide 50–62 回扣同一套语义，说明 tile/distributed kernel 如何隐藏 queue、completion、ownership 和 backpressure 成本 |
| p.3–4 术语表、p.2 目录 | Connection/Tunnel/Path、Move/Transaction/Fragment、DMA Context、Aperture、Retirement、Fence、Aggregation Engine 等候选语言 | 本场将其作为前序架构语言的 recall 和对照维度；Slide 26–33、52–62 与 Backup T2 从具体数据路径验证其边界 |

联讲时可以压缩的是链路握手、credit/replay、HOL/VC、基础 SQ/CQ 和 Ethernet 分层。不能压缩的是：一个 packet 与一个 application transaction 的区别、乱序数据如何直接放置、完成到底向谁承诺、可靠状态放在哪里、软件 transport 如何工作，以及 tile/distributed-kernel 接口隐藏了哪些有限资源。

## 术语表的精确口径

以下名词是前序讲者的候选架构对象，不是当前 RDMA、UET、Falcon、UCCL、SUE 或 UALink 的通用标准术语：

| 前序术语 | 本场采用的精确定义与边界 |
|---|---|
| `Management Domain` | p.3 术语表中指一个 OS 最终裁决资源的范围；不是 consistency domain。p.43 正文又使用了更偏共享内存状态范围的 `Domain`，两种口径不能自动合并 |
| `Software Connection` | 两端的 mapping + ACL 管理关系；不绑定 tunnel 或 path |
| `Reliable Tunnel` | NIC 内共享的 packet-reliability resource；不是封装隧道，也不承载 transaction semantics |
| `Physical Path` | packet 实际经过的路线，可随 tunnel 映射改变 |
| `Move` | 可很大的完整搬运任务，由 DMA 拆分；本身没有一个单一 completion 语义 |
| `Bounded Transaction` | 有稳定身份、有限大小、一次 retirement 的工作单元；不是数据库原子事务 |
| `Transaction Fragment` | 自描述、幂等、可独立放置的逻辑片段 |
| `Incarnation` | 某个 fragment 的一次实际传输；换 tunnel 重传会产生新的 incarnation |
| `DMA Context` | per-PASID 的调度、语义、源数据义务和 retirement 状态；不能直接等同 QP |
| `Aperture` | 远端资源映射到本地地址空间的 window，home 在 NIC；映射不自动赋予本地 cache/coherence/failure semantics |
| `Local Retirement` | sender 收齐所有 fragment ACK 并解除 source obligation；不表示远端 consumer 已经可见或执行 |
| `Terminal Result` | success、definite rejection 或 unknown transport failure；timeout 本身不是结果 |
| `Send Fence` | 只约束后继 transaction 何时可进入网络；不保证 arrival/execution/completion order |
| `Execute Fence` | 只约束目标端后继 transaction 的执行资格；不把多 packet 操作变成原子提交 |
| `Aggregation Engine` | 占用地址空间的 endpoint；不是 switch functionality 的同义词 |

UET 的 PDC/CCC、Falcon connection/subflow、UCCL logical connection/QP pool、RDMA QP 和 compute tile 可以拿来检验这套语言是否有解释力，但不能反向声称这些系统采用了同一对象模型。

## 必须保留的科学边界

1. p.19 的 lossless/lossy 是教学化分类。`拥塞时是否主动丢包`、`链路是否 replay`、`端到端是否可靠` 和 `应用是否可恢复` 是四个不同问题。
2. p.38 的 Orderlock 结论只在 Jiang et al. 论文模型中成立：in-order delivery、lossless transmission 与 out-of-order capability 同时存在，是该类 Orderlock 的必要充分条件；不能泛化为所有无损乱序网络都会死锁。
3. p.44 的 NVL72 `Domain` 是架构案例，不证明 management domain、coherence/consistency domain、scale-up domain 与 failure domain 天然相同。
4. p.47 所说同步“不能隐藏”，应理解为真实依赖不能被违反；同步延迟仍可能与不依赖的数据搬运或计算重叠。overlap 隐藏时间，不消灭依赖。
5. p.48 的 prior/posterior 以及 polling/interrupt 是帮助理解状态观察的类比，不是对所有 I/O 机制的完备分类。
6. p.50 把 host 写 doorbell 描述成对设备的“中断”。在常见 verbs/RNIC 路径中，通知设备通常是对 doorbell register 的 MMIO write，有些实现还配合 host-memory doorbell record；这不是 CPU-style interrupt。设备向 CPU 报告完成时才可能使用 interrupt，也可能由软件 polling CQ。
7. p.52 的 packet “atomic”只可理解为 framing/forwarding unit 不被中途拆成两个独立 packet 语义，不等于 application transaction atomicity、exactly-once 或多 packet commit。
8. p.53–54 对 Ethernet/L2 forwarding 的描述是入门启发式。实际广播域、VLAN、overlay、LAG/ECMP、控制平面和厂商 pipeline 不能由几条简化规则完全概括。
9. 把 remote resource 放进 address space，不会自动获得 local memory semantics。仍需定义 protection、generation/revocation、partial completion、unknown result、endpoint reset、memory scope 和一致性边界。

## 建议开场衔接

建议用 90–120 秒：

> 上一场从 VALID/READY、credit、replay 和 router queue 出发，解释了长距离传输为什么会出现缓冲、流控、乱序、死锁与恢复问题，也用 Domain、SQ/CQ 和 Ethernet/TCP 建立了设备与网络的基础坐标系；新版后半段还初步提出了网络分层、multi-plane、Tile、Descriptor、Barrier、Commit 和 Unified System。我们这一场不重复定义这些抽象，而是跟踪一个 GPU A 到 GPU B 的 tensor chunk，把它们放回 RDMA、MRC、MoE、KV 和 distributed-kernel 的真实数据路径；再用公开标准、论文和实现检查每个对象到底隐藏了什么、又由谁承担成本。

这段衔接保持两场主线一致，同时不会让听众把前序的架构语言误认为已经标准化或已经被某个产品完整采用。
