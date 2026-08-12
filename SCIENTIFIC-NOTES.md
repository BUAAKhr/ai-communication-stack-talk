# 科学性审校说明

本稿于 2026-08-12 完成一轮公开资料审校。审校目标不是证明所有未来产品细节，而是让每个结论落在正确的证据层级，并显式保留公开资料的边界。

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
16. 已与前序演讲《Towards Modern Networking System》当前 PDF 的 42 页内容逐页对照。前序的 circuit/link/credit/replay/router/VC/HOL/Orderlock 作为本场前提；本场只承接到 AI workload、RDMA、Scale-Up/Scale-Out、UEC/Falcon/UCCL 和 distributed kernel。Orderlock 使用原论文限定：在论文模型中，in-order delivery、lossless transmission 与 out-of-order capability 同时成立，是该类死锁的必要充分条件。

## 演讲时仍需限定

- 厂商带宽数字按原始产品口径引用，不擅自拆成单向/双向或 payload/aggregate。
- 开源项目性能只代表其明确硬件、shape、dtype、版本与测试环境；本稿未在本地 B200 复现 MegaMoE benchmark。
- ICMS/CMX、Rubin tile-level coordination、UltraEP 和 MoonEP 等快速演进内容不讲成稳定跨版本接口。
- BDP 公式用于估算 in-flight state 的数量级，不能直接反推芯片面积。
- 通过 I/O memory/DPU/communication appliance 放置可靠性边界是一种架构选择，不是已经统一的行业标准。
- UCCL 的软件控制面主要依赖 RTT/丢包等仍可见的信号；RNIC 已消费的 ECN、trim 或 vendor-specific telemetry 不会自动出现在用户态。CPU engine、host NUMA、polling、QP context 和 UD 重组开销必须纳入线速与尾延迟评估。
- 前序 PDF 当前只包含到 Part I 的 1.3 标题页；目录列出的 management-domain 后续正文、NIC microarchitecture 和 tile-based transaction 部分没有出现在该文件中。对这些未交付页面不宣称完成逐页冲突核验；只根据术语表预先隔离 `Software Connection`、`Reliable Tunnel`、`Bounded Transaction` 与 RDMA/UCCL/compute tile 的同名异义。
## 自动检查结果

- 主讲页：72 页，编号连续且无重复。
- 引用标签：58 个使用项与 58 个定义项闭合，无悬空引用。
- 主要公式：Ring AllReduce 每 rank 传输量和两个 BDP 数量级示例已复核。
