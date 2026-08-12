# 参考资料

资料核对日期：2026-08-12。引用编号与 [TALK.md](TALK.md) 保持一致。

证据等级：

- `[A]`：官方规范、官方文档或正式论文。
- `[B]`：官方开源仓库、项目文档或固定版本的实现证据。
- `[C]`：厂商公开预告或披露仍不完整的快速演进能力。

## 官方架构、产品与软件文档

- [A1] NVIDIA, [NVLink and NVSwitch](https://www.nvidia.com/en-us/data-center/nvlink/).
- [A2] NVIDIA, [DGX platform documentation](https://docs.nvidia.com/dgx/).
- [A3] AMD ROCm, [AMD Instinct MI300 Series microarchitecture](https://rocm.docs.amd.com/en/latest/reference/gpu-arch/mi300.html), including MI300 package and eight-GPU node-level Infinity Fabric topology.
- [A4] Huawei, [Groundbreaking SuperPoD Interconnect: Leading a New Paradigm for AI Infrastructure](https://www.huawei.com/en/news/2025/9/hc-xu-keynote-speech), 2025-09-18.
- [A5] NVIDIA, [Networking documentation](https://docs.nvidia.com/networking/).
- [A6] NVIDIA, [DOCA documentation](https://docs.nvidia.com/doca/).
- [A7] AWS, [Elastic Fabric Adapter](https://aws.amazon.com/hpc/efa/).
- [A8] AWS, [Neuron documentation](https://awsdocs-neuron.readthedocs-hosted.com/).
- [A9] OpenAI, [Supercomputer networking to accelerate large scale AI training](https://openai.com/index/mrc-supercomputer-networking/), 2026-05-05.
- [A11] NVIDIA, [NCCL documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/).
- [A12] Google Cloud, [TPU system architecture](https://cloud.google.com/tpu/docs/system-architecture-tpu-vm).
- [A13] UALink Consortium, [Specifications and news](https://ualinkconsortium.org/).
- [A14] NVIDIA, [SHARP documentation](https://docs.nvidia.com/networking/display/sharpv320).
- [A15] NVIDIA, [NCCL User Guide](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/).
- [A19] NVIDIA, [Inside NVIDIA Rubin GPU Architecture: Powering the Era of Agentic AI](https://developer.nvidia.com/blog/inside-nvidia-rubin-gpu-architecture-powering-the-era-of-agentic-ai/), 2026-07-21.
- [A20] NVIDIA, [PTX ISA 9.4, CUDA 13.4 Developer Preview](https://docs.nvidia.com/cuda/developer-preview/13.4/parallel-thread-execution/index.html).
- [A21] NVIDIA, [CUDA Programming Guide: Programmatic Dependent Launch and Synchronization](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/programmatic-dependent-launch.html).
- [A22] NVIDIA, [CUDA Toolkit 13.4 Developer Preview Release Notes](https://docs.nvidia.com/cuda/developer-preview/13.4/cuda-toolkit-release-notes/index.html).
- [A23] NVIDIA, [Blackwell Architecture](https://www.nvidia.com/en-us/data-center/technologies/blackwell-architecture.md) and [Blackwell platform announcement](https://nvidianews.nvidia.com/news/nvidia-blackwell-platform-arrives-to-power-a-new-era-of-computing). The quoted product wording is “two reticle-limited dies connected by a 10 terabytes per second (TB/s) chip-to-chip interconnect in a unified single GPU.”
- [A35] NVIDIA, [ConnectX-8 SuperNIC User Manual: Introduction](https://networking-docs.nvidia.com/connectx8hw/introduction).
- [A36] NVIDIA, [DOCA DPA Development](https://networking-docs.nvidia.com/doca/archive/3-4-0/dpa-development), including programmable congestion-control events.

## Standards and Specifications

- [A30] IETF RFC 5041, [Direct Data Placement over Reliable Transports](https://www.rfc-editor.org/rfc/rfc5041.html), October 2007.
- [A32] Ultra Ethernet Consortium, [Ultra Ethernet Specification 1.0](https://ultraethernet.org/wp-content/uploads/sites/20/2025/06/UE-Specification-6.11.25.pdf), June 2025.
- [A33] UALink Consortium, [UALink 200G Specification Rev 1.0, Evaluation Copy](https://ualinkconsortium.org/wp-content/uploads/2025/04/UALink200_Specification_v1.0_Evaluation_Copy.pdf), April 2025.
- [A34] Broadcom, [Scale-Up Ethernet Framework Specification](https://docs.broadcom.com/docs/scale-up-ethernet-framework), Scale-Ethernet-RM104, 2025-09-26.
- [A38] MPI Forum, [MPI: A Message-Passing Interface Standard, Version 4.1](https://www.mpi-forum.org/docs/mpi-4.1/mpi41-report.pdf), November 2023.

## Papers

- [A10] *Resilient AI Supercomputer Networking using MRC and static SRv6*, [arXiv:2605.04333](https://arxiv.org/abs/2605.04333).
- [A16] *Mooncake: A KVCache-centric Disaggregated Architecture for LLM Serving*, FAST 2025, [arXiv:2407.00079](https://arxiv.org/abs/2407.00079).
- [A17] *DualPath: Breaking the Storage Bandwidth Bottleneck in Agentic LLM Inference*, [arXiv:2602.21548](https://arxiv.org/abs/2602.21548).
- [A18] Zheng et al., *TileLink: Generating Efficient Compute-Communication Overlapping Kernels using Tile-Centric Primitives*, MLSys 2025, [arXiv:2503.20313](https://arxiv.org/abs/2503.20313).
- [A24] Arunkumar et al., [MCM-GPU: Multi-Chip-Module GPUs for Continued Performance Scalability](https://research.nvidia.com/publication/2017-06_mcm-gpu-multi-chip-module-gpus-continued-performance-scalability), ISCA 2017, DOI 10.1145/3079856.3080231.
- [A25] Young et al., [Combining HW/SW Mechanisms to Improve NUMA Performance of Multi-GPU Systems](https://research.nvidia.com/publication/2018-10_combining-hwsw-mechanisms-improve-numa-performance-multi-gpu-systems), MICRO 2018, DOI 10.1109/MICRO.2018.00035.
- [A26] Ren et al., [HMG: Extending Cache Coherence Protocols Across Modern Hierarchical Multi-GPU Systems](https://research.nvidia.com/publication/2020-02_hmg-extending-cache-coherence-protocols-across-modern-hierarchical-multi-gpu), HPCA 2020.
- [A27] Muthukrishnan et al., [Efficient Multi-GPU Shared Memory via Automatic Optimization of Fine-Grained Transfers](https://research.nvidia.com/publication/2021-06_efficient-multi-gpu-shared-memory-automatic-optimization-fine-grained-transfers), ISCA 2021, DOI 10.1109/ISCA52012.2021.00020.
- [A28] Muthukrishnan et al., [FinePack: Transparently Improving the Efficiency of Fine-Grained Transfers in Multi-GPU Systems](https://doi.org/10.1109/HPCA56546.2023.10070949), HPCA 2023.
- [A29] Mittal et al., [Revisiting Network Support for RDMA](https://arxiv.org/abs/1806.08159), SIGCOMM 2018, DOI 10.1145/3230543.3230557.
- [A31] Singhvi et al., [Falcon: A Reliable, Low Latency Hardware Transport](https://dl.acm.org/doi/10.1145/3718958.3754353), SIGCOMM 2025; [Google Cloud overview](https://cloud.google.com/blog/topics/systems/introducing-falcon-a-reliable-low-latency-hardware-transport).
- [A37] Graham et al., [An In-Network Architecture for Accelerating Shared-Memory Multiprocessor Collectives](https://doi.org/10.1109/ISCA45697.2020.00085), ISCA 2020.
- [A39] Fang and Peng, [NetDAM: Network Direct Attached Memory with Programmable In-Memory Computing ISA](https://arxiv.org/abs/2110.14902), 2021.

## Pinned Open-Source Evidence

- [B1] NVIDIA [NCCL Extensions / NCCL EP](https://github.com/NVIDIA/nccl-extensions/tree/9f47d6eb3b60962d8157a579b4caaaa4ae6b19f4), commit `9f47d6eb3b60962d8157a579b4caaaa4ae6b19f4`.
- [B2] [Mooncake](https://github.com/kvcache-ai/Mooncake/tree/51e594d3a21660bdf2f6f1f11ec544b7cfb06932), commit `51e594d3a21660bdf2f6f1f11ec544b7cfb06932`.
- [B3] DeepSeek [DeepEP](https://github.com/deepseek-ai/DeepEP/tree/01dc3aaac82068020353dce2c302e38153c0bfaa), commit `01dc3aaac82068020353dce2c302e38153c0bfaa`.
- [B4] [UltraEP](https://github.com/Dots-Infra/UltraEP/tree/94cab099b44fffa99a82fea99e7c12d89cf65e4f), commit `94cab099b44fffa99a82fea99e7c12d89cf65e4f`.
- [B5] [MoonEP](https://github.com/MoonshotAI/MoonEP/tree/7745ffa00532d9086b49bab84a65b17f687ede14), commit `7745ffa00532d9086b49bab84a65b17f687ede14`.
- [B6] ByteDance Seed [Triton-distributed](https://github.com/ByteDance-Seed/Triton-distributed/tree/8260bc34398c2b8f36dc840fd22f741ca9294584), commit `8260bc34398c2b8f36dc840fd22f741ca9294584`.
- [B7] FlashInfer [MoE EP / CuTeDSL MegaMoE](https://github.com/flashinfer-ai/flashinfer/tree/bac0eb790e93221a477cca7fcc1c505210b5bb92/flashinfer/moe_ep/kernel_src), commit `bac0eb790e93221a477cca7fcc1c505210b5bb92`. Its acknowledgement file attributes the vendored CuTeDSL kernels to the NVIDIA CuTeDSL MegaMoE kernel team.
- [B8] SGLang [HiSparse implementation](https://github.com/sgl-project/sglang/tree/22e4b3a81f6362123faac44d87e548a29e8f679f), commit `22e4b3a81f6362123faac44d87e548a29e8f679f`; relevant PRs: [#20343](https://github.com/sgl-project/sglang/pull/20343), [#21591](https://github.com/sgl-project/sglang/pull/21591), [#24880](https://github.com/sgl-project/sglang/pull/24880).
- [B9] SGLang [Mooncake Store integration](https://github.com/sgl-project/sglang/tree/22e4b3a81f6362123faac44d87e548a29e8f679f/python/sglang/srt/mem_cache/storage/mooncake_store), same pinned commit.
- [B10] DeepGEMM [PR #304: Introducing Mega MoE](https://github.com/deepseek-ai/DeepGEMM/pull/304), merge `7f2a703e`.
- [B11] DeepGEMM [PR #328: Mega MoE optimizations and benchmarks](https://github.com/deepseek-ai/DeepGEMM/pull/328), merge `67fc6486`.
- [B12] [FlashMoE code](https://github.com/osayamenja/FlashMoE/tree/9cc0c32443d2a2da6825a68af5ef83060329483b), commit `9cc0c32443d2a2da6825a68af5ef83060329483b`; *Fast Distributed MoE in a Single Kernel*, NeurIPS 2025, [arXiv:2506.04667](https://arxiv.org/abs/2506.04667).
- [B13] NVIDIA [NVSHMEM](https://github.com/NVIDIA/nvshmem/tree/f86be2c6c390448cc4e0c32db9f27f5dbc345b67), commit `f86be2c6c390448cc4e0c32db9f27f5dbc345b67`.
- [B14] ByteDance [FLUX](https://github.com/bytedance/flux/tree/19831ca2d820e3e782ed1d15d8b52d0898b78b26), commit `19831ca2d820e3e782ed1d15d8b52d0898b78b26`.
- [B15] NVIDIA CUTLASS [distributed GEMM examples](https://github.com/NVIDIA/cutlass/tree/dcf215af68a2d08d305076c152a06f201728cd53/examples/65_distributed_gemm), commit `dcf215af68a2d08d305076c152a06f201728cd53`.

## Rapidly Evolving Public Material

- [C2] NVIDIA, [CMX Context Memory Platform](https://resources.nvidia.com/en-us/accelerated-networking-resource-library/cmx-tech-blog). Treat branding, availability and implementation details as version-sensitive.

## Acknowledged Secondary Reading

特别感谢微信公众号 **zartbot**。以下文章帮助确定了问题脉络和扩展阅读范围；公众号文章未找到稳定公开永久链接，按标题与来源记录，访问日期 2026-08-12：

- 《英伟达 GB200 架构解析 4：BlackWell 多 die 和 Cache 一致性相关的分析》
- 《谈谈 RDMA 和 ScaleUP 的可靠传输》

讲稿中的产品事实、协议字段和量化数字仍回溯到上面的官方资料、标准、论文或固定版本的代码。
