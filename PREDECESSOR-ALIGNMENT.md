# 前序演讲对齐说明

审校日期：2026-08-14

## 输入材料与核验范围

本说明对照用户更新的 `Towards Modern Networking System(1).pdf`：

- 56 页，WPS 演示导出；标题页日期为 2026-08-15；
- SHA-256：`19C9AF2E0D78730D2D31297B9CF3EDD573BEFAF200D3ED33BAFEEDD208DEACA5`；
- 已提取全部页面文字，并将 56 页逐页渲染后完成视觉检查；
- 源 PDF 不收入公开仓库，只记录版本指纹和两场内容的边界。

需要先说明一个影响衔接方式的事实：第 2 页目录预告了 `Inside the Monolith` 和 `Beyond the Monolith`，第 3–4 页也给出了完整的候选对象词汇；但这份实际交付的 56 页 PDF 并没有展开目录中的 Connection/Tunnel/Path、Bounded Transaction、Aperture、Fence 和 Tile-based Computing 章节。实际正文在 Part I 的链路与路由基础之后，进入 Domain/SQ-CQ 例子以及 Ethernet/IP/TCP 入门。

因此，本场不能假设零基础听众已经学会前序目录预告的对象模型。正确的处理是：已经展开的 link/router/SQ-CQ/Ethernet 基础做简短 recall；只出现在术语表或目录中的内容，由本场从问题、语义、状态和实现代价开始完整讲授。

## 前序实际覆盖的内容

| 页码 | 已展开的内容 | 本场如何承接 |
|---|---|---|
| p.15–24 | VALID/READY、长连线与缓冲、credit、replay、lossless/lossy、数据损坏、PCIe link layer | Slide 10–12、22–25 快速回忆机制，再放入 GPU A→GPU B 的完整事件链 |
| p.27–41 | router、HOL、VC、FLIT、因果依赖、deadlock/Orderlock、InfiniBand、lossy router 问题 | Slide 25–31 继续讲 multipath、乱序放置、恢复、拥塞与状态位置 |
| p.43–44 | Domain/Connection 的引入和 NVL72 案例 | Slide 21–22、33–34 区分管理域、地址/一致性域、RTT/故障域和通信关系 |
| p.45–50 | 状态与计算、同步、prior/posterior 类比、audio timer 例子、SQ/CQ 生命周期 | Slide 4–8、15–16、34–37 用真实 tensor transfer 明确 initiator、progress、doorbell、completion 和 consumer wait |
| p.51–56 | Ethernet、IP、ARP、TCP 的入门层次 | 本场不重讲通用协议栈，直接进入 RDMA/AI transport 特有的 placement、ordering、multipath 和 recovery |
| p.3–4 术语表、p.2 目录 | Connection/Tunnel/Path、Move/Transaction/Fragment、DMA Context、Aperture、Retirement、Fence、Aggregation Engine；Tile 章节预告 | 仅作为前序讲者提出的架构语言；Slide 26–33、52–62 和 Backup T2 从零解释并与公开协议/实现逐一对照 |

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

> 上一场从 VALID/READY、credit、replay 和 router queue 出发，解释了长距离传输为什么会出现缓冲、流控、乱序、死锁与恢复问题，也用 Domain、SQ/CQ 和 Ethernet/TCP 建立了设备与网络的基础坐标系。它在术语表和目录里进一步提出了 Connection/Tunnel/Path、Bounded Transaction、Aperture、Fence 与 Tile 的候选语言，但这份 PDF 没有展开这些章节。我们这一场会先跟踪一个 GPU A 到 GPU B 的 tensor chunk，把已经讲过的链路与路由机制放回真实数据路径；然后从零说明 multipath、placement、completion、transport-state placement、UCCL/Falcon/UET，以及 tile 和 distributed kernel 到底隐藏了什么、又由谁承担成本。

这段衔接保持两场主线一致，同时不会让听众把“目录中的未来设计”误认为已经讲完、已经标准化或已经被某个产品采用。
