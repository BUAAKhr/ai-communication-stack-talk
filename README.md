# AI Communication Stack: From One Tensor to the Whole System

一份从零基础出发、面向 AI 系统与高性能通信的技术 talk。整场反复跟踪同一个场景：GPU A 已产生一个 tensor chunk，GPU B 必须等它安全可见后才能继续。听众会从一个 API 调用一路追到算法分块、CPU/GPU progress、memory movement、RNIC、transport、switch queue、link protection、目标放置、completion 与恢复。

这里的“透明”只表示调用者不必显式管理，不表示工作和成本消失。讲稿要求每一层都回答：数据在哪、谁发起、谁推进、隐藏了什么状态、会卡在哪、上层看到什么症状、用什么证据能证明。正文给出可独立阅读的事件链和因果关系；讲师说明再用统一的 32 KiB tensor chunk 演算性能瓶颈、错误边界与取证方法。

## 内容

- 72 页主讲内容，独立讲授约 148 分钟；紧接前序演讲时建议压缩为约 136 分钟。
- 一个统一的端到端性能模型：source readiness、launch/progress、staging、queueing、serialization、placement、completion、consumer wait、recovery 与 overlap。
- 一张 13 层透明性阶梯，用来定位 `all_reduce()`、P2P、MoE dispatch、distributed kernel 和 KV movement 下方的隐藏工作。
- 一张 API 入口到隐藏层次的映射：PyTorch collective、NCCL、RDMA verbs 与 device-side put/store 分别站在哪一层之上。
- 三条可逐事件跟踪的数据路径：scale-up fabric、GPUDirect/RNIC/PCIe，以及 host-memory staging fallback。
- 一套固定取证方法：依赖与 bytes、物理位置、五类执行角色、四条逻辑路径、服务率与队列、timeline/counter/P99。
- AI server 内的 PCIe、NVLink/NVSwitch、xGMI、HCCS 与 NUMA。
- Blackwell 双 Die 的官方事实，以及不能从 MCM-GPU 论文反推的产品细节。
- Scale-Up 与 Scale-Out 的语义、RTT、故障域和可靠性状态。
- RDMA、DDP、multipath、out-of-order placement、SACK、拥塞控制和 BDP。
- UCCL：基于现有 RDMA verbs 的 host-CPU software transport，以及它与 Falcon、UEC 的层次差异。
- MPI/NCCL 的 progress 与 collective schedule，以及 CPU initiated、GPU initiated、NIC/DPU offload 的责任边界。
- P2P object lifecycle、NCCL EP、DeepEP、MoE dispatch/combine、expert skew 与 incast。
- compute-communication overlap、异步数据搬运、distributed kernel。
- DeepGEMM MegaMoE 的真实 dataflow，以及与 FlashInfer CuTeDSL MegaMoE、FlashMoE 的边界。
- KV cache、Mooncake、DualPath、HiSparse 与 context-memory tier。

## 阅读入口

- [完整逐页讲稿](TALK.md)
- [参考资料](REFERENCES.md)
- [科学性审校说明](SCIENTIFIC-NOTES.md)
- [前序演讲对齐说明](PREDECESSOR-ALIGNMENT.md)

## 证据约定

- `[A]`：官方规范、官方文档或正式论文。
- `[B]`：官方开源仓库、项目文档或固定版本的实现证据。
- `[C]`：厂商公开预告或披露仍不完整的快速演进能力。

产品事实、学术方案和基于公开材料的推断在讲稿中分开表达。开源实现尽量固定到 commit，避免项目后续演进改变原始语义。

本稿还与前序演讲《Towards Modern Networking System》更新版 56 页 PDF 完成逐页对齐。该版本实际展开了 VALID/READY、credit/replay、router/VC、Orderlock、Domain、SQ/CQ 与 Ethernet/TCP 基础；Connection/Tunnel/Path、Bounded Transaction、Fence 和 Tile-based Computing 只出现在术语表或目录预告中。因此本稿会压缩 recall 已讲过的链路/路由基础，但从零讲授后续语义、transport state placement 和 distributed-kernel 接口。源 PDF 未收入本公开仓库；版本哈希和详细边界见 [前序演讲对齐说明](PREDECESSOR-ALIGNMENT.md)。

## 校验

在 PowerShell 中运行：

```powershell
./scripts/validate.ps1
```

校验包括 72 页编号连续性、引用闭包、重复引用定义和残留占位词。

## 特别鸣谢

特别感谢微信公众号 **zartbot** 长期整理 GPU 多 Die、缓存一致性、RDMA、Scale-Up/Scale-Out 与可靠传输相关资料。本稿在确定问题脉络和扩展阅读范围时重点参考了：

- 《英伟达 GB200 架构解析 4：BlackWell 多 die 和 Cache 一致性相关的分析》
- 《谈谈 RDMA 和 ScaleUP 的可靠传输》

具体事实和数字仍尽量回溯至官方文档、标准、论文与固定版本的开源仓库。

## 使用说明

本仓库当前公开用于阅读、讨论和提交勘误。尚未附加开放许可证，因此默认版权规则适用；如需再分发、改编或用于商业培训，请先取得作者许可。
