# AI Communication Stack: From One Tensor to the Whole System

前导从 Tensor Core 的 `WMMA → MMA → WGMMA → tcgen05` 演进开始：计算吞吐提高后，持续供数、异步 completion 和细粒度依赖更容易进入关键路径。单 GPU 内的 `Producer → Data Movement → Completion → Consumer` 数据流，随后扩展到 GPU、NIC 和交换机之间的跨设备通信。该前导不增加 88 页编号。


一份从零基础出发、面向 AI 系统与高性能通信的技术 talk。整场反复跟踪同一个场景：GPU A 已产生一个 tensor chunk，GPU B 必须等它安全可见后才能继续。听众会从一个 API 调用一路追到算法分块、CPU/GPU progress、memory movement、RNIC、transport、switch queue、link protection、目标放置、completion 与恢复。

这里的“透明”只表示调用者不必显式管理，不表示工作和成本消失。讲稿要求每一层都回答：数据在哪、谁发起、谁推进、隐藏了什么状态、会卡在哪、上层看到什么症状、用什么证据能证明。正文给出可独立阅读的事件链和因果关系；讲师说明再用统一的 32 KiB tensor chunk 演算性能瓶颈、错误边界与取证方法。

## 核心问题与主线

> **当一个 Tensor Chunk 从 GPU A 发往 GPU B 时，它实际走过什么路径？GPU B 在什么条件下才真正获得消费它的资格？**
>
> 为了让这个 Chunk 在依赖满足后，以正确的顺序写入正确的位置，并对消费 kernel 可见，通信栈必须维护哪些状态、执行哪些协议？这些责任由哪一层承担，系统设计者又必须在哪些边界上做出取舍？

| Topic | Slides | 简介 |
|---|---:|---|
| 1. 什么才叫可消费？ | 1–8 | 用 Delivery、Placement、Completion、Visibility 与 Ordering 建立正确性坐标系。 |
| 2. 数据跨过哪些边界？ | 9–21 | 沿 HBM、GPU fabric、PCIe、NIC、RDMA 与交换机画出真实数据路径和故障边界。 |
| 3. 状态与控制由谁维护？ | 22–38 | 比较 runtime、host software、NIC/transport 与 fabric 如何负责可靠性、顺序、拥塞、progress 和恢复。 |
| 4. Workload 如何把流量变成等待？ | 39–69 | 用 collective、P2P/KV、MoE、overlap 与 distributed kernel 解释 traffic 如何形成 wait-for graph。 |
| 5. 哪些开销会在 scale 下进入 Critical Path？ | 70–78 | 用 MRC 与 Meta 100K+ GPU 案例分析启动、稳态资源、尾延迟及故障恢复成本。 |
| 6. 重新划分边界后会怎样？ | 79–87 | 用 Cerebras、Groq、HBF、PNM、3D stacking 与 NetDAM 检查责任是消失、转移还是复制。 |

最终收束为：`可消费语义 → 数据边界 → 状态归属 → 流量与等待 → scale 下的 critical path → 重画系统边界`。

## 内容

- 88 页主讲内容，独立讲授约 186 分钟；紧接前序演讲时建议压缩为约 170–180 分钟。
- 一个统一的端到端性能模型：source readiness、launch/progress、staging、queueing、serialization、placement、completion、consumer wait、recovery 与 overlap。
- 一张 13 层透明性阶梯，用来定位 `all_reduce()`、P2P、MoE dispatch、distributed kernel 和 KV movement 下方的隐藏工作。
- 一张 API 入口到隐藏层次的映射：PyTorch collective、NCCL、RDMA verbs 与 device-side put/store 分别站在哪一层之上。
- 三条可逐事件跟踪的数据路径：scale-up fabric、GPUDirect/RNIC/PCIe，以及 host-memory staging fallback。
- 一套固定取证方法：依赖与 bytes、物理位置、五类执行角色、四条逻辑路径、服务率与队列、timeline/counter/P99。
- AI server 内的 PCIe、NVLink/NVSwitch、xGMI、HCCS 与 NUMA。
- Blackwell 双 Die 的官方事实，以及不能从 MCM-GPU 论文反推的产品细节。
- Scale-Up 与 Scale-Out 的语义、RTT、故障域和可靠性状态。
- RDMA、DDP、multipath、out-of-order placement、SACK、拥塞控制和 BDP。
- MRC：RC-compatible AI transport 的多路径、选择性恢复、ECN/路径健康、生产故障与受控丢包案例，并明确其 WRITE/WRITE_IMM 语义子集和 endpoint 故障边界。
- UCCL：基于现有 RDMA verbs 的 host-CPU software transport，以及它与 Falcon、UEC 的层次差异。
- MPI/NCCL 的 progress 与 collective schedule，以及 CPU initiated、GPU initiated、NIC/DPU offload 的责任边界。
- P2P object lifecycle、NCCL EP、DeepEP、MoE dispatch/combine、expert skew 与 incast。
- compute-communication overlap、异步数据搬运、distributed kernel。
- DeepGEMM MegaMoE 的真实 dataflow，以及与 FlashInfer CuTeDSL MegaMoE、FlashMoE 的边界。
- KV cache、Mooncake、DualPath、HiSparse 与 context-memory tier。
- SIGCOMM 2026 的 100K+ GPU 生产通信栈：CCLX 初始化/HBM 管理、DQPLB 的 BDP 感知流控、Fault Analyzer、PerfProfiler 与 CPU emulation。
- 推理硬件专题：Cerebras CS-4、Groq 设计空间、HBF、PNM、3D memory–logic stacking、低延迟互联与 NetDAM。

## 阅读入口

- [完整逐页讲稿](TALK.md)
- [参考资料](REFERENCES.md)
- [科学性审校说明](SCIENTIFIC-NOTES.md)
- [前序演讲对齐说明](PREDECESSOR-ALIGNMENT.md)

## 证据约定

- `[A]`：官方规范、官方文档或正式论文。
- `[B]`：官方开源仓库、项目文档或固定版本的实现证据。
- `[C]`：快速演进的公开材料、厂商预告或用户提供的二手分析；不作为一手规范。

产品事实、学术方案和基于公开材料的推断在讲稿中分开表达。开源实现尽量固定到 commit，避免项目后续演进改变原始语义。

本稿与用户提供的前序演讲《Towards Modern Networking System》79 页 PDF 对齐：新版已展开 VALID/READY、credit/replay、router/VC、Orderlock、Domain、SQ/CQ、Ethernet/TCP，以及后半段的网络分层、multi-plane、Tile-based Computing、Descriptor、Barrier、Commit、Wait 和 Unified System。因而本场不再声称这些内容“尚未讲授”，而是把前序抽象放回 GPU tensor、RDMA、MRC、MoE、KV 和 distributed-kernel 的具体数据路径中，检查它们在公开标准与实现中的边界。源 PDF 未收入本公开仓库；页数、SHA-256 和详细章节映射见 [前序演讲对齐说明](PREDECESSOR-ALIGNMENT.md)。

## 校验

在 PowerShell 中运行：

```powershell
./scripts/validate.ps1
```

校验包括 88 页编号连续性、引用闭包、重复引用定义和残留占位词。

## 特别鸣谢

特别感谢微信公众号 **zartbot** 长期整理 GPU 多 Die、缓存一致性、RDMA、Scale-Up/Scale-Out 与可靠传输相关资料。本稿在确定问题脉络和扩展阅读范围时重点参考了：

- 《英伟达 GB200 架构解析 4：BlackWell 多 die 和 Cache 一致性相关的分析》
- 《谈谈 RDMA 和 ScaleUP 的可靠传输》
- 《“漫”谈 RDMA 现代化》及《谈谈 OpenAI 发布的 MRC》（作为科普/评论性二手阅读，不作为科学证据）
- 《大语言模型推理硬件的挑战与研究方向》、SemiAnalysis 的 CS-4 文章摘录，以及用户提供的 SIGCOMM 2026 论文《Connecting 100K+ GPUs》共同扩展了推理硬件、100K+ GPU 通信栈与运维可观测性部分。

具体事实和数字仍尽量回溯至官方文档、标准、论文与固定版本的开源仓库。

## 使用说明

本仓库当前公开用于阅读、讨论和提交勘误。尚未附加开放许可证，因此默认版权规则适用；如需再分发、改编或用于商业培训，请先取得作者许可。
