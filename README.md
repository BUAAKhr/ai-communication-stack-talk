# AI Communication Stack: From Workload to Dataflow

一份面向 AI 系统、GPU/加速器和高性能网络工程师的通信技术 talk。内容不是按设备罗列，而是沿着一条端到端数据流展开：模型为什么产生通信，数据穿过哪些物理边界，fabric 必须提供什么语义，谁实际搬运数据，以及如何缩短关键路径。

## 内容

- 72 页主讲内容，建议时长约 130 分钟。
- AI server 内的 PCIe、NVLink/NVSwitch、xGMI、HCCS 与 NUMA。
- Blackwell 双 Die 的官方事实，以及不能从 MCM-GPU 论文反推的产品细节。
- Scale-Up 与 Scale-Out 的语义、RTT、故障域和可靠性状态。
- RDMA、DDP、multipath、out-of-order placement、SACK、拥塞控制和 BDP。
- UCCL：基于现有 RDMA verbs 的 host-CPU software transport，以及它与 Falcon、UEC 的层次差异。
- MPI、NCCL、NCCL EP、DeepEP、P2P、KV movement 与 MoE 通信。
- compute-communication overlap、异步数据搬运、distributed kernel。
- DeepGEMM MegaMoE 的真实 dataflow，以及与 FlashInfer CuTeDSL MegaMoE、FlashMoE 的边界。
- KV cache、Mooncake、DualPath、HiSparse 与 context-memory tier。

## 阅读入口

- [完整逐页讲稿](TALK.md)
- [参考资料](REFERENCES.md)
- [科学性审校说明](SCIENTIFIC-NOTES.md)

## 证据约定

- `[A]`：官方规范、官方文档或正式论文。
- `[B]`：官方开源仓库、项目文档或固定版本的实现证据。
- `[C]`：厂商公开预告或披露仍不完整的快速演进能力。

产品事实、学术方案和基于公开材料的推断在讲稿中分开表达。开源实现尽量固定到 commit，避免项目后续演进改变原始语义。

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
