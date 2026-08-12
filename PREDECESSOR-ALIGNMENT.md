# 前序演讲对齐说明

审校日期：2026-08-12

## 输入材料

本说明对照用户提供的 `Towards Modern Networking System.pdf`。PDF 共 42 页，正文包含：

- circuit/link：VALID/READY、credit、link replay、lossless/lossy 与 failure/rot 的区分；
- network：router、arbiter、crossbar、HOL blocking、virtual channel、deadlock/livelock；
- 协议案例：PCIe link layer 与 InfiniBand；
- 第 42 页进入 `1.3 From Connectivity to Management` 的 Scale-Up/Scale-Out 标题页。

目录中列出的 management-domain 后续正文、NIC microarchitecture 和 tile-based transaction 部分没有出现在这份 PDF 中，因此本说明不声称已经审阅这些未交付页面。

## 与本场的衔接

| 前序内容 | 本场承接位置 | 承接方式 |
|---|---|---|
| p.19–22：credit/backpressure、ACK/NAK/retry、lossless/lossy、failure/rot | Slide 21、24–25、Backup T1 | 从 overflow 策略继续拆成 FEC、LLR、flow control、端到端 retry 和 runtime recovery |
| p.23–24：PCIe credit + replay、Go-Back-N、cut-through/nullify | Slide 24、32、Backup T1 | 作为逐跳保护和 replay buffer 的直观案例，不把 PCIe 机制外推成所有 RDMA/Scale-Up 协议 |
| p.27–30：router、HOL blocking、VC | 开场衔接、Slide 25、30 | 不重复推导交换机基础，直接讨论 AI 流量的多路径、队列和拥塞代价 |
| p.36–38：causation、deadlock、Orderlock | Slide 23、26、Backup T1 | 把 completion、fence、乱序持有和有界 buffer 放入 RDMA/UEC/Falcon/UCCL 语境 |
| p.39–41：InfiniBand 的 link credit + endpoint replay，以及 lossy fabric router 问题 | Slide 21、25–31、Backup T5 | 进入 IRN、UEC、Falcon、UCCL 和 selective recovery |

## 未发现的冲突

1. 本场把 `lossless` 和 `reliable` 分层处理，与前序对 overflow 策略和故障恢复的区分一致。
2. 本场没有把多路径乱序说成“天然免费”：仍要求 placement identity、gap/duplicate tracking、completion 和 ordering/fence。
3. 本场没有把 DDP、UEC、Falcon 或 UCCL 混成同一个协议。UCCL 是现有 RNIC 上的 host-CPU software transport；Falcon 更接近硬件/SmartNIC transport；UEC 是 wire-level specification。
4. 本场的 `RDMA message`、`UCCL chunk`、通信 tile 和 GEMM tile 不等同于前序术语表中的 `Bounded Transaction`。
5. 前序的 `Management Domain` 是一个 OS 的最终裁决范围；本场的 scale-up/scale-out domain 主要按 RTT、拓扑、语义和故障预算划分。二者可以重合，但不是同一个定义。
6. 前序的 `Aggregation Engine` 是其架构中占用地址空间的端点；SHARP 是 switch/fabric reduction placement，不能只因都执行聚合就视为同一种对象。

## Orderlock 的精确口径

前序第 38 页的三元组来自 Jiang et al., *Orderlock*（SIGCOMM 2025）。原论文的限定是：在其模型中，`in-order delivery`、`lossless transmission` 与 `out-of-order capability` 同时成立，是该类 Orderlock 死锁的必要充分条件。本场只用这个限定结论，不说成“任何乱序和无损组合都会死锁”。

因此 Slide 26 的 direct placement 只解决“乱序数据写到哪里”的问题；它不取消 completion、fence、buffer 上限，也不自动消除 Orderlock 风险。

## 演讲开场建议

用 60–90 秒说明：前序已经从 wire、credit、replay 和 router 推导出可靠链路与网络的基本机制；本场向上承接到 AI workload，回答这些机制如何影响 RDMA transport、Scale-Up/Scale-Out、collective、EP、distributed kernel 和 KV movement。
