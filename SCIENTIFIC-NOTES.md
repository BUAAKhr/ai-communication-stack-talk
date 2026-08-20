# 科学性审校说明

本稿于 2026-08-21 完成零基础叙事重写、MRC case study、100K+ GPU 通信栈案例、推理硬件专题及新版前序讲座对齐后的公开资料复核。审校目标不是证明所有未来产品细节，而是让每个结论落在正确的证据层级，并显式保留公开资料的边界。

## 已修正的关键问题

1. Blackwell 只采用 NVIDIA 官方可确认的三个事实：两个 reticle-limited dies、10 TB/s chip-to-chip interconnect、single unified GPU。不由此推出所有路径等距、完整 cache coherence、具体跨 Die 延迟或 CTA 调度实现。
2. MCM-GPU、CARVE、HMG、PROACT 和 FinePack 全部标为研究方案，不画进 GB200 产品框图。
3. cache coherence、memory consistency/scope、NUMA locality 与 flush/invalidation mechanism 分开使用。
4. lossless、link-level replay、end-to-end reliable transport 与 runtime recovery 分层讨论。
5. RFC 5041 中 Tagged Buffer 的 `STag + Tagged Offset` 与 Untagged Buffer 的 `Queue Number + MSN + Message Offset` 分开描述；DDP 不直接等同于任意乱序 transport。
6. rate、window、credit 和 telemetry 被视作不同设计轴，不给出“某一种永远更好”的绝对结论。
7. UALink、SUE/SUE Lite 和 UET 被放在各自目标层次中，不作为同层跑分表。
8. EFA、NeuronLink 和 accelerator fabric 分层，避免把节点间适配器与节点内互联端点混为一类。
9. DeepGEMM MegaMoE 与 FlashInfer CuTeDSL MegaMoE、FlashMoE 分开。DeepGEMM dataflow 固定为 dispatch/pull、Linear1、SwiGLU 与重量化、Linear2、remote combine write、top-k reduction。
10. Rubin 能力明确标注公开预览状态；既有 grid-level PDL 从 `sm_90+` 开始，不称为 Blackwell 独占能力。
11. CloudMatrix384 采用华为官方口径：它是构建在 Atlas 900 A3 SuperPoD 上的云服务实例，后者最多包含 384 个 Ascend 910C。
12. 未找到足够一手资料确认 Ascend 950 CCU 内部微架构，因此只保留 dedicated collective engine 作为设计空间。
13. UCCL-Tran（OSDI 2026；公开预印本 arXiv:2504.17307v2）描述的是基于现有 RDMA primitives 的 host-CPU software transport：优先 UC，兼容路径包括受限条件下的 RC 和 UD；只有 UC/UD 路径把 packet reliability 放到软件，RC 仍保留 NIC hardware reliability。它不是新 NIC，也不是自动把 RoCE/InfiniBand wire protocol 变成 UET。
14. UCCL 的论文结果与实现细节受 testbed、NIC vendor、QP 数量、chunk size、CPU 预算和 collective shape 约束；4.5×、1.9× 及 EQDS tail-latency 数字不能外推为所有 GPU 集群的通用收益。
15. 当前 UCCL 开源仓库的范围已经扩展到 UCCL-Tran、UCCL-P2P 和 UCCL-EP。讲稿分别引用论文与固定仓库 commit，不把后来项目能力倒推成原论文结论。
15a. MRC 被作为生产 case study，而不是完整 RDMA 替代品：规范/论文支持 packet-level multipath、direct placement、SACK/selective retransmission、ECN、路径健康和可选 packet trimming；ECMP entropy 与 static SRv6 是两种路径方案。公开 transport 子集仅含 RDMA WRITE/WRITE-with-IMMEDIATE，不能推断 SEND/RECV、READ、ATOMIC 已支持。50K/75K-GPU 故障案例、64-GPU 受控丢包实验、约 770 Gb/s 和 5.09/6.54 μs 均标为论文特定部署/配置结果，不是普遍 SLA；论文报告的 NIC transceiver 全端口故障仍可能使 QP 失败。
15b. OCP MRC 1.0 的规范链接已记录为 [A42]，但本轮环境访问 OCP 下载端点时被 Cloudflare 拦截，未做逐条 clause 引用；MRC 功能和测量结论由可访问的 [A9]/[A10] 交叉核对。对外发布前应再用取得的规范副本核对 revision、字段和强制性措辞。
16. 已与前序演讲《Towards Modern Networking System》79 页 PDF 逐页对照并完成文字与视觉核验。其正文展开了 link/router、Orderlock、Domain、同步/SQ-CQ、Ethernet/TCP，以及 p.64–70 的网络分层、RC QP 耦合批评、multi-plane/SRv6 风格路径和 p.71–78 的 Tile/Descriptor/Barrier/Commit/Wait/Unified System。本场应把这些前序抽象放入具体 GPU tensor、RDMA、MRC、MoE、KV 和 distributed-kernel 数据路径，不再声称后半段“未展开”。
17. 前序第 3–4 页的 `Software Connection / Reliable Tunnel / Physical Path / DMA Context / Bounded Transaction` 仍被保留为讲者提出的候选对象，不与 RDMA QP/RC、UET PDC/CCC、Falcon connection、UCCL connection/chunk 或 compute tile 混用。新版后半段虽已把相关分层和 Tile 语义初步展开，仍不能据此声称它们是共同标准对象。`Reliable Tunnel` 是共享 packet-reliability resource，不是 encapsulation tunnel；`Bounded Transaction` 也不是数据库原子事务。
18. 已删除“前序第 50 页系统批评 RC QP”的错误归因：该页实际展示 SQ/CQ 生命周期。主讲对传统 QP 耦合的分析由 IRN、Falcon、UET、UCCL 等一手资料独立支持，并继续限定为常见设计模式；不同 RNIC/transport 已提供 SRQ、DC、adaptive routing、selective recovery 等扩展。
19. Tile/address-style programming 被解释为把 queue bookkeeping 移入 compiler/runtime/device engine；底层有限 queue、credit、translation/protection、retry、completion 和 backpressure 仍然存在。`32–128 KiB` 是设计建议，不是跨 workload/协议的固定最优范围。
20. 远端资源映射进入地址空间不等于自动获得本地 memory semantics；跨管理域仍需 capability、撤销/generation、partial completion、unknown result、endpoint reset、memory scope 与一致性边界。
21. Orderlock 使用原论文限定：在论文模型中，in-order delivery、lossless transmission 与 out-of-order capability 同时成立，是该类死锁的必要充分条件。
22. 前序 p.43–44 的 Domain/NVL72 是案例，不外推为 management domain、coherence/consistency domain、scale-up domain 与 failure domain 天然等价；离散 GPU/NIC 系统的 addressability、coherence、consistency scope、IOMMU/PASID 和 ownership 必须分别确认。
23. “不承诺伪 exactly-once”被限定为 transport 在不确定故障后不能单独判断远端应用动作；不否认带 durable deduplication、transaction/consensus 的上层系统在明确模型下提供 exactly-once effect。
24. 前序 p.45–50 的 synchronization、prior/posterior、audio timer 与 SQ/CQ 用作教学类比，不当成 I/O 机制的完备分类。真实依赖不能被违反，但其等待时间可与独立工作重叠；p.50 的 host doorbell 在常见 RNIC 路径中通常是对 device doorbell register 的 MMIO write（有时配合 host-memory doorbell record），不是 CPU-style interrupt。
25. 新增的端到端延迟分解式是诊断框架，不是假设各项严格独立或可直接线性测量；queueing、serialization、placement、completion 与 overlap 在真实流水中可能相互重叠。
26. `effective throughput ≤ min(...)` 是资源服务率的必要上界，用于提醒 source/destination memory、PCIe、NIC、fabric 和 consumer 都可能限速；它不替代 collective algorithm、duplex、协议开销和并发流的精确模型。
27. “一个 API 下有十三层”是教学分层，不是标准网络分层模型。层数用于显式追踪隐藏工作，不声称每个实现都存在十三个独立模块。
28. GPUDirect/peer DMA 被描述为 payload 可绕过 CPU DRAM，不等于 CPU 不参与注册、控制或 completion，也不保证所有平台都能避免 PCIe root/NUMA/IOMMU 限制；不支持时可能退回 staging。
29. sender-side CQE、transport ACK、remote memory placement 和 consumer-visible completion 被分开描述；任何具体 API 的完成语义仍须以其规范、memory ordering 和实现为准。
30. KV hierarchy 中的 host/remote/context tier 不被称为透明扩展 HBM。它们需要 object identity、placement、prefetch、publish、eviction 和 failure policy，且逐 token 同步访问通常不能直接按介质峰值带宽估算。
31. 新增的 `32 KiB ÷ 50 GB/s ≈ 0.66 μs` 只用于说明 raw serialization 的数量级。`50 GB/s` 是把 400 Gb/s 做单位换算后的理想上限，未扣除 framing、FEC、协议 header、idle gap 与 payload efficiency；真实端到端延迟必须继续加入 DMA、queue、placement、completion 等事件。
32. `initiator / progress engine / data mover / completion owner / recovery owner` 是责任归因框架，不声称每个实现都有五个独立硬件模块；同一 CPU、GPU kernel、RNIC 或 endpoint 可以同时承担多个角色。
33. “正文事件链 + 讲师演算 + 症状/证据”是教学组织方式，不把启发式诊断词汇当成标准接口或性能模型。具体 API 的完成、ordering、memory scope 与错误语义仍以对应规范和实现为准。
34. 前序的 `Local Retirement` 只表示 sender 收齐 fragment ACK 并解除 source-data obligation，不推出 remote placement、consumer visibility 或 target execution；sender CQE、transport ACK、remote placement 和 consumer-visible completion 继续分层。
35. 前序的 `Terminal Result` 分为 success、definite rejection 和 unknown transport failure；timeout 只是本地观察到等待超限，不自动证明远端未执行，也不应伪造确定失败结果。
36. `Send Fence` 只控制后继 transaction 何时进入网络，`Execute Fence` 只控制目标执行资格；两者都不自动提供 arrival order、completion order、multi-packet atomic commit 或 exactly-once effect。
37. 前序 p.52 的 packet “atomic”只按 framing/forwarding unit 理解，不提升为应用事务原子性；p.53–54 的 Ethernet/L2 规则是入门启发式，不覆盖 VLAN、overlay、LAG/ECMP、控制平面和具体 switch pipeline。
38. SIGCOMM 2026 的 100K+ GPU 案例使用论文 [A44] 作为生产部署和实验结果来源：100K+ GPU、跨 building 最高约 30× latency、CCLX 约 11× initialization improvement、约 2× communication HBM reduction、DQPLB buffering/throughput 数字都绑定论文的 fabric、rank、NIC、message shape 和对照实现。CCLX/NCCLX/RCCLX、CTran、DQPLB、Fault Analyzer、PerfProfiler 和 CPU emulation 的职责按论文描述区分，不能倒推为 NCCL、RDMA 或所有生产集群的通用行为。
39. DQPLB 的 `QP × segment × outstanding ≈ BDP` 是设计直觉，不是协议常数；多 QP 乱序需要 sequence/reorder state，降低 switch buffering 不等于在所有消息大小上提升 throughput。
40. CCLX 的 10 GB/80 GB H100、约 175 s restart budget、96K virtual-rank CPU emulation 和约 100× synchronization case 都是 [A44] 的配置或案例；CPU emulation 只保证 control-plane fidelity，不模拟 GPU data-plane performance。
41. 推理硬件章节使用 [A43] 讨论 HBF、PNM、3D stacking 和低延迟互联的研究方向，不把它们写成成熟产品或普遍优于 PIM 的结论。Prefill/decode 的 compute/memory-bound 分类是 workload tendency。
42. Cerebras CS-4 的 44 GB SRAM/wafer、43 PB/s aggregate SRAM bandwidth、2.4 Tb/s off-wafer I/O、2–3 μs path、125–135 kW rack 等来自用户提供的 SemiAnalysis 二手摘录 [C3]；这些是报道/特定配置口径，不能与 Rubin/HBM 或 CS-3 的不同 power baseline 直接比较。43 PB/s 也不能与外部 HBM 带宽做同口径比较。
43. Groq 页只保留公开材料支持的 compiler/static scheduling、spatial dataflow 和 SRAM-centric design-space 描述。[C4] 未确认的内部微架构、确切功耗、cycle-level determinism 和 3D stacking 均不作事实断言。
44. HBF 更适合低写入的冷权重/冷 context；热 KV 的写入压力、flash 页粒度、延迟、寿命和写放大仍需单独评估。PNM、3D stacking、low-latency interconnect 是研究/架构方向，不自动解决容量、热、接口标准或故障问题。
45. NetDAM [A39] 是 2021 FPGA/100GE 研究原型；其延迟/jitter 不能线性外推到 1 Tb/s 量产系统。network-attached memory 仍需 ownership、capability、ordering、completion、backpressure、security 和 failure recovery，不等于透明共享内存。

## 演讲时仍需限定

- 厂商带宽数字按原始产品口径引用，不擅自拆成单向/双向或 payload/aggregate。
- 开源项目性能只代表其明确硬件、shape、dtype、版本与测试环境；本稿未在本地 B200 复现 MegaMoE benchmark。
- ICMS/CMX、Rubin tile-level coordination、UltraEP 和 MoonEP 等快速演进内容不讲成稳定跨版本接口。
- BDP 公式用于估算 in-flight state 的数量级，不能直接反推芯片面积。
- 通过 I/O memory/DPU/communication appliance 放置可靠性边界是一种架构选择，不是已经统一的行业标准。
- UCCL 的软件控制面主要依赖 RTT/丢包等仍可见的信号；RNIC 已消费的 ECN、trim 或 vendor-specific telemetry 不会自动出现在用户态。CPU engine、host NUMA、polling、QP context 和 UD 重组开销必须纳入线速与尾延迟评估。
- 前序 p.3–4 的 connection/tunnel/path、transaction/fragment/incarnation、DMA context、aperture、retirement、fence 与 aggregation engine 是候选架构语言，不当作 UEC、SUE、UALink、Falcon、UCCL 或当前 RNIC 的共同对象模型。
- 前序 p.47 的同步、p.48 的 prior/posterior、p.50 的 SQ/CQ、p.52–59 的 Ethernet/TCP，以及 p.64–78 的网络分层与 Tile/Unified System 内容用于建立架构直觉；主讲中的完成语义、wire behavior 和量化结论仍回溯至标准、论文、官方文档和固定代码版本。
## 自动检查结果

- 主讲页：88 页，编号连续且无重复。
- 引用标签：引用使用项与定义项闭合，无悬空引用。
- 主要公式：Ring AllReduce 每 rank 传输量和两个 BDP 数量级示例已复核。
