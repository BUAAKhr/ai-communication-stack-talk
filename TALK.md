# AI Communication Stack: From One Tensor to the Whole System

> 零基础公开审校稿 v0.9，资料核对日期：2026-08-21。
>
> 独立讲授建议时长：约 186–192 分钟；紧接《Towards Modern Networking System》联讲时建议约 170–180 分钟。主讲 88 页，另附备份页、demo 与制图建议。屏幕正文控制信息密度，完整因果链、观测方法和易错边界写在讲师说明中。
>
> 证据标签：`[A]` 官方规范、官方文档或正式论文；`[B]` 官方开源仓库/项目文档；`[C]` 快速演进的公开材料、厂商预告或用户提供的二手分析。`[C]` 内容适合讲趋势，不宜讲成稳定产品事实或一手规范。涉及产品微架构时再区分“官方产品事实 / 学术研究方案 / 基于公开材料的推断”，不能用论文方案反推量产芯片实现。

## 前导：从 Tensor Core 到跨 GPU 数据流

从 Volta 到 Blackwell，Tensor Core 大致经历了 `WMMA → MMA → WGMMA → tcgen05` 的编程模型演进。矩阵吞吐提高后，问题不再只是“算得更快”，而是如何持续供数、推进依赖并隐藏搬运和等待；这不意味着计算不重要，而是数据供给和协调更容易进入端到端关键路径。

数据搬运也在改变责任边界：从线程/warp 手工 load/store，到 Ampere 的 `cp.async`，再到 Hopper 的 TMA，以及 Blackwell 的 TMA + TMEM。与此同时，计算从同步发射逐步支持异步发射和异步完成。`__syncthreads()` 主要同步线程控制流，`mbarrier` 用于异步搬运阶段，transaction-aware wait（例如 `tcgen05.wait`）则把等待绑定到未完成事务。`async` 只拆开发起与完成，不会消除依赖。

可以把这条演进压缩为一条数据流：

```text
Producer → Data Movement → Completion → Consumer
```

在单个 GPU 内，这条链由 Tensor Core、copy engine、barrier 和 memory system 协作完成；当 chunk 跨越 GPU、NIC 和交换机时，同样的问题会扩展为跨设备的 ownership、ordering、progress、visibility 和 recovery。以下六个 topic 就从这条数据流逐层展开。[A19][A20][A22]

## 课程主张与学习目标

通信不是一根“更快的线”，而是把一个上层依赖翻译成若干次数据搬运、排队、同步与恢复的端到端过程。整场只反复使用一个基准场景：

```text
GPU A 已经产生一个 tensor chunk
GPU B 的下一步计算必须等到该 chunk 可以安全消费
```

### 核心问题

> **当一个 Tensor Chunk 从 GPU A 发往 GPU B 时，它实际走过什么路径？GPU B 在什么条件下才真正获得消费它的资格？**
>
> 为了让这个 Chunk 在依赖满足后，以正确的顺序写入正确的位置，并对消费 kernel 可见，通信栈必须维护哪些状态、执行哪些协议？这些责任由哪一层承担，系统设计者又必须在哪些边界上做出取舍？

这不是两个互不相关的问题。“走什么路径”决定数据跨过哪些资源、地址域和故障域；“何时可消费”决定每个边界必须建立什么 completion、visibility 与 ordering 证据。整场沿着以下六问推进：

| Topic | 核心追问 | 本节任务 |
|---|---|---|
| 1. 什么才叫可消费？ | Delivery、Placement、Completion、Visibility、Ordering 分别证明什么？ | 先建立正确性坐标系；数据到达端点不等于 GPU consumer 已可见。 |
| 2. 数据跨过哪些边界？ | HBM、GPU fabric、PCIe、NIC、RDMA 与交换机之间发生了什么？ | 画出真实 payload path，并标出共享资源、地址转换、ownership 与故障边界。 |
| 3. 状态与控制由谁维护？ | 可靠性、顺序、拥塞、progress 和故障状态在哪些层维护？ | 比较 collective/runtime、host software、NIC/transport 与 fabric 的控制闭环；回答谁发现、谁推进、谁恢复。 |
| 4. Workload 如何把流量变成等待？ | Ring、All-to-All、MoE、P2P/KV 与 distributed kernel 各自让谁等待谁？ | 从 traffic pattern 走到 progress、contention、overlap 和 wait-for graph，找到真正暴露的依赖。 |
| 5. 哪些开销会进入 Critical Path？ | 启动/重启、稳态执行、故障检测恢复为何在大规模下不可忽略？ | 用 MRC 与 Meta 100K+ GPU 案例解释 scale 如何放大状态、资源、尾延迟与恢复成本。 |
| 6. 如果重新划分边界会怎样？ | 改变 compute、memory 与 interconnect 的落点后，责任消失了吗？ | 用 Cerebras、Groq、HBF、PNM、3D stacking 与 NetDAM 检查责任是被删除、转移、复制，还是形成新耦合。 |

```text
可消费语义
    → 物理与协议边界
    → 状态与控制归属
    → workload 产生 traffic、progress 与 wait-for graph
    → scale 把暴露开销推入 critical path
    → 重新划分 compute / memory / interconnect 边界
```

听众在结束时应该能独立完成四件事：

1. 从一个 `all_reduce()`、`send()`、MoE dispatch 或 KV transfer 调用，画出数据真正经过的硬件路径。
2. 区分 Delivery、Placement、Completion、Visibility 和 Ordering 五类 readiness evidence，并检查 source/destination buffer 的 ownership/lifetime。
3. 把慢归因到 source readiness、launch/progress、memory movement、queueing、serialization、path、completion、imbalance 或 recovery，而不是笼统地说“网络慢”。
4. 指出调用者站在多少层抽象之上，以及每层虽然透明但仍付出了什么状态、带宽、延迟和芯片面积。

本稿把一次用户可见操作拆成以下层次；`透明`只表示调用者不必亲自管理，不表示该工作不存在或没有成本：

```text
workload dependency
  ↓ framework graph / parallel strategy
collective, P2P, EP or object API
  ↓ algorithm / channel / chunk schedule
CPU or GPU execution and progress
  ↓ memory readiness / staging / registration / DMA
transport connection / congestion / reliability
  ↓ packetization / path selection / switch queues
link serialization / FEC / replay / credit
  ↓ destination placement / completion / memory ordering
consumer synchronization and recovery
```

后续每一层都固定回答八个问题：

1. 移动的对象是什么？
2. 谁发起，谁持续推进 progress？
3. 数据前后物理上放在哪里？
4. 本层隐藏了哪些工作与状态？
5. 哪个资源可能阻塞？
6. 阻塞会在上层表现成什么？
7. 哪个计数器、日志或 timeline 能证明它？
8. 哪个更高层对此完全无感？

## 与前序演讲的衔接

前序演讲《Towards Modern Networking System》已经从 circuit、VALID/READY、credit、link replay、router queue/VC、Orderlock、Domain、同步、SQ/CQ 与 Ethernet/TCP 建立了基础；新版 p.64–70 还初步展开了网络分层、RC QP 耦合批评、multi-plane/SRv6 风格路径，p.71–78 展开了 Tile、Descriptor、Barrier、Commit、Wait 和 Unified System。因此，本场不再把这些内容说成“尚未讲授”，而是把前序抽象放回 GPU tensor、RDMA、MRC、MoE、KV 和 distributed-kernel 的具体数据路径，再用公开协议与实现检验其边界。

建议用约 90–120 秒完成这个承接：

- 前序第 15–42 页已经展开 credit/replay、lossless/lossy、HOL/VC、因果依赖、Orderlock 与 InfiniBand；本场在 Slide 22–25 压缩回忆，在 Slide 26–33 把这些机制放入 multipath、direct placement、SACK/retry、拥塞控制与状态放置的 AI case。
- 前序第 43–50 页用 Domain、NVL72、同步类比和 SQ/CQ 生命周期说明“设备背后存在状态与异步 progress”；本场在 Topic 1 把它翻译成一个 GPU A→GPU B 的 readiness contract，并明确 MMIO doorbell、DMA、transport ACK、CQE、remote visibility 和 consumer synchronization 不是同一事件。
- 前序第 52–59 页已经给出 Ethernet/IP/ARP/TCP 的基础层次，p.64–78 又提出网络分层与 Tile/Unified System；本场不再泛讲协议栈，而是把 connection/tunnel/path、bounded transaction、fence、tile，以及 UET、Falcon、MRC、UCCL、TMA、NVSHMEM、TileLink、distributed GEMM 与 MegaMoE 放入可观测的数据路径，讲清各自实际边界。

这里有一个重要口径：`Software Connection`、`Reliable Tunnel`、`Physical Path`、`DMA Context`、`Bounded Transaction`、`Local Retirement`、`Send/Execute Fence` 等仍是前序讲者的架构词汇，不是行业通用标准对象；新版虽已初步展示相关分层和 Tile 操作，也不能把它们直接等同为 RDMA QP/RC、UET PDC/CCC、Falcon connection、UCCL connection/chunk 或 GEMM tile。Tile Load/Store 在前序中是设计语言，本场会把它连接到已公开的 device/runtime 机制，并说明 queue、backpressure、replay、protection 和 completion state 仍然存在。

```text
1. What makes a tensor chunk consumable?
2. Which physical and protocol boundaries does it cross?
3. Where do state and control live?
4. How does workload traffic become a wait-for graph?
5. Which costs enter the critical path at scale?
6. What changes when we redraw compute, memory and interconnect boundaries?
```

## 总时间建议

| 章节 | Slides | 时间 |
|---|---:|---:|
| 1. 什么才叫可消费 | 1–8 | 17 min |
| 2. 数据跨过哪些边界 | 9–21 | 25 min |
| 3. 状态与控制由哪一层维护 | 22–38 | 39 min |
| 4. Workload 如何把流量变成等待 | 39–69 | 61 min |
| 5. 哪些开销会在 scale 下进入 Critical Path | 70–78 | 21 min |
| 6. 重新划分 compute、memory 与 interconnect 边界 | 79–87 | 21 min |
| 总结 | 88 | 2 min |
| **总计** | **88** | **186 min** |

联讲版不删除页面，但把 Slide 22–25 中前序已经讲过的 credit、HOL、lossless 与 replay 机制压缩为约 8 分钟，重点保留“这些机制在一个真实 tensor transfer 中改变了什么”。Slide 26–33 仍完整讲多路径、恢复、拥塞和可靠性边界；新增案例可压缩为约 170–180 分钟。

---

# 1. 什么才叫“可消费”？（0–17 min）

> 本章只回答一个语义问题：`x[i]` 在哪些条件都成立时，GPU B 才能安全消费？从 Slide 3 到 Slide 7 依次拆开 Delivery、Placement、Completion、Visibility 和 Ordering；它们是五类证据，不是五个必然串行的 wire stage。


## Slide 1｜先说清楚：这场课结束时你要能画出什么

屏幕正文：

```text
AI Communication Stack
From One Tensor to the Whole System

GPU A ── Tensor Chunk ──?──> GPU B / consumer kernel

两条主问题：
1. 这块数据实际走过什么路径？
2. GPU B 凭什么判断“现在可以消费”？
```

讲师说明：先不要记厂商、协议或缩写。我们先建立一个 readiness contract：B 不是因为“收到一个消息”就能消费，而是因为一组可验证的条件已经成立。后面看到 NCCL、RDMA、UET、TMA 或 MegaMoE，都把它们放回这条 contract，而不是把它们当成互不相干的产品名。

建议图示：左侧一个 API，右侧一个消费者 kernel，中间留出一条逐层展开的路径；只标出“调用者看到的”和“硬件实际做的”。

## Slide 2｜基准场景：GPU A 产出，GPU B 才能继续

屏幕正文：

```text
GPU A / HBM                         GPU B / target buffer
  producer 写出 x[i] ──?──> 目标区域       K_B 依赖 x[i]

payload role:       搬运真正被消费的 bytes
control / metadata: identity、address、sequence、credit、ACK/NACK、error
completion / publish: CQE、counter、fence、event 或 ready signal
lifetime:           source 与 destination buffer 何时可以复用

CanConsume(B, x[i]) requires evidence for:
Delivery ∧ Placement ∧ Completion ∧ Visibility ∧ Ordering
```

讲师说明：假设 GPU A 在 HBM 中产生了一个 32 KiB chunk，GPU B 的下一个 tile 依赖它。五项分别问：必要的 bytes/fragment 是否到达规定的接收端（`Delivery`）；是否写入正确的目标地址、offset 和 generation（`Placement`）；哪一项传输或发布义务已经结束（`Completion`）；B 的 memory system 和 consumer 是否能在所需 scope 下观察到写入（`Visibility`）；payload、signal、fence 和 consumer launch 之间需要的 happens-before 是否成立（`Ordering`）。它们是分析“可消费资格”的证据类别，不是所有协议都严格串行执行的五个 wire stage。

`Buffer ownership/lifetime` 是横向的安全前提：即使五类证据已经满足，如果 A 已经过早复用 source buffer，或者 B 的 target slot 已经被下一轮覆盖，B 仍不能安全消费。这里的三类角色不是三条必然独立的物理路径：控制信息可能与 payload 一起传输，completion 也可能 piggyback 在控制消息上，或者由同一个 endpoint 直接产生。需要分别追问的是：bytes 是否搬到位，控制/metadata 是否使它能被正确解释和推进，以及相应层次的 completion/publication 是否已经发布。对 B 的 readiness contract 来说，只要其中一类必要工作没有完成，consumer 就可能继续等待，表现为 kernel 未启动、polling 或 pipeline bubble；与 B 无关的 source-side ACK 延迟则不一定阻塞 B。

本页的数值只是教学单位，不是某个协议规定的最佳 chunk。真实大小由算子 tile、memory layout、NIC offload、MTU、拥塞窗口和接收端 buffer 一起决定。

## Slide 3｜Delivery：必要的 bytes 到达规定的接收端

屏幕正文：

```text
Delivery 问的是：
必要的 packet / fragment 是否到达
协议定义的接收端点？

需要识别：
  message / chunk identity
  sequence / offset / length
  integrity 与 duplicate handling
  gap / loss 是否已被处理（若协议允许乱序或重传）

到达接收端 ≠ 已写入目标 buffer
到达接收端 ≠ consumer 已经可以读
```

讲师说明：先限定“到达”的观察点。它可以是 remote RNIC 收到并验证了 fragment，也可以是 scale-up endpoint 接收了一个 transaction；不能在没有协议定义的情况下把它直接说成“已经到达 GPU HBM”。Delivery 需要 message identity、offset、length、完整性和 gap/duplicate 状态，接收端可能允许乱序到达，但必须能判断哪些片段仍缺失。

可靠传输中的 ACK、receive completion 或后续 transport state 可以证明某一层的 delivery obligation；它们不自动证明 payload 已经完成目标写入，更不自动证明 B 的 kernel 已经 acquire 到数据。这个区分会贯穿后面所有 RC、MRC、Falcon、UCCL 和 UET 的比较。

## Slide 4｜Placement：bytes 位于正确的目标位置

屏幕正文：

```text
Placement 问的是：
bytes 是否已经写入正确的
address / offset / generation？

必须成立：
  address translation / protection
  range 与 length 检查
  fragment coverage / hole tracking（若发生分片或乱序）
  destination buffer ownership

在协议允许乱序时，direct placement 可以允许乱序写入，
但不能允许错误位置或错误 generation。
```

讲师说明：Placement 比“收到 bytes”更强。目标可能是远端 HBM、host staging buffer、片上 scratchpad 或一个由 runtime 管理的 slot；必须明确最终 consumer 读取的地址域。在支持分片乱序放置的协议中，可以按 fragment offset 直接写入，不要求 payload 按网络到达顺序到齐；此时接收端还要维护 hole/bitmap、长度和 generation，避免迟到的上一轮数据污染当前 buffer。顺序传输则可能不需要这些额外的 reorder state。

DMA 已经写入一个目标地址，不等于整个 logical chunk 已经完整放置；一个 message 也可能经过 staging、reorder 或分片提交。证据应包括目标写入范围、fragment completion、reorder state 和 buffer lifetime，而不是只看 sender-side CQE。

## Slide 5｜Completion：必须说明“哪一个义务结束了”

屏幕正文：

```text
Completion 不是一个全局事件。

可能分别表示：
  sender：source buffer 可以复用
  transport：delivery / retry 义务结束
  endpoint：本层 DMA / write obligation 已结束
  runtime：ready signal / counter 已发布
  consumer：已满足 acquire 条件并开始使用（readiness endpoint）

每个 CQE / ACK / counter / event
都必须问：它覆盖哪一层？
```

讲师说明：Completion 是最容易被一句“通信完成了”掩盖的词。发送方 CQE 可能只表示本地 WQE 已由 RNIC 处理，足以解除 source-data obligation；transport ACK 可能只表示对端接受了协议层义务；remote write completion、runtime signal 和 consumer acquire 又是不同层次。具体 API 的语义必须以它的规范和 memory-ordering 定义为准，不能把一个本地 completion 反推成远端 kernel 已执行。

还要区分 definite success、definite rejection 和 unknown failure。超时只是本地观察到等待超限，不自动证明远端没有执行；如果 buffer 要复用或重试，必须知道当前 completion/ownership 到底覆盖了什么。

## Slide 6｜Visibility：目标写入对 consumer 真正可观察

屏幕正文：

```text
Visibility 问的是：
consumer 的 memory access
能否在规定 scope 下观察到 payload？

DMA write ≠ kernel-visible write
signal observed ≠ payload visible
除非定义了所需的 memory ordering
```

讲师说明：Visibility 是相对于 consumer 和 memory scope 定义的，不是“总线上的某个设备看见过 bytes”。不同平台可能提供硬件一致性、显式 fence、event/stream dependency、acquire/release 或其他 scope；本稿不假设所有平台都需要同一种 flush/invalidate。关键是要有协议或 memory model 规定：目标写入何时进入 consumer 可观察的域。

最常见的错误是先写 payload，再单独更新 flag；如果 flag 的发布没有 release/ordering 语义，consumer 可能先观察到 flag，却仍不能安全读取 payload。反过来，payload 已进入目标 memory system，也不代表 consumer 已经获得执行资格。证据应包含 consumer-side acquire、event/fence、memory-scope 文档或可重复的 protocol trace。

## Slide 7｜Ordering：满足 consumer 所需的 happens-before

```text
Ordering 不是“所有 packet 必须按序到达”，
而是必要的先后关系必须成立：

payload writes  →  publish signal
phase n        →  phase n+1
metadata       →  payload interpretation
producer ready →  transfer launch
completion     →  consumer launch

sequence / phase / fence / barrier / acquire
共同表达这些 happens-before 约束。
```

讲师说明：Ordering 必须说明“在哪个域、对谁成立”。多路径或 direct placement 可以允许 packet 乱序到达，只要 message identity、offset、sequence/bitmap 和 commit rule 能让目标按 logical order 发布；反过来，in-order delivery 也不等于 consumer 已经完成 acquire。需要特别防止 stale signal：buffer 复用后，上一轮迟到的 completion 或 flag 不能被解释成当前 generation 的 ready。

因此要分开 arrival order、placement order、completion order 和 execution order。一个协议可以只保证其中一部分，剩余部分由 endpoint、runtime 或 kernel 补齐；这正是 Topic 3 要比较的状态归属问题。

## Slide 8｜从五类证据转向后面的六个问题

屏幕正文：

```text
五类证据不是五个必然串行的阶段：

Delivery      到达规定接收端
Placement     写入正确目标位置
Completion    某项义务结束并可被发布
Visibility    consumer 可以观察 payload
Ordering      依赖所需的先后关系成立

CanConsume(B, x[i])
  ⇔ D ∧ P ∧ C_publish ∧ V ∧ O
  subject to valid buffer ownership / lifetime
```

| 证据 | 它证明什么 | 它不自动证明什么 |
|---|---|---|
| Delivery | 规定接收端看到了所需 fragment | 目标 buffer 已写完、consumer 已可见 |
| Placement | bytes 位于正确 address / offset / generation | memory ordering、consumer 执行资格 |
| Completion | 指定层的 transfer / publication 义务结束 | 远端 application 已执行 |
| Visibility | consumer 在所需 scope 下可观察 payload | payload 一定满足 logical sequence |
| Ordering | payload、signal、phase、launch 的先后约束成立 | 缺失 bytes 已经到达 |

讲师说明：到这里，五类证据的边界已经清楚：对本例的安全消费而言，每一项都需要有对应保证，但没有一项单独充分。它们可以被同一个 counter、fence 或 completion record 一次性发布，也可以由多个层次分别维护。`Buffer ownership/lifetime` 是横向安全条件，不能因为 payload 已可见就省略。后面每一个协议、library、kernel 和硬件案例都必须回到这个 contract，并说明自己提供了哪一类证据。

```text
五类证据
    → 物理与协议边界
    → 状态与控制归属
    → workload 产生 traffic、progress 与 wait-for graph
    → scale 下暴露的 critical path
    → 重画 compute / memory / interconnect 边界
```

这五类证据仍然分布在一套透明性阶梯中：

```text
workload dependency
  ↓ framework / parallel strategy
collective, P2P, EP or object API
  ↓ algorithm / channel / chunk schedule
CPU or GPU execution and progress
  ↓ memory readiness / staging / registration / DMA
transport connection / congestion / reliability
  ↓ packetization / path selection / switch queues
link serialization / FEC / replay / credit
  ↓ destination placement / completion / memory ordering
consumer synchronization and recovery
```

讲师说明：这张阶梯不是标准网络分层模型，而是追踪证据和隐藏工作的教学坐标。下一章暂时只沿 payload path 画 HBM、GPU fabric、PCIe、RNIC 和交换机；哪些层拥有 sequence、completion、visibility 和 recovery state，留到 Topic 3 再回答。

本章的验收问题只有一个：如果有人说“数据已经到了”，请追问“到了哪个端点、写入哪个位置、哪一项 completion 已发布、对哪个 consumer 可见、满足哪一个 ordering 约束？”如果这五个答案不完整，`CanConsume(B, x[i])` 仍未被证明。

---

# 2. 数据究竟跨过哪些边界？Physical Architecture & Topology（17–42 min）

> 本章只回答“payload 经过哪里”。沿 HBM、GPU/local fabric、PCIe/C2C、RNIC DMA、RDMA transport 和 switch fabric 画出可能路径；每跨一个边界，就检查 address、ownership、queue、completion、visibility 和 failure model 如何变化。实际路径取决于 GPU 位置、拓扑、通信库和 fallback，并非每次传输都会经过全部层次。状态 owner 留给 Topic 3。

## 2.1 Inside AI Servers: Package, Node and NUMA

## Slide 9｜GPU A → GPU B 的第一条路径：节点内专用 fabric

屏幕正文：

```text
producer kernel writes x[i] into GPU A HBM
      ↓ source-ready signal / dependency
GPU A fabric endpoint reads or sources the bytes
      ↓ NVLink / xGMI / HCCS / accelerator fabric
switch / crossbar arbitrates and forwards
      ↓
GPU B endpoint places x[i] into GPU B memory
      ↓ completion + ordering
consumer kernel may read x[i]
```

讲师说明：如果 A、B 位于同一个带专用 scale-up fabric 的 domain，通信库可能选择 NVLink、xGMI、HCCS 等 peer path，payload 不必经过 host CPU/CPU DRAM、外部 RNIC 或 Ethernet/InfiniBand switch；是否经过 PCIe 仍取决于具体 GPU、桥接器和拓扑，不能一概而论。逐步看：A 的 producer 先把 32 KiB chunk 写完；某个 GPU warp、copy/collective engine 或 endpoint 获得 ready 条件；source endpoint 从 HBM/L2/SMEM 对应路径取数；fabric 仲裁；B endpoint 把 bytes 写入目标位置；completion/fence 最后释放 B 的 consumer。对调用 NCCL 或 device `put` 的程序员来说，中间的 endpoint queue、fabric credit、arbitration、peer HBM write 与 signal 通常都是透明层。

瓶颈因而不叫“网卡线速”，而可能是 source HBM read、endpoint injection、共享 fabric edge、destination HBM write 或 completion wait。症状分别可能是 producer 后长 gap、fabric link 不满、某一 edge 饱和、B 侧 memory busy 或数据已到但 kernel 仍在 poll。证据应组合 NVLink/xGMI/HCCS counters、per-link bytes/stall、HBM throughput 和 GPU timeline。[A1][A3][A4]

如果服务器没有可用的节点内专用 fabric，或者通信目标位于另一台服务器，数据就可能转入通用 I/O 路径：同一节点内可以是 PCIe P2P，跨节点则常见的是 GPUDirect RDMA。此时必须先把实际拓扑画出来，再判断哪些边界真的经过。

## Slide 10｜GPU A → GPU B 的第二条路径：通用 I/O / scale-out fabric

屏幕正文：

```text
common host-driven control:
  setup: register memory region (often amortized)
  per operation: build/post WQE → poll CQE

same-node PCIe P2P variant:
  GPU A HBM → PCIe switch / root complex → GPU B HBM

cross-node GPUDirect RDMA (when peer DMA is supported):
GPU A HBM → GPU–RNIC I/O link (often PCIe)
           → RNIC DMA read / packet engine
           → packetization / transport / Ethernet or IB switches
           → remote RNIC → remote GPU–RNIC I/O link
           → PCIe DMA write → GPU B HBM

completion/publication (semantics vary):
  sender CQE / transport ACK / explicit remote signal
    → required consumer-side ordering/acquire → consume
```

讲师说明：这页描述的是两种常见的通用 I/O 变体，而不是说所有 GPU-to-GPU 通信都使用 RDMA。若同一节点没有专用 GPU fabric，GPU P2P 可能经 PCIe switch 或 root complex 完成；若目标在另一台服务器且平台支持 peer DMA，则可使用 GPUDirect RDMA：RNIC 直接读取已注册的 GPU memory，并把 payload 写入远端 GPU memory，数据路径不必经过 CPU DRAM。CPU 仍可能在常见的 host-driven 实现中负责 memory-region 注册、WQE 提交和 CQ 轮询；这些 control/progress 工作也可能由 GPU 或 NIC/DPU offload，且 memory registration 通常是可摊销的 setup，而不是每个 chunk 都重复执行。

分析跨节点路径时，应把 source/destination HBM、两端 GPU–RNIC I/O link、RNIC DMA/packet engine、交换网络队列和两端 completion/publication 看成不同的资源域，而不是固定的“六个服务站”。peer-DMA、IOMMU、PCIe bridge 或 NUMA 条件不满足时，runtime 可能退回 Slide 11 的 host-memory staging。

以单端口 400 Gb/s 为例，原始线速约为每方向 50 GB/s，实际 payload 还要扣除编码、FEC、协议头和其他链路开销；若 GPU→RNIC 的有效 DMA 只有 35 GB/s，交换网络再快也无法提高端到端 payload。反过来，DMA 已接近线速而 flow hash 撞在同一 uplink，瓶颈就位于网络。若 payload 已写入 B，但 B 所需的 remote signal、ordering 或 acquire 条件到得晚，链路 counter 仍可能很好看，consumer 却继续空等。最容易犯的错误是把“GPU 与 NIC 在同一台服务器”误认为一定共享同一个 PCIe switch 或最短 NUMA 路径；应使用
`nvidia-smi topo -m`、PCIe 拓扑、GPU–NIC affinity、NUMA 绑定、DMA microbenchmark 和 NIC/link counters 共同确认实际路径。

## Slide 11｜GPU A → GPU B 的第三条路径：经过 CPU/host memory 的 fallback

屏幕正文：

```text
GPU A HBM ─DMA/copy→ source host buffer
source host buffer ─RNIC/network→ destination host buffer
destination host buffer ─DMA/copy→ GPU B HBM

同一批 payload 被 memory system 服务至少三次；
每一段都有独立的 queue、completion 和 buffer lifetime。
```

讲师说明：当 peer access、IOMMU 映射、内存注册或设备组合不支持直达时，runtime 可能退回 staging。对同一个 32 KiB chunk，先从 A HBM 搬到 host buffer，等这一段 completion；RNIC 再读取 host buffer并传到远端 host；最后再搬进 B HBM并发布 consumer-ready。除非做双缓冲流水，否则三个阶段容易串行。即使流水化，每个 in-flight chunk 也需要 source/destination staging slot 和生命周期状态。

它会同时消耗 HBM、PCIe、CPU DRAM、RNIC DMA 和 launch/progress 资源；网络本身不变，端到端时间却可能明显增加。上层通常只看见 collective/P2P 变慢，并不知道 runtime 已 fallback。证据是 host memory traffic 与 GPU copy engine 活跃、NIC 仍接近原速、timeline 出现 HBM→host 和 host→HBM 两段；若只看网络端口，会误判为协议效率下降。

## Slide 12｜节点内三类 fabric，分别解决不同问题

屏幕正文：

| fabric | 主要移动对象 | 常见优势 | 典型代价 |
|---|---|---|---|
| memory/coherent link | cache line、load/store、host/device data | 地址共享、编程便利 | coherence/ordering、非均匀延迟 |
| GPU scale-up fabric | 大块 tensor、collective partial | 高带宽、短 RTT、域内拓扑固定 | 专用端点与较大 die/封装成本 |
| general I/O fabric | DMA buffer、message、storage/KV object | 标准化、可跨节点扩展 | PCIe、NIC、packet transport、故障状态 |

讲师说明：这三层不是“性能从高到低”的简单排序。memory/coherent link 更适合细粒度访问；scale-up fabric 更适合受控域内的 bulk/collective；general I/O fabric 更适合跨节点、跨租户和异构设备。一个 workload 可能同时使用三层，真正要问的是每一段 bytes 的所有权和 completion 在哪里转移。

## Slide 13｜读拓扑不是数线，而是找共享资源和慢路径

屏幕正文：

```text
1. 最小的高带宽域有多大？
2. 任意两端的路径是否对称？
3. NIC 挂在哪个 GPU / NUMA / PCIe switch？
4. 哪些边或交换机存在 oversubscription？
5. 离开这个域后，语义和故障边界变成什么？
```

讲师说明：用一台“8 GPU、4 NIC、两个 CPU socket”的服务器练习。若 GPU0–3 与 NIC0–1 在 socket 0，GPU4–7 与 NIC2–3 在 socket 1，那么 GPU0 通过 NIC3 发包可能跨 GPU fabric、PCIe root 或 CPU socket；`8×400G` 只是端口总和，不是任意 GPU 都能同时获得的带宽。若跨节点 collective 又经过 oversubscribed uplink，真正共享的瓶颈可能只是一条边。

这五个问题会直接决定 ring 顺序、hierarchical collective 分组、EP expert placement、PD 的 NIC 选择，以及是否需要跨 rail 复制。上层 API通常只知道 rank id，不知道 rank 到 GPU/NIC/NUMA 的映射；通信库必须把逻辑 rank graph 放到物理图上。验证时把 topology、rank mapping、实际 route、per-link bytes 与 per-rank completion time 对齐；单独看一张厂商拓扑图无法预测通信时间。

## Slide 14｜一个逻辑 device 仍可能有多种物理距离

屏幕正文：

```text
compute die 0 ── 10 TB/s chip-to-chip interconnect ── compute die 1
                         ↓
                 unified single GPU
```

讲师说明：NVIDIA 官方对 Blackwell 的原文是：两个 reticle-limited GPU dies 由 10 TB/s chip-to-chip interconnect 连接成一个 “single, unified GPU”。这解释了为什么 CUDA 程序员看到一个 device，但不能推出每个地址、每个 HBM 访问和每个 cross-die transaction 都有相同的延迟、带宽或争用。对听众最重要的结论是：逻辑地址空间统一，不等于物理路径同质；仍需把 `local / cross-die / peer / remote` 分开测量。[A23]

建议图示：只画两个 compute die、相邻的 HBM 资源和中间 NV-HBI/芯片间链路；在逻辑层外框写 “one CUDA GPU”，在物理层标 “local / cross-die path may differ”。不要把 HBM stack 或 L2 slice 与某个 die 的精确归属画成官方事实，也不要虚构内部一致性目录或具体 L2 分区。

---
## 2.2 From Node to Cluster: NIC, Switch and Topology

## Slide 15｜NIC、DPU、交换机和 scale-up endpoint 各自搬什么

| 设备 | 收到什么输入 | 持有什么状态 / 做什么工作 | 交给下一层什么 |
|---|---|---|---|
| RNIC / fabric adapter | WQE、buffer address、payload | translation/protection、DMA、packetization、transport、CQ | packets；local/transport completion |
| switch | ingress packets/flits | forwarding table、queue、credit/ECN，部分设备有 reduction state | next-hop packets/flits |
| SmartNIC / DPU | packets + infrastructure work | NIC data path、programmable policy、storage/security/virtualization | forwarded data + offload result |
| scale-up endpoint | load/store/tile/collective transaction | address/route、credit/replay、remote placement/signal | remote data / response / completion |

讲师说明：把设备按名字分类容易混淆，按一次 x[i] 的责任链更准确。RNIC 接受 WQE 和地址，先验证权限并 DMA 取数，再分段、加 transport header、排队发包，最后产生本地或 transport completion；交换机不理解 PyTorch tensor，只看转发表、队列和 flow-control state；DPU 可以额外运行 policy、storage/security/control；scale-up endpoint 则更接近 load/store、tile 或 collective transaction。

同一产品也不必独占一种角色，关键是五件事分别由谁负责：initiator、progress engine、data mover、completion owner、recovery owner。上层调用者通常看不见 switch queue 和 NIC SRAM，却会以 launch gap、低吞吐、P99 或 timeout 的形式承受它们。验证时分别找 WQE/CQ、DMA、per-port queue/ECN、DPU core utilization 和 endpoint credit/replay 证据，不能用一个“NIC utilization”概括全部。

## Slide 16｜一条 RDMA WRITE 在 RNIC 内还要经过八步

屏幕正文：

```text
1 consume MMIO doorbell / fetch WQE
2 check MR, key, address and permissions
3 DMA-read source GPU/host memory
4 segment payload and build transport packets
5 select path, apply CC/pacing and enqueue
6 receive ACK/NACK/telemetry; retry when required
7 free outstanding/replay state
8 write CQE / immediate / completion signal
```

讲师说明：应用 post 一个 RDMA WRITE 后，RNIC 并不是立刻“把 tensor 放上网”。在常见 verbs 路径中，通知设备通常是对 doorbell register 的 MMIO write，有些实现还配合 host-memory doorbell record；这不是 CPU-style interrupt。设备报告完成时可以触发 interrupt，也可以由软件 polling CQ。WQE 可能先在 queue 等待；memory key 或地址转换 miss 会阻塞取数；GPU→NIC DMA 可能受 PCIe 限制；packet engine 再消耗 QP/connection、PSN、path 和 CC state；发送后还要保留 outstanding/replay 信息，直到 ACK 或完成条件释放。CQE 的到达也不自动等于远端 GPU consumer 已做 acquire/fence。

因此同样的端口线速下，小消息可能受 doorbell/WQE/CQE rate 限制，大消息受 DMA 或 wire rate 限制，多连接受 QP-context/cache 限制，丢包时受 replay/recovery 限制。应测 post→first DMA、DMA rate、packet rate、queue occupancy、retry、CQE latency 和 remote-visible gap。ConnectX 是 NIC/RNIC，BlueField 是带可编程基础设施处理器的 DPU，Spectrum-X 是交换机、NIC/DPU 与软件组成的系统；DOCA、NCCL、SHARP 也处在不同层，不能用产品名代替这八步。[A5][A6]

## Slide 17｜同一 workload 也可能同时走两层互联

屏幕正文：

```text
global collective
  → intra-system phase: NeuronLink / accelerator fabric
  → boundary / aggregation buffer
  → inter-instance phase: EFA + SRD/libfabric path
  → remote intra-system distribution

每次跨层都重新出现：chunking、buffer、completion、failure boundary
```

讲师说明：AWS 的例子把层次边界看得很清楚。一个 global collective 可先在 Trainium system 内通过 NeuronLink/accelerator fabric reduce 或 gather；到系统边界后，把某些 chunk 交给 EFA + SRD/libfabric；远端收到后再在本地 fabric 分发。上层只调用一次 collective，但下面至少有两套路径、两个 RTT 范围、两种故障半径，以及把二者接起来的 buffer/completion。

若 intra-system phase 慢，EFA link 可能长期空闲；若跨实例 phase 慢，本地 accelerator fabric 会出现等待；若 hierarchy 的 chunk 过小，跨层同步开销暴露；过大又降低流水化。应把 collective timeline 分成 local reduce、boundary ready、EFA transfer、remote distribute，并分别看本地 fabric 与 EFA counters。EFA 也不等于 InfiniBand，它是 AWS 的网络接口与 transport 体系。[A7][A8]

## Slide 18｜Clos/Fat Tree：路径多，不代表没有瓶颈

屏幕正文：

```text
sender A ─ leaf L ─ spine 0 ─ leaf R ─ receiver
sender B ─ leaf L ─ spine 0 ─ leaf R ─ receiver   ← hash collision
                   spine 1                         ← idle capacity

ECMP 通常按 flow 选一条路；
多条等价路径 ≠ 一个大 flow 自动使用全部路径。
```

讲师说明：Clos 的“路径多”先带来的是可选路径，不是已实现的负载均衡。若两个长流的 hash 都落到 spine 0，它们各只能分到热点链路的一部分，而 spine 1 空闲；collective 的慢 rank 仍由 spine 0 决定。增加 QP/subflow、adaptive routing 或 packet spraying 可以提高 path entropy，但会把乱序、per-path CC 和 gap tracking带到端点。

“non-blocking”也有前提：leaf/spine 端口比例、上行带宽和流量矩阵满足设计假设。若每个 leaf 下挂总速率高于 uplink，总 bisection 数字再大，局部仍可 oversubscribe。上层 NCCL 只看到某些 channel 慢；证据要落到每条 uplink utilization/queue、ECN/trim、flow-to-path mapping、reorder depth 和 rank tail，而不是只看所有端口求和。

## Slide 19｜Rail optimization：用规则性换取可预测性

屏幕正文：

```text
Node 0: GPU0─NIC0 ─┐       ┌─ NIC0─GPU0 : Node 1
Node 0: GPU1─NIC1 ─┼ rails ┼─ NIC1─GPU1 : Node 1
Node 0: GPU2─NIC2 ─┘       └─ NIC2─GPU2 : Node 1

规则 collective：同 local rank 走同一 rail
跨 rail P2P：需要本地转发、额外 hop 或另一条直接路径
```

讲师说明：rail optimization 预先把“哪个 GPU 使用哪个 NIC/交换平面”固定下来。规则 collective 可以让同 local rank 的流量留在同一 rail，减少 GPU→NIC first hop、ECMP碰撞和最后一跳争用，因此更可预测。比如 GPU0 的 chunk 通过 NIC0 进入 rail 0，到另一节点的 GPU0；通信库需要据此安排 rank graph。

代价是逻辑映射被物理拓扑约束。若 GPU0 要直接给远端 GPU2 发动态 EP token，可能先在本节点转给 GPU2/NIC2（PXN 类路径）、跨 rail，或走更多交换层；每种选择都增加 local copy、hop、completion 或 path state。某 rail 故障时，恢复也可能破坏原有亲和。观测应同时看 rail utilization、GPU–NIC bytes、跨 rail/PXN bytes、rank mapping 和 failure fallback，而不是把“rail optimized”理解成任意通信都更快。[A11]

## Slide 20｜Torus、rail、Clos：拓扑只是对等待关系的映射

屏幕正文：

| 拓扑 | 让什么更可预测 | 容易暴露什么等待 |
|---|---|---|
| Clos / Fat Tree | 任意端点可经多条等价上行到达 | ECMP collision、uplink oversubscription、reorder state |
| Rail | 规则 rank 对固定到物理平面 | cross-rail P2P、mapping 与故障回退成本 |
| Torus / mesh | 邻居与局部路径规则，布线可递增 | hop count、partition shape、bisection 与 wrap-around hotspot |

讲师说明：拓扑不是独立于软件的一张网络图，它规定“哪些通信边共享哪些物理资源”。同一个 ring 放在 Clos 上，慢点可能是 hash collision；放在 rail 上，慢点可能是跨 rail 的 rank edge；放在 torus 上，ring/collective 的方向和 partition shape 会决定 hop 与 bisection。Google TPU 的 3D torus 只是这一设计点的公开案例，不要求听众记某一代具体维数。[A12]

比较拓扑时至少固定 endpoint 数、每端口带宽、traffic matrix、算法和故障假设，再比较 path length、共享边、可用 path diversity 和最慢 rank。峰值链路速率相同不代表 step time 相同。证据是 hop/path distribution、per-edge bytes/queue、partition shape 和 per-rank completion；上层通常只看到 collective tail。

---
## 2.3 Scale-Up vs. Scale-Out: Physical and Failure Boundaries

## Slide 21｜Scale-up / scale-out：同一个 x[i]，跨过边界后协议就变了

| | 短距 scale-up / local fabric | 长距 scale-out / routed fabric |
|---|---|---|
| 常见范围 | package、server、rack、supernode | 多 rack、data center、跨园区 |
| 拓扑与 RTT | 较固定、较短、常为一层交换 | 多跳、多路径、RTT 与抖动更大 |
| 语义倾向 | transaction、load/store、atomic、fence | message、RDMA、packet transport |
| 常用保护 | FEC、link replay、credit/lossless flow control | multipath、端到端 ACK/retry、congestion control |
| 主要代价 | XPU die area、短距 replay/queue buffer | per-flow state、timer、reorder、长 BDP buffer |

讲师说明：scale-up/out 不是简单的距离或 Ethernet/非 Ethernet 二分，而是一个工程边界：RTT、路径数量、故障概率、地址语义、完成协议和可承受的状态量一起变化。短距 local fabric 往往可以用 credit、FEC 和 link replay 把错误隐藏在一跳内；跨 rack 的 routed fabric 必须处理多路径、拥塞、丢包、端点重启和长 BDP。对 Slide 2 的 x[i]，关键问题是“它在哪个边界完成 ownership transfer”：如果跨边界后只剩一个 opaque message，consumer 需要 ACK/CQE；如果进入对端地址空间，仍要定义 placement、ordering、权限和错误结果。UALink、SUE、UET/RDMA 的差异，本质是可靠性状态放在哪里、覆盖多大故障域，而不是谁的宣传带宽更高。[A13][A32][A33][A34]

用同一故障就能看清层次：一根 link 出现可纠正 bit error，FEC/LLR 可以让上层无感；某条多跳路径丢 packet，transport 需要知道 message identity 和 gap；远端进程重启后，即便 packet transport 已完整交付，runtime 仍可能必须重建 communicator 或重跑 iteration。观测应分开 link replay、credit stall、transport retransmit、completion timeout 和 rank failure。所谓“scale-up 更可靠”或“scale-out 更灵活”只是设计倾向，必须落到保护边界与状态预算。

---
# 3. 可靠性、顺序、拥塞、Progress 与故障状态由谁维护？（42–81 min）

> 本章坐标：主要展开第 4、7–12 层。物理路径已经画清楚，现在比较 collective/runtime、host software、NIC/transport 与 fabric 分别保存什么状态；谁发现 gap 或 congestion，谁持续推进，谁发布完成，谁在失败后恢复。这里不是给每类问题指定唯一 owner，而是识别多个控制闭环及其交界面。

## 3.1 Memory Semantics vs. RDMA Message Semantics

## Slide 22｜Memory semantic 和 RDMA message semantic，只是两种发起方式

| 问题 | Memory / transaction path | RDMA message / verbs path |
|---|---|---|
| 调用者表达什么 | `load/store/atomic/fence` 或 tile copy | `SEND/RECV/WRITE/READ/atomic` |
| 目标如何定位 | 地址 + translation/protection | 注册 buffer、RKey、QP/RQ、remote address |
| 谁保存 outstanding state | XPU load/store queue、copy engine、fabric endpoint | RNIC QP/WQE、host/device memory、transport engine |
| 如何知道完成 | response、counter、signal、fence | ACK、CQE、immediate、event、remote flag |
| 常见优点 | 细粒度、容易嵌入 kernel dataflow | bulk transfer、隔离成熟、跨 routed fabric |

讲师说明：对 Slide 2 的 x[i]，两条路径都必须做相同的基本工作：确认源数据 ready、检查权限、把 bytes 搬到目标、处理 backpressure、报告完成、满足消费者需要的顺序。差别在于这些工作由谁显式表达、状态放在哪里。`remote_store(dst, x)` 看起来像一条指令，但 endpoint 仍可能分块、排队、重放和等待 credit；`RDMA_WRITE` 看起来像 message，但 RNIC 可以直接 DMA GPU memory，payload 不一定经过 CPU。

性能上不能只比较 API 指令数。memory path 的远端延迟会占住 load/store queue、MSHR、TMA slot 或 transaction buffer；verbs path 会消耗 WQE/doorbell、QP context、CQ polling 和注册状态。应比较从 producer ready 到 consumer visible 的完整时间。观测上，前者重点看 remote outstanding、fabric stall 和 fence wait；后者重点看 post-to-DMA gap、CQE latency、QP/retry counters 和 GPU–NIC DMA bandwidth。常见误区是把“地址式接口”理解成底层没有队列，或把“message 接口”理解成一定经过 host memcpy。

---
## 3.2 Consumability and Layered Reliability

## Slide 23｜Topic 1 定义终点；本页分配状态观察与推进责任

```text
Delivery:   link / transport 观察 gap、duplicate，并触发 retry
Placement:  endpoint / DMA 维护 address、offset 与 buffer ownership
Completion: device / NIC / runtime 发布 CQE、counter 或 signal
Visibility: memory system / consumer 建立 scope 与 acquire 语义
Ordering:   protocol / runtime / kernel 维护 sequence、phase 与 dependency
```

讲师说明：Topic 1 已定义“可消费”的五类证据；本页只问哪一层能观察、证明并推进它们。常见的责任分布是：`Delivery` 由 link/transport 发现 gap、duplicate 并触发 retry；`Placement` 由 endpoint/DMA 处理 address、offset 与 buffer ownership；`Completion` 由 device/NIC/runtime 发布 CQE、counter 或 signal；`Visibility` 由 memory system 与 consumer 的 scope/acquire 语义建立；`Ordering` 由 protocol、runtime 或 kernel 维护 sequence、phase 与 dependency。实际系统通常跨层协作，不存在固定的单层 owner。

因此，out-of-order arrival 不等于 out-of-order completion；DMA 已经写入目标地址也不等于 memory model 已允许 kernel 观察。Scale-up 还要把 completion 与 acquire/release、scope、atomicity 和错误响应对齐。Orderlock 论文在其模型中证明，in-order delivery、lossless transmission 与 out-of-order capability 同时成立，是该类死锁的必要充分条件；direct placement 只是显式化落点和 gap，并没有取消 completion、fence 或有限 buffer。[A41]

观测时分别找证据：sequence gap/NACK 证明 delivery 问题，reorder bitmap/offset 证明 placement，CQE/counter/flag 证明 completion，cache/memory scope 与 acquire/consumer event 证明 visibility，fence/barrier wait 证明 ordering。只看“没有 packet drop”无法证明应用语义正确。

前序术语表可以帮助把同一例子再拆细，但这些词需要在这里第一次完整解释：`Move` 是较大的完整搬运任务，本身未必只有一个完成点；`Bounded Transaction` 是其中有稳定 identity、有限 size、一次 retirement 的工作单元；`Transaction Fragment` 是可独立 place 的逻辑片段；某个 fragment 每重发一次都会形成新的 `Incarnation`。sender 收齐 fragment ACK 得到的 `Local Retirement`，只表示可以解除 source-buffer obligation，不表示 B 的 kernel 已经可见或执行。最终还要区分 `Terminal Result`：success、definite rejection 或 unknown transport failure；timeout 只是等待超限，不能自动推出远端未执行。

同理，两类 fence 不应被说成万能顺序屏障：`Send Fence` 只限制后继 transaction 何时进入网络，`Execute Fence` 只限制目标端后继操作何时具备执行资格；它们都不会自动把多个 packet 变成 atomic commit，也不单独保证 arrival、completion 或 exactly-once effect。后文遇到 RDMA completion、UET ordering、device counter 和 distributed-kernel signal 时，都回到这组边界。

## Slide 24｜每一层可靠性只覆盖自己的故障半径

| 层次 | 主要覆盖 | 不能单独解决 |
|---|---|---|
| PHY FEC / CRC | 有界物理位错误、检测损坏 | 拥塞丢包、交换机/端点故障 |
| Link-level replay / LLR | 相邻链路上的损坏或缺失 frame/flit | 跨多跳的不可恢复错误、端点重启 |
| PFC / CBFC / credit | 配置正确时避免接收 buffer overflow | 数据损坏、路由黑洞、永久故障 |
| End-to-end transport | 缺失检测、ACK/retry、duplicate handling | 节点进程状态丢失、语义级回滚 |
| Runtime / application | rank failure、checkpoint、idempotence | 纳秒级链路恢复 |

讲师说明：沿 A→switch1→switch2→B 走一遍。线缆上的少量 bit error 先由 FEC/CRC 处理；一跳 frame 损坏可由相邻两端 replay；接收 buffer 快满时由 credit/PFC/CBFC 暂停上游；如果 switch2 丢包、改路由或 B 重启，只有端到端 transport 能判断完整 message 是否缺失；如果 B 的进程已经失去状态，最终还要 runtime 重建 communicator、重放 iteration 或从 checkpoint 恢复。

所以“lossless”不是“end-to-end reliable”的同义词。在本场的机制化语境中，lossless 首先回答正常拥塞下是否因 buffer overflow 丢弃；它不自动覆盖 silent corruption、route blackhole、永久故障和 endpoint reset。UALink 1.0 的正常路径由 FEC/CRC、每段 link-level replay 与 flow control 组成，但规范也定义 drop、isolation 和 completion timeout 来处理不能透明恢复的错误。[A33]

观测上，PHY corrected/uncorrected errors、LLR replay count、PFC pause/credit stall、transport retransmission 和 communicator failure 是五组不同证据。把它们汇总成一个“network error count”会丢失故障层次。

## Slide 25｜Lossless 把 drop 变少，也可能把等待向上游传播

屏幕正文：

```text
PFC / credit backpressure
    ↓ fewer congestion drops
    ↑ head-of-line blocking / congestion spreading / config coupling
```

讲师说明：假设 B 的 ingress 或目标 HBM 暂时不能继续接收。lossless fabric 不丢 x[i]，而是发送 pause/撤销 credit；switch2 的队列增长，继而阻塞 switch1，再影响共享同一 priority/virtual lane 的无关 flow。这就是 head-of-line blocking 和 congestion spreading：数据仍然“可靠地”留在系统里，但等待时间和故障影响范围扩大了。上层可能只看到某个完全无关的 collective channel 也变慢，因为它与热点流共享了被 pause 的 class 或队列。

IRN 的核心贡献不是说 PFC 永远无用，而是证明 RDMA 并不从原理上必须依赖 PFC；在其研究配置中，有限 NIC 状态、选择性重传和 BDP flow control 可以在 lossy fabric 上工作。UEC 1.0 同时支持 best-effort 与 lossless 网络，并在 best-effort 路径采用 endpoint reliability 与 congestion control；这些结果都依赖协议、buffer 和 workload 配置，不能外推成某种 fabric 永远更优。[A29][A32]

怎么判断问题在这里：同时查看 pause duration、per-priority queue occupancy、ECN/trim/drop、上游端口 idle/busy 和 victim-flow latency。如果链路利用率下降而 pause/queue 上升，瓶颈不是序列化带宽，而是 backpressure。常见误区是把“零 drop”当作“零拥塞”或“低延迟”。

---
## 3.3 Multipath, Out-of-Order and Direct Placement

## Slide 26｜Multipath：允许乱序到达，维持所需的完成顺序

```text
one message / transaction
   ├─ packet 0 → path A ─┐
   ├─ packet 1 → path B ─┼→ direct placement / gap tracking
   └─ packet 2 → path C ─┘→ completion only after required bytes arrive
```

讲师说明：先定义问题。ECMP 通常把一个 flow 按 header hash 固定到某条等价路径；两个大 flow 若恰好撞到同一链路，另一条链路空闲，collective 仍被热点链路限制。multipath 让同一个逻辑 connection 使用多个 flow/QP/subflow，甚至把不同 packet/chunk spray 到不同路径，目标是获得更多 path entropy、绕开拥塞和快速避障。

代价是到达顺序不再天然等于发送顺序。假设 packet 1 走慢路径，packet 2 先到：接收端若只知道 First/Middle/Last，可能不知道 packet 2 应落在哪里；若每个 segment 带 message identity + offset，就能先 direct-place 到目标位置，再用 bitmap/gap state 等 packet 1。整个 x[i] 只有在所需 bytes 全部到达并满足 ordering 后才发布 completion。payload 不一定需要集中复制到一个巨大 reorder buffer，但 metadata、gap、duplicate 和 buffer lifetime state 仍存在。

这个设计必须明确选择“允许乱序持有、按 completion/fence 对上层提交”的语义。如果协议又要求论文模型中的 in-order delivery、lossless transmission 与 out-of-order capability 同时成立，就会进入 Orderlock 风险区。[A41] UEC 明确规定跨不同路径不保证到达顺序；Falcon、MRC 和 UCCL 分别在规范、硬件/SmartNIC、生产 transport 或 host software 的不同位置处理这个问题。[A9][A10][A31][A32][A40]

观测时看 per-path bytes/RTT/queue、flow hash 分布、out-of-order depth、duplicate/gap count、retransmission 和 message completion tail。若总带宽不满但某一条 path 满载，属于 path collision；若路径已均衡而 completion tail 仍长，要继续检查 reorder/recovery 和最慢 packet。

## Slide 27｜DDP 的真正启示：把 placement 与 arrival order 解耦

| RFC 5041 DDP model | 分段携带的关键定位信息 |
|---|---|
| Tagged Buffer | `STag + Tagged Offset`，直接放入已 advertised buffer |
| Untagged Buffer | `Queue Number + MSN + Message Offset`，定位 queued message buffer |

讲师说明：`placement` 回答的是“这一段 bytes 应写到哪一个 buffer 的哪一个 offset”。Tagged Buffer 适合已公开远端地址的 one-sided placement：`STag` 类似被授权的 buffer handle，`Tagged Offset` 指定位置。Untagged Buffer 面向 queued receive：`Queue Number` 找到接收队列，`MSN` 找到哪一条 message，`Message Offset` 找到 message 内位置。[A30]

有了这些 metadata，segment 2 即使先到，也能直接写入 `dst + offset_2`，无需依靠 segment 1 推导地址。接收端仍须记录哪些范围已经到、是否重复、何时整个 message 完整；因此 direct placement 消除的是一次中间重排 copy，不是消除所有 reorder state。

不要笼统地说“iWARP 每个包都有 MSN+MO”：它们属于 Untagged Buffer header，Tagged Buffer 使用另一套字段。RFC 5041 本身仍规定可靠、按序 delivery，所以 DDP 是 placement 思想来源，不等同任意乱序 transport。上层看见的仍只是“buffer 已完成”，下层则付出了 protection、offset、gap 和 completion tracking。

## Slide 28｜同样要利用多路径，MRC、Falcon、UCCL 和 UET 改的是不同层

屏幕正文：

| 方案 | 位于哪一层 | payload/control 怎么走 | 主要约束 |
|---|---|---|---|
| MRC | RC-compatible AI transport extension | packet spraying；可用 ECMP entropy 或 static SRv6；SACK/ECN/故障恢复 | 论文报告的 transport 子集仅含 WRITE/WRITE_IMM；部署依赖 endpoint 与网络能力 |
| Falcon | hardware/SmartNIC transport | hardware shaping、RTT、retransmission、multipath | 需要对应 transport hardware/firmware |
| UCCL-Tran | collective 下方的 host software transport | RNIC DMA payload；CPU engine 做 CC/LB/order/recovery | CPU/NUMA、verbs 能力、可见信号 |
| UET 1.0 | wire-level transport specification | 标准化 multipath、ACK/SACK、CC 与 endpoint behavior | 具体 state placement 由实现决定 |

讲师说明：这页不是跑分比较，而是回答“我们站在哪一层改系统”。MRC 是对 RoCEv2 RC 语义的 AI workload 扩展：它在 best-effort/lossy Ethernet（论文部署禁用 PFC）上做 packet-level multipath，并以 SACK/selective retransmission、ECN、路径健康和可选的 packet trimming（在支持 trimming 的部署中用于加速 incast 恢复）处理拥塞与故障；路径可以通过 ECMP entropy 或 source-routed/static SRv6 实现，static SRv6 是论文的一种部署方案，不是 MRC 的唯一要求。OpenAI/Microsoft 的生产经验是论文报告的特定部署结果，不等同于所有 MRC 产品的普遍保证。Falcon 把低延迟可靠 transport 放进硬件/SmartNIC；UCCL 不改 RNIC wire protocol，优先利用 UC，把 GPUDirect payload 留给 NIC，把可扩展控制放到 host CPU；UET 则定义可互操作的 wire behavior 和 transport objects。[A9][A10][A31][A32][A40][A42]

UCCL 的 UC 路径用 `write_with_imm` 让 payload 直接进 GPU、32-bit immediate 进入 CPU control path；UD fallback 用 scatter-gather 把 control header 和 GPU payload fate-share，并由 GPU kernel协助重组。RC fallback 即使关闭硬件 CC，packet reliability 仍由 RNIC 保留。它的 32 KiB control coalescing、256-QP 等选择是论文实现对 CPU 成本、path entropy 和 control precision 的折中，不是通用协议常数。[A40][B16]

所以“支持 multipath”不能单独回答可部署性：还要问应用/NCCL 是否要改、NIC 是否要换、wire 是否兼容、CPU/DPA 是否有预算、谁能看到 ECN/RTT/trim，以及 failure state 落在哪里。MRC 还必须诚实标出语义边界：当前公开论文中的 transport 只定义 RDMA WRITE 和 WRITE-with-IMMEDIATE；SEND/RECV、READ、ATOMIC 不能自动从“RC-compatible”推断为已支持。

### MRC preview：路径韧性与状态边界

> 本节只用 MRC 说明 transport/path 层的状态放置和恢复边界；Topic 5 再讨论它如何影响大规模训练的 recovery critical path。MRC 主要缓解 path、link 和 switch failure，不应写成任意 endpoint failure 的透明容错。

### MRC case study：一次故障为什么没有杀死训练

把这项工作当作一个可验证的生产案例，而不是协议宣传页。OpenAI blog [A9] 适合说明为什么大规模同步训练需要 multipath 和故障韧性；OCP MRC 规范 [A42] 负责 wire semantics；论文 [A10] 才提供这里引用的部署与测量细节：

```text
GPU ranks → multi-plane Clos → ECMP/SRv6 paths
          ↘ packet spray + direct placement ↗
       SACK/NACK + selective retry + ECN/health feedback
```

论文报告的一个 50K-GPU 训练集群案例中，光模块抖动造成约一分钟内约 25% throughput 下降，但训练没有崩溃、QP 没有失败、节点也无需移除；论文报告多路径将受损路径的流量转移到健康路径，并通过选择性恢复快速处理丢失片段；这是该特定部署的观测，不是对所有 MRC 实现的因果或 SLA 保证。这个数字和结论必须带上“paper-reported、特定集群/配置”。[A10]

把证据拆成三类，避免只讲一个漂亮的故障曲线：

| 证据 | 论文中的配置 | 能支持什么 | 不能支持什么 |
|---|---|---|---|
| 生产故障 | 约 50K GPU、CX-8、每 NIC 4×200 Gb/s；T0 光模块连续 flap | 约一分钟内 throughput 下降约 25%，job/QP/节点没有失败 | 不能推出所有拓扑都能无感绕过 NIC 或交换机故障 |
| 大规模交换机故障 | 约 75K GPU 预训练；T1 switch 故障期间约 580K packet drops、约四分之一 QP 受影响 | MRC 可快速避开坏路径，吞吐在初始下降后基本恢复 | 不能把一次运行观察写成故障概率或 SLA |
| 受控丢包对比 | 64-GPU 小集群；MRC 与 PFC+DCQCN RoCE，对 0.1%/1% 注入丢包 | MRC 在短暂/低丢包下选择性恢复更有韧性 | 论文明确指出 1% 持续丢包时 MRC 也只约达到目标吞吐的三分之一，不能宣称“任意高丢包仍高 goodput” |

这三类证据分别对应 resilience、recovery efficiency 和 operating envelope；它们不是同一个 benchmark，也不能拼成跨产品排名。[A10]

还要把论文自己报告的失效边界讲出来：如果是 NIC transceiver 本身 flap，可能同时失去该 NIC 的全部端口，QP 仍会失败，节点也可能需要被移出；MRC 主要缓解的是路径、链路和交换机层面的故障，不是任意 endpoint 故障的透明容错。[A10]

同一论文还报告了特定 Cluster B 配置的 32 KiB back-to-back WRITE、application-level GPU-to-GPU 带宽约 770 Gb/s；另一个 2 B latency 测试（论文表格使用不同的 QP 配置）给出 T0-local 约 5.09 μs、cross-T1 约 6.54 μs（论文将 post-to-sender-completion 的往返测量除以二作为近似单向延迟）。这里的教学重点不是记住 770 Gb/s，而是把测量拆成 Topic 1 的 placement/completion/visibility 证据，再结合 Topic 5 的 critical-path 时间线检查 payload serialization、路径/交换排队、SACK/ACK 与 consumer-visible completion；这些数不能泛化为所有 NIC、消息大小或拓扑。[A10]

case study 的验收问题：

1. 故障发生时，per-path bytes/RTT/ECN/trim、SACK gap 和 retransmitted bytes 是否同时变化？
2. 训练没有失败，是因为 MRC 在 transport 层恢复，还是上层 checkpoint/restart 掩盖了错误？要区分 QP state、job progress 和 application correctness。
3. 若 workload 需要 SEND/RECV、READ 或 ATOMIC，是否回退到另一条 transport/path？回退会不会重新引入 ECMP collision 或 ordering tail？

这组问题把前序课的“connection / path / transaction / completion”语言落到公开可测的事件上，也避免把 MRC 的有限语义子集误说成完整 RDMA 替代品。

## Slide 29｜Go-Back-N、Selective Retry 与 SACK 各自买了什么

| 恢复方式 | 优点 | 代价/风险 |
|---|---|---|
| Go-Back-N | 接收端状态简单、实现紧凑 | 一个 gap 重放后续窗口，长 BDP 下放大流量 |
| Selective Retry | 只重传缺失分段 | 需要精确 gap/duplicate/placement tracking |
| SACK / bitmap | 告知已收到范围，尽快释放发送 buffer | ACK state、bitmap、timer 与协议字段增加 |
| Time-based loss detection / probe | 区分延迟、乱序与真实丢失 | 依赖 RTT 模型，错误阈值会误重传或恢复过慢 |

讲师说明：用发送序列 0、1、2、3 举例。若 1 丢失，Go-Back-N 可能把 1、2、3 全部重发，接收端逻辑简单但浪费链路；Selective Retry 保留已到的 2、3，只要求重发 1，但需要 gap/duplicate tracking；SACK bitmap 把“我已经收到 0、2、3”告诉发送端，既触发精确恢复，也让发送端尽早释放对应 replay buffer。

长 BDP 下恢复方式尤其重要。窗口里可能有 MB 级 payload，一个 gap 若放大为整个窗口重传，会造成新的拥塞和尾延迟；但 selective state 若全放片上 SRAM，又会增加面积和连接规模压力。因此设计不是“先进/落后”二分，而是重传流量、接收状态、ACK 带宽、timer 和 failure latency 的交换。

UEC 的 RUD 路径要求处理 SACK bitmap，ROD 除 probe 外可选；Falcon 公开材料强调快速、准确的重传。[A31][A32] RACK/TLP 可作为时间型 loss detection 思路介绍，但不能说 UEC/Falcon 必然逐条采用 TCP 同名实现。观测时看 loss event 到 retransmit 的时间、retransmitted bytes/lost bytes、duplicate count、replay-buffer occupancy 和 completion P99。

---
## 3.4 Congestion Control, Retry and State Placement

前序第 50 页实际展示的是 SQ/CQ 生命周期；新版 p.64–70 已初步讨论 RC QP 耦合与 network-layer 拆分。本节把该问题放回公开实现重新核对：IB/RoCE QP 常把寻址、PSN/ordering、reliability、path selection 与 SQ/RQ/CQ progress 关联在一个硬件对象及其状态中；不同代际 RNIC 又提供 multi-QP、shared receive queue、DC transport、adaptive routing、selective recovery 或厂商扩展。不能把“单路径、Go-Back-N、PFC、出错即杀 QP”写成所有 RC 实现的永久定义。真正的问题是这些轴能否独立演进，以及状态应由 NIC SRAM、host memory、DPA 还是 software runtime 承担。[A29][A31][A32][A40]

## Slide 30｜拥塞控制：rate/window/credit/telemetry 是设计轴

| 设计轴 | 典型选择 |
|---|---|
| 控制量 | pacing rate、packet/byte window、receiver credits |
| 信号 | ECN、RTT、queue telemetry、packet trimming、ACK/NACK |
| 状态范围 | per-flow、per-destination、per-path、shared CC context |
| 实现位置 | 固定 ASIC、programmable NIC/DPA、host/runtime |

讲师说明：拥塞控制的目标不是让端口永远 100% 忙，而是让进入瓶颈队列的 bytes 与其服务能力匹配。rate/pacing 决定单位时间发多少，适合抑制 burst；window 限制尚未确认的 in-flight bytes，更直接绑定 BDP；receiver credit 限制接收端允许的新数据，保护 last hop/buffer；telemetry/ECN/RTT/trim 是观察拥塞的信号，不是控制动作本身。

假设 8 个 sender 同时向一个 expert rank 发 50 GB/s，而最后一跳只能接收 50 GB/s。没有控制时瞬时输入 400 GB/s，队列迅速增长；pacing/window 降低发送，receiver credits 按可用 buffer 发放许可，ECN/RTT 反馈则告诉 sender 队列正在增长。反馈太慢会 overflow 或形成长 queue，过度反应又会让链路空闲。因此需要同时看利用率和 queueing delay。

不能把“rate-based 必然差、window-based 必然好”当结论。UEC 同时定义 network-signal CC、receiver-credit CC、transport flow control 与 packet window；Falcon 使用细粒度 RTT、hardware shaping、快速重传与 multipath；ConnectX-8 文档可确认 advanced routing 和 telemetry-based CC，DOCA DPA 暴露 programmable CC events，但本稿不反推未公开 PSA 内部流水线。[A31][A32][A35][A36]

UCCL 把控制从 packet 放宽到 chunk/RTT 粒度：默认约 32 KiB control coalescing，用 NIC timestamp 和 loss 等软件仍可见的信号，由 CPU engine 做 pacing/path selection。这证明软件控制可以工作，但 CPU 看不到 RNIC 已消费的所有 ECN/trim/vendor telemetry，也不具有完全相同的 reaction time。[A40] 观测需同时包含 RTT/queue、ECN/trim/loss、cwnd/rate/credit、sender idle 和 receiver buffer occupancy。

## Slide 31｜五种 design profile：可靠性成本放在不同位置

| Profile | 正常交付与恢复 | 多路径/乱序 | 端点状态取舍 |
|---|---|---|---|
| UALink 1.0 | FEC/CRC + accelerator↔switch 每段 LLR + credit FC | 单层 switch；正常路径 lossless | link RTT replay buffer；高层错误走 RAS/drop/isolation |
| SUE full | LLR + PFC/CBFC + end-to-end Go-Back-N | 每 plane 单路径，可由外部跨接口均衡 | reliable transport + fixed-window CC |
| SUE Lite | LLR + lossless traffic class | 假定每 plane 按序 | 无 end-to-end reliable transport、无 CC |
| UET 1.0 | endpoint ACK/NACK、SACK、retry，可运行于 best-effort/lossless | multipath + RUD/ROD | 更丰富 PDC/CCC、timer 与 tracking |
| UCCL-Tran | UC/UD 软件可靠性；RC 保留硬件可靠性；控制策略在 host CPU | 软件多 QP、细粒度 spraying、GPU-memory reorder | 不改 RNIC；受 CPU、verbs 与可见拥塞信号约束 |

讲师说明：这些不是同层、同目标产品的跑分表。UALink/SUE 面向短距 scale-up，UET 1.0 的重点是 backend scale-out。Broadcom 官方规范称 SUE Lite 通过移除 reliable transport、congestion control、AXI datapath 等简化，使“整个 SUE IP”最多缩小 50%；MAC/Link/PHY 大小不变，也不等于整个 XPU I/O die 减半。[A32][A33][A34]

UCCL 与 Falcon/UEC 的关系也要分开：UCCL 是基于现有 RNIC verbs 的软件 endpoint/transport 实现，目标是快速试验并部署新的 control policy；Falcon 更接近硬件或 SmartNIC 中的可编程 transport；UEC 是 wire-level 规范。UCCL 的 multipath 不自动让底层 wire protocol 变成 UET，也不保证跨厂商 NIC 拥有相同的硬件能力。[A31][A32][A40][B16]

前序词汇表可以在这里充当一组对照问题：应用关系、packet reliability resource 和 physical route 是否能独立变化？UET 的 PDC/CCC、Falcon 的 connection/subflow、UCCL 的 logical connection 与共享 QP pool 分别给出不同答案；其 object、wire identity、failure semantics 与 state placement 也都不同。这个对照只说明拆分维度有解释力，不表示这些协议或实现采用了前序的同一对象模型。

读这张表时要做一个固定练习：若 x[i] 在中间丢失或迟到，谁检测、谁保留重放数据、谁限制新流量、谁最终通知 B？答案分别落在 link endpoint、XPU transport、host CPU、RNIC 或 UET endpoint。上层 collective 可能完全透明，但可观察证据不同：LLR replay/credit、transport retry、CPU engine utilization、QP/connection state、completion timeout。只有把状态位置写出，才有资格比较面积、延迟和可编程性。

## Slide 32｜BDP 最终会变成 buffer、状态与 Die 面积

```text
in-flight bytes ≈ bandwidth × RTT

800 Gb/s × 20 μs ≈ 2 MB
1 TB/s   ×  2 μs ≈ 2 MB
```

需要付费的并不只有 payload buffer：

- replay buffer 与 ACK release state；
- gap/duplicate/reorder 或 direct-placement metadata；
- per-destination packing queues 与 RX/TX queues；
- QP/PDC/CCC、timer、outstanding transaction 与 protection metadata。

讲师说明：以 `1 TB/s × 2 μs` 为例，若想让链路持续忙，系统中约有 2 MB bytes 尚未完成；这不代表必须有一块恰好 2 MB 的单一 buffer，而是这些 bytes 和对应 ownership 必须存在于 source queue、replay RAM、network queue、destination buffer 或其他可追踪位置。若做 8 条 path，还要决定状态按 connection 共享还是按 path 分裂；若同时面向许多 destination，又会出现 per-destination queue fragmentation。

Little's Law 只给数量级下界，不能由带宽直接反推某个 IP 的 mm²。状态也不按同一维度增长：per-link replay、per-destination queue、per-QP context、per-subflow context 的扩展性完全不同。上层症状通常是 window 太小导致带宽打不满、buffer 太深导致 P99 上升、state cache miss 导致多连接性能下降。证据是 in-flight bytes、replay/queue occupancy、outstanding depth、context miss 与 completion latency。UALink 明确要求 TxReplay 覆盖 link RTT；规范示例中 200 Gb/s、1 μs 约为 25 KB，即约 40 个 640-byte data-link flit。[A33]

## Slide 33｜Scale-up / scale-out 融合的关键：可靠性边界放在哪里

```text
XPU local memory fabric
   ↕ short-RTT transaction / simple link protection
I/O memory or communication appliance
   ↕ buffered, reliable, multipath inter-rack transport
remote I/O memory or communication appliance
   ↕ short-RTT transaction
remote XPU
```

讲师说明：不必强迫一套协议同时覆盖片内、机柜内与跨机柜。可让 XPU 只面对短 RTT transaction，把 inter-rack 所需的 MB 级 buffer、timer、multipath 和 retry 放到独立 I/O memory/DPU/communication appliance；远端 XPU 再从其本地 appliance 读。这样把长距失败隔离在边界外，也减少 XPU die 上的长 BDP state。

但这不是免费“大坝”。A 必须先把 x[i] 的 ownership 交给本地 appliance，appliance 何时可覆盖 buffer；跨 rack 失败是否重试；远端 appliance 何时 publish；B 读取时如何保证版本与 ordering；appliance 自身掉电如何恢复，都需要协议。新增 staging/copy 与 hop 也可能使小消息更慢。验证时比较 XPU-visible RTT、appliance queue/buffer、inter-rack utilization、extra-copy bytes、publish latency 和 failure recovery。NetDAM 只作为这种思想的研究原型，不是行业标准事实。[A39]

---
## 3.5 软件如何把依赖变成工作：Progress, Completion and Recovery Ownership

> 本节坐标：回到第 0–4 层，补齐 transport 上方的控制 owner。解释 workload dependency 如何被翻译成可执行 schedule，以及 CPU、GPU、NIC/DPU 中究竟谁负责持续推进、发布完成与处理错误。

### 3.5.1 Control Plane, Data Plane and Collective Libraries

## Slide 34｜一次通信有三类逻辑角色，recovery 是异常闭环

```text
control / metadata: group / route / buffer / connection / credit / policy
                    CPU/runtime ──────────────────────────────┐
payload:            GPU A HBM ── DMA / fabric ──> GPU B HBM   │
completion / publish: ACK/CQE/immediate/counter/signal/event ─┤
recovery loop:      timer/NACK/retry/failover/runtime error ──┘→ update state / consumer decision
```

讲师说明：framework 的 `all_reduce(x)` 只声明“这些 rank 上的 tensor 按某个 op 归约”。这里区分的是三类逻辑角色，而不是三条必然独立的物理路径：control/metadata 决定 rank、算法、chunk、channel、目标 buffer、connection 和生命周期；payload 搬运真正被消费的 bytes；completion/publication 让某项本地或远端义务、目标 readiness 或 source lifetime 释放变得可观察。recovery 是异常控制闭环，在缺失、超时或端点故障后更新状态、安排重试/切换，或向 runtime 报错。同一个 endpoint 或链路可以承载多个角色，completion 也可能 piggyback 在控制消息上。

因此，“任何一条路径停住”应理解为：某一类必要职责停住，并且它位于 GPU B 的 readiness dependency 上。payload 停住会缺 bytes，control/metadata 停住会缺 identity、placement 或 progress，必要的 completion/publication 停住会让 B 继续等待；这些都可能表现为 consumer kernel 未启动、polling 或 pipeline bubble。反之，与 B 无关的 source-side CQE 延迟可能只阻塞 A 复用 source buffer，并不一定阻塞 B 的消费。

这里必须区分 API 返回与操作完成。异步 API 返回通常只表示 work 已排入 stream/queue，不表示 payload 已到 B；sender CQE 也可能只证明本地/transport completion，不自动等于 B 的 consumer 已经执行 acquire/fence。分析性能时分别测 control-plane setup、steady-state data rate 和 completion latency。

UCCL-Tran 插在 collective library 与现有 RDMA primitives 之间：应用仍使用 NCCL 风格接口，plugin/CPU engine 管连接、memory registration、QP/path、CC/LB/order，并在 UC/UD 路径处理 ACK/retry；payload 仍由 RNIC 通过 GPUDirect DMA GPU memory。当前开源仓库另有 UCCL-P2P 与 UCCL-EP，接口和目的不同，不能把它们当成原论文同一个 datapath。[A40][B16]

一个非常实用的观测方法是给三类逻辑角色和 recovery 闭环分别着色：CPU trace 看 setup/post/poll，GPU trace 看 producer/consumer，NIC/link counters 看 payload，ACK/retry/counter 看 completion 与 recovery。即使多个角色共用同一物理链路，也要在时间线上分别标出它们的证据。若 payload 很快而 required publication 慢，上层仍表现为通信慢；若 control setup 只在首轮慢，应与 steady state 分开报告。

## Slide 35｜Progress 决定“谁让通信继续向前走”

屏幕正文：

```text
enqueue work ≠ make progress ≠ observe completion

progress 可能由：
application thread / CPU polling thread / GPU persistent kernel /
NIC ASIC / DPA-SmartNIC core / receiver credit engine 完成
```

讲师说明：这是零基础听众最容易忽略的一层。应用已经调用 `send()`，但如果实现要求 CPU poll 而 CPU 被抢占，WQE 可能尚未及时 post，ACK/CQE 也无人消费；若使用 GPU persistent kernel，则会长期占 SM；若全部 offload 到 NIC，则可编程性受硬件能力限制。所谓 asynchronous 只表示调用者无需同步等待，不保证系统中没有某个 progress engine 在持续工作。

MPI 的 communicator、point-to-point、collective 和 progress semantics 是理解这一问题的经典入口。GPU-aware MPI 允许传入 device pointer，但具体是否 GPUDirect、谁推进 UCX/libfabric、何时产生 completion 取决于实现；它不是 MPI 标准对某条硬件路径的保证。[A38]

观测上把 CPU scheduling/poll loop、GPU communication kernel residency、WQE post rate、CQ depth 和 NIC DMA 放在同一 timeline。若 wire 空闲而 CPU progress thread 出现长 gap，优化网络拓扑不会解决问题。

## Slide 36｜一次 NCCL AllReduce 如何变成可执行工作

屏幕正文：

```text
all_reduce(tensor)
  → choose rank graph: ring / tree / hierarchy
  → split tensor: channel → chunk → slice
  → launch communication/reduction kernels
  → map each edge to P2P, NVLink/PCIe or NET plugin
  → send / receive / reduce / copy / signal
  → stream event lets dependent compute continue
```

讲师说明：以 ring 为例，一个 rank 不是把完整 tensor 一次发给所有人，而是先切 chunk，经过 ReduceScatter 多步传递并在中途 reduce，再经 AllGather 传播最终 shard。这样能流水化链路，但每一步都依赖上一 chunk 的到达和 reduction 完成。NCCL 还要根据拓扑决定 channel、ring/tree、协议和本地/网络 transport。用户看见一个 API，下面已经形成了一个 distributed schedule。[A15]

排查时从三个层次取证：`NCCL_DEBUG`/拓扑日志确认算法和 transport，GPU timeline 确认 kernel/stream gap，NIC/NVLink counters 确认实际 path 和利用率。如果 ring 顺序跨 NUMA 或某个 channel 映射到慢 NIC，表现会像 collective bandwidth 下降；如果 GPU reduction kernel 占满 SM/HBM，链路未满也可能是正常的。

UCCL-Tran 可作为 NCCL network plugin 替换一部分 NET transport control，但不会替 NCCL 选择整个 collective 算法，也不会改变节点内所有路径。仓库后续加入的 P2P/EP 能力不能倒推为原论文当时已完整覆盖。[A40][B16]

## Slide 37｜谁发起不等于谁搬 payload，也不等于谁恢复错误

| 角色 | 需要回答的问题 | 可能的执行者 |
|---|---|---|
| Initiator | 谁创建本次 operation？ | application CPU、GPU kernel、scheduler |
| Progress engine | 谁不断 post/poll/发 credit？ | CPU thread、persistent GPU kernel、NIC/DPA |
| Data mover | 谁真正读写 payload？ | GPU copy/TMA、RNIC DMA、fabric endpoint |
| Completion owner | 谁宣布 source 可复用 / destination 可消费？ | CQ engine、counter/signal、GPU event/fence |
| Recovery owner | gap/timeout/endpoint failure 后谁处理？ | link、RNIC transport、host software、runtime |

讲师说明：一条路径可以是“CPU initiated + NIC payload DMA + NIC reliability”，也可以是“GPU initiated + NIC payload DMA + CPU software CC”，还可以是“GPU persistent kernel 自己 put/signal + fabric endpoint replay”。因此“CPU-driven”或“GPU-driven”都不够精确，必须把五个角色逐一填完。比如 UCCL 的 host CPU 是重要 progress/control owner，但 payload 仍由 RNIC DMA；device-side API 可由 GPU 发起，link replay 仍在 endpoint。

NCCL Device API 的 LSA/GIN、NVSHMEM、SHMEM-style put/get/signal 属于 device-initiated 方向：它们减少 host launch gap，让通信与 tile 依赖更紧；代价是 persistent resources、memory ordering 和调试复杂度。两者的 API、progress 与支持拓扑不能互相替代。[B1][B13]

UCCL-Tran 是另一种折中：GPU payload 走 GPUDirect，host CPU 运行 TX/RX、pacing 和路径控制，并在 UC/UD 路径负责 ACK/重传；RC 仍使用 NIC hardware reliability。论文在其 400G 测试条件下用 control coalescing 等方法把 CPU 成本摊薄，但实际部署仍要核算 CPU core、NUMA、polling、QP context 和信号可见性。[A40][B16]

定位时也按五角色找证据：API 到 WQE 的 gap 指向 initiator/progress；payload counter低指向 data mover/path；bytes 已到但 consumer 未启动指向 completion；loss event 后长时间无进展指向 recovery。这样能避免“CPU 在参与，所以不是 RDMA”或“GPU 发起，所以 CPU/NIC 完全不参与”这类错误推断。

## Slide 38｜Offload 的本质是移动 critical-path work，不是让工作消失

屏幕正文：

| 被移动的工作 | 从哪里移到哪里 | 可能省下什么 | 新成本 / 新证据 |
|---|---|---|---|
| connection / policy / telemetry | host CPU → DPU/NIC core | CPU jitter、host isolation | DPU cycles、firmware queue、upgrade/debug |
| DMA / packet transport | CPU copies/kernel stack → NIC ASIC | copy、syscall、packet CPU | NIC SRAM、WQE/CQ、PCIe/DMA limit |
| collective reduction | GPU/endpoints → NIC/switch/fabric engine | network bytes、SM/HBM traffic | group/tree/op state、fallback |
| storage/KV movement | serving worker → DPU/appliance | CPU work、data-path isolation | staging、metadata、ownership/failure |

讲师说明：offload 不是一个开关，而是“把哪段工作从哪个处理器搬到哪个处理器”。连接/telemetry 下沉可降低 host jitter；NIC DMA 省 CPU copy；switch reduction 省重复 network/GPU work；KV appliance 移走 storage protocol。每种 offload 只改变 Slide 3 的某些层，payload、completion 或 recovery 的其他部分仍在。

判断 offload 是否有效，不能只看 CPU utilization。要看端到端 critical path 是否缩短、是否少了一次 memory copy/doorbell、tail 是否改善，以及错误路径是否更难恢复。常见误区是“offload 后 CPU 不忙，因此通信一定更快”；如果 DPU core、NIC SRAM 或 PCIe 成为新瓶颈，只是把队列移了位置。

DOCA 是 BlueField/DPU 的基础设施与加速 SDK，不是 NCCL/MPI 的同层替代；SHARP 是 collective reduction offload，UCCL 是 host software transport。验证时除 CPU 外，还看 DPU core/queue、NIC SRAM/context、PCIe transactions、wire bytes、GPU SM/HBM 和 fallback count，才能证明工作被消除还是仅被搬走。[A6]

---

# 4. Workload 如何塑造 Traffic、Progress 与 Wait-for Graph？（81–142 min）

> 本章坐标：前面已经知道路径和 state owner；现在把 `workload dependency → traffic pattern → message/token/object granularity → topology/queue contention → progress/synchronization → wait-for graph → exposed critical path` 串起来。重点不是罗列 API，而是解释谁在等谁、谁推进通信、哪里发生 contention，以及一个局部 stall 如何传播到 collective。

## 4.1 Collective Pattern: Where Should Reduction Execute?

## Slide 39｜In-network reduction 的价值不只是在链路上少发 bytes

```text
Ring AllReduce per-rank traffic ≈ 2 × (p-1)/p × message_size

endpoint partials → aggregation tree / multicast-reduce engine → result
```

| Reduce 位置 | 主要收益 | 主要约束 |
|---|---|---|
| GPU kernel | 最灵活 | 占 SM、HBM/L2 traffic、同步 |
| NIC/DPU | endpoint offload | NIC state、数据类型与编程接口 |
| Switch / SHARP | 减少重复 fabric traffic | 资源、树、算子与故障恢复限制 |
| Shared-memory fabric / NVLS 类 | 减少 endpoint 搬运与 HBM 干扰 | memory semantic、counter、地址域耦合 |
| Dedicated on-package collective engine（设计点） | 距计算更近 | silicon area、协议耦合、可编程性 |

讲师说明：先定义 reduction：多个 rank 各有同形状 partial tensor，要按元素做 sum/max 等结合操作，再把结果送回需要的 rank。普通 ring 把 chunk 沿端点逐跳传递，每一跳由 GPU 读入、reduce、再发出；aggregation tree 则让 switch/NIC/fabric engine 在中间汇聚 partials，减少相同 bytes 重复穿过上层链路。

收益不只是一条链路少发 bytes。若 GPU 不再反复读写 partial buffer，可以少占 HBM/L2、SM 和 synchronization；但中间设备必须知道 group/tree、dtype、op、chunk identity、participant state 和错误回退。若任一 rank 缺失，中间 partial result 如何撤销、重试或回退也比普通 packet forwarding 更复杂。

固定、可结合、shape 规则的 AllReduce 更适合下沉；DeepEP 式动态 token dispatch、路由和大量 metadata 不天然适合 switch reduce。SHARP 与 NVSwitch shared-memory collective 论文是两类公开案例。前序的 `Aggregation Engine` 是其架构中占地址空间的端点；这里的 SHARP 是 switch/fabric reduction placement，不是同一个对象。`on-package collective engine` 也只是设计点，本稿没有足够一手资料确认所谓 Ascend 950 CCU 的内部微架构。[A14][A37]

观测时同时看 network bytes、GPU HBM traffic、communication-kernel SM time、tree setup、reduce-engine occupancy 和 fallback/error count。若 wire bytes 下降但 GPU 等待未降，瓶颈可能在 tree setup、completion 或结果分发，而不是 reduction 算力。

---
## 4.2 P2P and Object/State Movement

## Slide 40｜P2P 不只是 bytes：它搬的是有生命周期的对象

屏幕正文：

```text
object = payload + shape/layout + object/request id
       + source/destination placement
       + ownership/lifetime + completion/error state
```

讲师说明：`send(ptr, bytes)` 只描述 payload 范围，没有回答接收端把它放到哪个请求、哪个 layer、哪个 token range，也没有回答 sender 何时可复用 buffer、receiver 超时后是否可重试。PP activation、PD KV、RL 权重、remote cache 都使用 P2P，但生命周期完全不同：activation 在一个 microbatch 后失效，KV 可能跨多轮复用，权重更新还要求版本一致性。

以 PD KV 为例，control plane 先决定 decode worker 和目标 pool，交换地址/handle 与 request metadata；data plane 搬 KV blocks；completion 更新 block table 或 ready state；失败路径处理重复传输、部分到达和 worker 退出。真正的性能指标因此不只是 GB/s，还包括 setup latency、bytes/object、P99 completion、buffer occupancy、cache hit 和 orphan object 数量。

## Slide 41｜Mooncake 把“怎么搬”和“对象放哪儿”拆开

屏幕正文：

```text
Transfer Engine: heterogeneous zero-copy data movement
Mooncake Store: distributed object/KV storage + placement/lifecycle
```

讲师说明：Transfer Engine 负责具体数据路径：选择 RDMA/TCP/NVLink 等 transport、注册/映射内存、做多段 transfer 和 completion；Mooncake Store 再负责 object/KV 的 key、placement、replica、eviction 和生命周期。前者回答“怎样把这些 bytes 送到指定内存”，后者回答“哪个副本存在、谁拥有、何时淘汰、失败后去哪里找”。[A16][B2]

这解释了为什么零拷贝还不够：即使 payload 直接 DMA，metadata lookup、placement decision、memory allocation、admission 和 completion publish 仍可能在 critical path。排查时分别测 transfer engine 的网络/内存时间与 store 的 lookup/placement/queue 时间，避免把 storage control latency 归因成 RDMA bandwidth。

## Slide 42｜同样是 P2P，PP activation 与 PD KV 的等待关系不同

| | Pipeline Parallel | Prefill–Decode disaggregation |
|---|---|---|
| 对象 | activation | KV cache/state |
| 生命周期 | 单 microbatch/stage | 请求级、可复用、可持久化 |
| 关键风险 | bubble、backpressure | placement、cache miss、decode admission |

讲师说明：PP 的 stage B 通常必须立刻消费 stage A 的 activation；发送太慢直接形成 pipeline bubble，接收端 buffer 太少则反压前一 stage。PD 中的 KV 是请求级状态：可以提前预取、在 host/remote tier 等待、被多个后续 token 复用；但 decode admission 必须确认所需 blocks 已经可见。PD 因此不是把 PP send/recv 复用一次，而是增加 placement、cache miss、request lifecycle 和 failure recovery。

两者的观测也不同。PP 看 microbatch timeline、send/recv gap、stage bubble 和 queue depth；PD 看每请求 KV bytes、transfer P99、block-ready 时间、decode admission wait、cache hit/miss 和 host/GPU pool occupancy。

## Slide 43｜DualPath 通过增加路径，改变谁在等存储

屏幕正文：

```text
traditional: storage → prefill → decode
DualPath:    storage → prefill
             storage → decode
             dynamic load balancing between paths
```

讲师说明：传统路径把 storage load、prefill compute 和 P→D transfer 串成一条依赖；即使 decode 端有空闲 NIC，也必须等 prefill 侧取完。DualPath 增加 storage→decode，调度器可并行使用 P、D 两侧路径，并按负载决定 KV 从哪边进入。它优化的不是单个 packet，而是把一段串行 critical path 改成两个可并行服务站。[A17]

新增路径同时增加一致性与调度问题：两边不能对同一 block 发布冲突版本，decode 必须知道哪些 blocks 已到，存储和 NIC 带宽也可能共享瓶颈。验证时比较 storage read、P/D NIC、P→D transfer 和 decode admission 的时间线，而不是只报告总 network throughput。

---
## 4.3 EP and MoE Communication

## Slide 44｜一个 MoE token 要经历七个步骤，all-to-all 只是中间一段

屏幕正文：

```text
1 router 选择 top-k expert
2 count / quota 决定每个 destination 的 token 数
3 prefix / layout 计算目标 offset
4 pack payload + token/expert/source metadata
5 dispatch 到 expert rank 的 receive buffer
6 grouped GEMM 读取 expert-major layout
7 combine 回源并按 top-k 权重归并
```

讲师说明：假设一个 token 的 hidden state 发送给两个 expert。payload 只是 hidden vector；还要携带 token id、source rank、top-k slot/weight、目标 expert 和目标 offset，接收端才能计算并在 combine 时写回正确位置。若 destination count 未知，需要先 count/prefix 或使用预留 buffer；若热点 expert 超出 quota，会产生 drop、padding、reroute 或等待。

因此只测一个均匀 all-to-all 会漏掉 router/count、pack/layout、remote completion、GEMM 等待和 combine reduction。应记录每 rank/expert token count、max-to-mean、pack/unpack kernel、network bytes、receive-ready 时间、expert GEMM start 和 combine completion。

把透明层次逐个点出来：模型代码通常只看见 MoE layer；runtime 隐藏了 router output 到 destination count、offset 和 buffer allocation；EP 库隐藏了 pack、transport、notification 与 combine；RNIC/fabric 继续隐藏 packet path 和 recovery。任何一层变慢，用户看到的都可能只是 MoE layer latency 上升。诊断必须从 token histogram 开始，再沿 metadata/layout、payload、completion 到 GEMM，而不是直接从 NIC counter 开始。

## Slide 45｜DeepEP 隐藏的是一套 dispatch/combine 协议

屏幕正文：

```text
router output + token buffer
  → count/prefix + buffer layout
  → scale-up / scale-out transfer
  → receive counters / notification
  → expert-ready buffer
  → combine transfer + source-side reduction
```

讲师说明：DeepEP 不是给 `all_to_all` 换一个更快实现，而是针对 EP 提供 high-throughput 与 low-latency 的专用 GPU communication kernels。它必须管理 token layout、source/destination metadata、buffer capacity、跨 NVLink/RDMA 的 hybrid path、completion/notification 和 combine。V2 公开方向转向 NCCL GIN backend、统一 ElasticBuffer，并强调减少 SM 占用；这再次说明 payload path、control state 和 compute resources 要一起设计。[B3]

对零基础听众要明确：kernel launch 后仍有一套协议在运行。发送端何时可覆盖 slot、接收端何时启动 expert GEMM、不同 phase 如何复用 counter，都是正确性和性能状态。项目性能数字必须连同 shape、dtype、NIC、拓扑、版本和 SM 占用引用；不能把某个 benchmark 当成所有 MoE 的通用提升。

## Slide 46｜NCCL EP 用两条执行路径服务不同消息形态

屏幕正文：

```text
LL: direct P2P all-to-all for latency-sensitive inference
HT: NVLink intra-node aggregation + RDMA inter-node hierarchy
LSA + GIN: GPU-initiated data path
```

讲师说明：LL path 面向 latency-sensitive inference，倾向 direct P2P、少聚合和短 startup；HT path 面向更大 batch，先在 NVLink 域内聚合，再用 RDMA 跨节点，换取更高链路效率。LSA/GIN 提供 GPU-initiated data path，使 producer/consumer kernel 可以更紧密地协调。两条路径的区别不是一个“快慢开关”，而是消息大小、并发、拓扑和资源预算不同。[B1]

验证时按 token count/message size 分桶，分别看 startup、SM 占用、NVLink/RDMA bytes 和 P99；不要只用一个平均带宽把 LL 和 HT 混在一起。仓库仍持续演进，接口和结果必须绑定版本。

## Slide 47｜热点 expert 让“计算不均”直接变成网络 incast

| 项目 | 核心决策 |
|---|---|
| UltraEP | 基于当前 post-gating load 实时复制热点 expert，并在 scale-up domain 内 reroute |
| MoonEP | dynamic redundant experts + symmetric-memory weight layout，目标是固定 rank compute load |

讲师说明：当一个 expert 接收的 token 是平均值的数倍时，问题同时发生在三层：多个 sender 在最后一跳形成 incast；目标 rank 的 receive/GEMM queue 变长；其他 rank 已完成却在 combine/barrier 等待。只做 transport CC 能保护队列，却不能消除 expert 计算偏斜。

传统 auxiliary loss/EPLB 偏慢时间尺度；UltraEP/MoonEP 把 replica placement、weight sync 和 reroute 推进到 layer/microbatch critical path。它们通过多副本分摊热点，但要付出权重拷贝/同步、额外 slot、gradient reduction、route plan 和 cache 容量。[B4][B5]

要同时看网络与计算证据：per-expert token histogram、receiver ingress queue、expert GEMM duration、replica sync bytes 和 combine wait。只看到 P99 network latency 上升时，不应立即认定是 transport 算法问题。

## Slide 48｜Expert replica 应放在哪，取决于“省下的等待”能否覆盖同步成本

屏幕正文：

```text
replicate hot experts inside fast domain
route bulk tokens across slower domain only when necessary
```

讲师说明：在快速 scale-up domain 内复制热点 expert，token reroute 可以少跨慢网络；但每个 replica 需要权重容量、版本同步和训练时 gradient reduction。跨 rack 复制可能增加 fault blast radius 和同步流量。一个简单判断是比较：被消除的 dispatch/combine tail + GEMM queue wait，是否大于 replica 创建/同步/调度成本。

UltraEP 的公开实现把复制与 reroute 约束在其支持的 NVLink scale-up domain，这说明 EP placement 不能脱离硬件域。更大的 rack-scale fabric 可能改变“一 rank 一 expert”的默认假设，但不会消灭 ownership、版本和 failure semantics。[B4]

## Slide 49｜EP 设计决策表

| 决策 | 低延迟偏好 | 高吞吐偏好 |
|---|---|---|
| dispatch | direct P2P | hierarchical aggregation |
| layout | 少 metadata / 固定 buffer | expert-major / padding 友好 GEMM |
| load balance | replica / quota | 更大 batch 平滑 |
| resources | 少 SM、低 startup | 更多 pipeline、channel、buffer |
| precision | BF16/FP8/FP4 traffic | 精度与 packing 开销权衡 |

讲师说明：这张表不是让听众挑一个固定方案，而是训练权衡。低延迟路径希望少 launch、少 metadata、少 hop、少 SM；高吞吐路径愿意用更大 chunk、层次聚合、更多 buffer 和 pipeline 来摊薄开销。实际选择必须同时写出 token size/distribution、top-k、group size、scale-up domain、NIC 数量、dtype、可用 SM/HBM 和 tail SLA。

诊断顺序是：先确认 router skew 和每 expert 工作量，再确认 layout/pack 与 buffer，随后看 physical path/CC，最后看 combine completion。若跳过前两步，仅调网络参数，很可能只移动瓶颈。

可用一个反例检查理解：若网络端口只有 55% 利用率，但热点 expert 的 GEMM queue 很长、receiver credit 不再发放，增加 NIC 带宽不会改善；若各 expert 工作量均匀、GEMM 空闲，而 pack kernel/小消息 startup 占主要时间，应先改 layout、batching 或 LL path；若某 rail 满而其他 rail 空，才进入 path/multipath 问题。三种现象在上层都可能叫“EP communication slow”，底层原因完全不同。

---

---
## 4.4 Locality and Overlap：缩短暴露的等待

> 本章坐标：不再逐层孤立优化，而是检查 placement、chunk、progress、completion 与 consumer dependency 能否共同缩短 Topic 1 所定义的 consumer-visible critical path。

### 4.4.1 Topology, NUMA and Locality-Aware Placement

## Slide 50｜MCM 的三角约束：数据、任务与缓存必须一起放

```text
address / page placement
        ↕
CTA / tile placement  ↔  cache placement and sharing
```

| 选择 | 收益 | 代价 |
|---|---|---|
| 地址均匀交错 | 容量和内存通道更易均衡 | 更多访问可能跨 Die |
| 强任务亲和性 | 提高 local reuse、减少跨 Die traffic | 尾部 CTA 或不规则 workload 可能失衡 |
| 缓存远端数据 | 降低重复远端流量 | 占用容量，并引入 lifetime / coherence 管理 |

讲师说明：NUMA 的直观含义是“地址都可访问，但不同地址离当前执行位置的距离不同”。若 CTA 在 die 0 执行、数据主要在 die 1/HBM1，每次 load 都要跨 die-to-die link；把数据 first-touch 到本地、把 CTA 调度到数据旁边，或缓存重复访问的远端 line，都可能减少通信。反之，强行保持 locality 可能让某个 die 任务过多，形成 load imbalance。

因此有三个相互制约的决策：`where data lives` 决定 page/address placement，`where work runs` 决定 CTA/tile placement，`where reuse is captured` 决定 cache/replica。只优化一项常把瓶颈推给另一项：地址均匀交错平衡容量，却增加远端访问；强亲和减少 remote bytes，却可能形成尾部 CTA；缓存远端数据省链路，却占容量并增加 lifetime/coherence 管理。

2017 MCM-GPU 论文用 remote-only L1.5、distributed CTA scheduling 和 first-touch page placement研究这一组合；它们是研究方案，不是 Blackwell 产品披露。[A24] 观测上需要 per-die HBM、die-to-die bytes/latency、CTA residency、cache hit 和 kernel tail，而不是只看逻辑 GPU 的总 HBM bandwidth。

## Slide 51｜从 NUMA 论文得到的通信设计原则

| 研究路线 | 解决的问题 | 对今天的启发 |
|---|---|---|
| MCM-GPU / first touch | page 与 CTA 缺少亲和性 | placement 是通信优化的一部分 |
| CARVE | remote working set 大于片上 LLC | 可用本地显存换远端带宽，但要管理一致性与容量 |
| HMG | hierarchy 下 flat sharer tracking 太贵 | coherence / consistency 应利用 scope 与拓扑层次 |
| PROACT / FinePack | sub-cacheline P2P 低效，bulk DMA 又阻塞流水 | 跟踪 readiness，并把细粒度写聚合成链路友好的 message |

讲师说明：四个词必须分开。`locality` 只说物理距离；`coherence` 保证多个 cache 副本的值如何保持一致；`consistency/scope` 规定不同线程/设备何时必须观察到某次写；`flush/invalidate` 只是实现这些语义的某类动作。一个系统可以地址可达但不 coherent，也可以 coherent 但远端访问仍更慢。

CARVE 用本地显存容量缓存 remote working set；HMG 研究 hierarchy 下如何缩小 sharer/coherence tracking；PROACT/FinePack 跟踪细粒度 store 的 readiness，再聚合成更适合链路的 message。它们分别说明容量、状态、granularity 和 completion 都能决定 scale-up 性能；均是论文方案，不应说成 GB200 已采用。[A25][A26][A27][A28]

落到 Slide 2：若 x[i] 只写 16 B，直接发一个带固定 header 的 transaction，wire efficiency 很低；等待更多 writes 合包能提高效率，却增加 packing latency 和 per-destination queue。若 consumer 很快就要这 16 B，低延迟可能比带宽效率更重要。观测要把 remote bytes、transaction-size histogram、packing wait、cache hit、fence/completion stall 和 consumer deadline 放在一起。

建议图示：横向画 `fine-grained load/store → coalesce/track readiness → efficient message → remote placement/cache`；下方单独放四个标签 `locality / granularity / completion / consistency`。

---
### 4.4.2 Compute-Communication Overlap and Async Data Movement

## Slide 52｜Overlap 只能隐藏“依赖允许且资源可并行”的那一段

屏幕正文：

```text
串行： produce all ─ communicate all ─ consume all

流水： produce chunk i+1
           ├─ communicate chunk i
           └─ consume chunk i-1

exposed communication = communication - safely hidden portion
```

讲师说明：先把 tensor 切成可独立发布的 chunk。producer 必须在 chunk i ready 后才能发；consumer 必须等 chunk i 完成并满足 ordering 后才能算。overlap 的收益来自把“等待完整 tensor”改成“等待当前需要的 chunk”。如果 consumer 仍要等所有 chunk，或者算法无法在 partial result 上继续，切得再细也不能缩短 critical path。

第二个前提是资源可并行。通信可能占用 SM 做 pack/reduce/poll，也会读写 HBM/L2；compute 也使用同一资源。如果两者都饱和 HBM，timeline 上重叠只是带宽互相稀释。衡量时计算 `exposed_comm = step_with_comm - ideal_compute`，并看 producer-ready→send、receive→consumer-start 的 gap，而不是只看两个 kernel 的矩形是否重叠。

## Slide 53｜Multi-stream 只表达依赖，真正并发还需要资源预算

屏幕正文：

```text
stream + event express dependency
chunking creates independent work
resource partitioning makes concurrency real
```

讲师说明：stream 决定同一 stream 内顺序，event 建立跨 stream 的 happens-before；它们不会自动切 chunk、不会为 communication 预留 SM，也不会提高 HBM/PCIe/NVLink 带宽。一个正确的流水通常需要：producer 在 chunk-ready event 后发布通信，communication 在 completion signal 后唤醒 consumer，同时限制 in-flight chunk，防止 buffer 被覆盖。

常见失败有四种：event 放在整个 GEMM 末尾，导致无法 tile-level overlap；通信 kernel 占满 SM，让 compute 无法调度；两者争用 HBM，单项时间都变长；chunk 太小，launch/signal/协议开销超过隐藏收益。观测时看 stream dependency、SM active/occupancy、HBM throughput、copy/NVLink/NIC utilization、kernel duration inflation 和 buffer queue depth。

## Slide 54｜Overlap 的调度单位从 kernel 缩小到 tile，状态成本随之增加

| 类型 | 例子 | 调度单位 |
|---|---|---|
| inter-kernel | GEMM 与 ReduceScatter 多 stream | chunk/kernel |
| fused producer-consumer | GEMM epilogue 发通信 | tile |
| persistent distributed kernel | kernel 内 load/store/signal/wait + compute | task/tile/warp role |

讲师说明：inter-kernel 最容易实现和调试，但只能在 chunk/kernel 边界交接；fused producer-consumer 可在 GEMM epilogue 或 tile ready 时发送，减少中间 HBM round trip；persistent distributed kernel 把 remote load/store、signal/wait 与 compute 放进同一 progress loop，启动间隙最小，但需要显式管理 credits、arrival counters、phase、buffer lifetime 和错误退出。

调度粒度越细，潜在 overlap 越大，固定开销和状态也越多。选择粒度时比较 `chunk serialization time`、producer/consumer tile 时间、launch/signal 成本、BDP 和可用 buffer。不是越小越好：过小会降低 wire efficiency、增加 metadata/atomic/counter 压力；过大又暴露尾部等待。

## Slide 55｜Data Movement 演进：从线程搬运到异步数据流

| 代际 | 关键变化 | 对 kernel 的含义 |
|---|---|---|
| Volta / Turing | Tensor Core fragment 与 accumulator 主要驻留寄存器 | 计算吞吐提高，但寄存器搬运与压力上升 |
| Ampere | `cp.async`：global → shared 的异步 copy | 供数不必先经普通寄存器 staging，可显式做多级流水 |
| Hopper | TMA + Tensor Map + `mbarrier` + async proxy | 地址生成、bulk tensor copy 与 completion 从计算 warp 中分离 |
| Blackwell | `tcgen05` + TMEM | accumulator 从 RF 移入专用 Tensor Memory，MMA、供数与 epilogue 更易解耦 |
| Rubin（公开预览） | runtime TMA override、细粒度 dependent coordination、counted scale-up completion | 同一套异步 dataflow 从片上内存继续延伸到跨 kernel 与远端 GPU |

讲师说明：这张时间轴的主线不是“每代更快”，而是把地址生成、data movement、compute 和 completion 从同一批线程中逐步解耦。Ampere `cp.async` 让 global→shared copy 不必先经过普通 register staging；Hopper TMA 用 Tensor Map 描述多维 layout，由专用 engine 做 bulk copy，并用 `mbarrier` 报告完成；Blackwell TMEM 把 Tensor Core accumulator 从普通 register file 分离；Rubin 公开预览继续扩展 runtime descriptor、跨 kernel/tile coordination 和 scale-up completion。[A19][A20][A22]

每次解耦都增加新状态：descriptor、barrier phase、transaction slot、TMEM lifetime、remote counter。它减少的是执行线程上的地址/搬运/等待工作，不是让 memory bandwidth 和 queue 消失。分析时仍回到 Topic 1 的 readiness contract 和 Topic 5 的 critical-path 模型：机制缩短了 launch/progress、staging、completion 或 consumer wait 中的哪一项，是否因更多 outstanding/资源占用增加了别的项。

NVIDIA 公开口径还给出 Rubin 的 HBM4 峰值带宽最高 22 TB/s、NVLink 6 scale-up 带宽 3,600 GB/s、NVLink-C2C 1,800 GB/s、PCIe Gen6 x16 256 GB/s；这里只按官方数字原样引用，不自行解释单向/双向或 payload/aggregate。峰值差距也再次说明不同层级的 bytes 不可当成同一条“内存带宽”。

建议图示：一条从 `RF → SMEM → TMEM → L2/HBM → NVLink peer memory` 向右展开的时间轴，每代只突出一个新增的数据通路。

## Slide 56｜一次“搬运”其实有三个问题

```text
Payload:     bytes 最终写到哪里？
Completion:  谁知道搬运完成、何时可以消费？
Lifetime:    buffer / cache line 何时可以复用或驱逐？
```

讲师说明：单卡 kernel 常把三者压在同一个线程控制流里；TMA、TMEM 和远端通信把它们拆开。`mbarrier` 回答本地异步操作何时完成；remote counter/flag 回答对端数据何时可见；cache eviction priority 管的是数据生命周期提示。通信进入 kernel 后，优化对象不再只是 payload bandwidth，而是 bytes、readiness publication 与 buffer lifetime 这三类状态/责任能否一起流水。

前序 p.71–78 已展示 `Tile Load / Tile Store`、Descriptor 和少量同步原语；本场把它们放回三个可验证问题：payload 放到哪里、谁确认 completion、buffer lifetime 何时结束。理想接口可让 compiler/runtime 生成地址、分块、排队和完成 bookkeeping，而不是让 kernel 作者逐条管理 SQE/CQE；它隐藏的是软件接口，不是物理资源。底层仍有有限 queue/credit、outstanding tracker、protection/translation、retry 或 error state；跨管理域还要回答 capability、撤销、generation、partial completion 与 endpoint failure。因此“地址语义”与“队列实现”不是非此即彼，常见实现会用地址式 API 驱动队列式硬件。

## Slide 57｜Runtime TMA override：复用 layout，只替换本次 expert 的地址

屏幕正文：

```text
shared Tensor Map: dtype / rank / layout / swizzle
        + runtime address / dimension / stride override
        ↓
TMA loads the selected expert tile
        ↓ repeated reuse with an L2 cache policy
last use → applypriority.async.bulk.tensor(...evict_normal)
```

讲师说明：Tensor Map/descriptor 可以理解为“多维 tensor 怎样从 global memory 搬到 shared memory”的说明书：dtype、rank、dimension、stride、swizzle 和 base address。MoE 中许多 expert 权重 layout 相同，只有 base address 或某些维度不同；如果每个 expert 都维护/改写完整 descriptor，会增加 descriptor memory、更新和同步工作。

Rubin 官方称新方向为 TMA inline descriptor update。PTX 9.4 为 `cp.async.bulk.tensor`、`cp.reduce.async.bulk.tensor` 和 tensor prefetch 增加 `.override::global_address` / `.override_attribute`，最低 `sm_107f` family：kernel 可复用公共 layout，在发起本次 TMA 时覆盖 expert address/dimension/stride。attribute override 只覆盖 global dimension/stride，且必须与 address override 同用。[A19][A20]

这减少 descriptor setup/traffic，不会自动解决 expert routing、weight placement、cache miss 或 TMA queue contention。新的 `applypriority.async.bulk(.tensor)` 可在 last-use 后把一段数据 L2 priority 恢复为 `evict_normal`，但 cache priority 只是 hint，不保证权重常驻。观测应看 descriptor/update 指令、TMA issue-to-complete、L2 hit、expert weight bytes 和 TMA slot stall。

建议图示：左边画基线软件设计“每个 expert 一份 descriptor，或在使用前更新 descriptor”，右边画公开预览方向“一个公共 descriptor + router 提供运行时字段”。不要把基线画成 Blackwell 硬件限制。

## Slide 58｜Dependent launch：让 consumer 不必等 producer 的整个 grid 结束

屏幕正文：

```text
Existing grid-level PDL (sm_90+):
  prerequisite grid collectively triggers → dependent grid may start
  consumer waits before reading prerequisite output

Rubin public claim:
  required tile becomes ready → corresponding consumer work can start earlier
```

讲师说明：普通 sequential launch 往往要求 producer kernel 整体完成，consumer kernel 才开始；但 consumer 可能只依赖 producer 已完成的一部分 tile。Programmatic Dependent Launch 允许 prerequisite grid 触发 dependent grid 更早开始，consumer 在真正读取依赖数据前再 wait，从而把 launch/scheduling 与剩余 producer 工作重叠。

现有 `griddepcontrol.launch_dependents/wait` 从 PTX 7.8、`sm_90+` 已存在，但触发仍要求 prerequisite grid 的所有 CTA 已执行 trigger 或结束。Rubin 官方博客展示更细粒度 tile/thread-block producer–consumer coordination；截至 PTX 9.4 Developer Preview，完整 runtime/PTX 调度和 memory-ordering 示例尚未公开。[A19][A20][A21]

它缩短的是 kernel boundary 和调度等待，不保证 consumer 能立即读到任意 tile，也不消除资源竞争、layout transform 或中间 HBM/SMEM placement。不要把“consumer polling 某个 flag”讲成已确认实现，也不要推导 megakernel 已无价值。验证时看 producer tile-ready、dependent launch、consumer wait release 和 SM resource overlap，而不是只看两个 grid start time。

## Slide 59｜Counted writes：把数据写入和远端完成计数绑定在一个操作里

屏幕正文：

```text
sender kernel
  └─ fabric put / reduction ──→ remote data
                               └→ remote byte counter += accessed bytes

receiver observes expected counter value → applies required ordering → consumes data
sender-side mbarrier → tracks local completion / error report
```

讲师说明：普通 remote write 常要另发 flag/atomic/ack：先写 payload，再保证顺序，再更新“已到”状态；这增加一条控制消息或一次 remote atomic，也容易出现 flag 先被观察而 payload 尚未按所需 scope 可见的错误。counted write 把目标数据访问与目标端 byte counter 更新绑定，receiver 等 counter 达到 expected bytes，再执行所需 ordering 后消费。

它减少的是独立 completion 消息和协调 round，不是让 receiver 无需同步。sender-side `mbarrier` 跟踪本地 operation completion/error report，remote counter 跟踪目标 bytes；两边语义不同。counter 复用还需要 generation/phase，防止上一轮迟到 write 污染下一轮。

PTX 要求 counter 为 8 字节且 256 字节对齐，更新粒度未规定。`fabric.try_put/try_red ... counted::bytes` 在 PTX 9.3 已引入、最低 `sm_100`，并非 Rubin 独占 ISA；Rubin 官方材料把 counted writes 作为 device-initiated NVLink fused communication 的重点优化。Fabric 指令使用 CUDA CFT logical endpoint，也不是任意 raw pointer store。[A19][A20] 观测应看 payload bytes、独立 atomic/flag 数、counter wait、phase errors 和 sender/receiver completion gap。

建议图示：对比“data write → fence → remote flag/ack”与“data write + counted completion”两条时序，不画成 receiver 无需同步。

---
## 4.5 从 Tensor Core dataflow 到跨设备 dependency

> 本节把单 GPU 的异步 producer–consumer dataflow 作为跨 GPU communication 的桥梁，不另起一个硬件演进章节。

### 4.5.1 Distributed Kernels and MegaMoE

## Slide 60｜Distributed kernel 把 progress engine 放进 GPU kernel

屏幕正文：

```text
warp roles / task loop:
  producer → remote put/get → signal/counter
  receiver → wait/acquire → compute → release buffer

state:
  symmetric addresses, credits, phase, outstanding ops,
  completion counters, timeout/error state
```

讲师说明：传统 host-driven path 在 kernel 边界把 work 交给 CPU/NIC；distributed kernel 则让 GPU warp/CTA 长驻，直接从 task queue 取任务、发 remote operation、poll signal，并在数据 ready 后计算。这可以消除 host launch gap，让 tile-level overlap 更细，但通信 progress 会占用 SM、寄存器、shared memory 和调度 slot。

回扣 Slide 56：payload、completion、lifetime 必须分别设计。remote write 完成后谁递增 counter，receiver poll 时需要什么 acquire/fence，buffer 何时进入下一 phase，credit 用完后谁等待；这些都是协议，而不是普通 load/store 自动解决。远端还会发生授权撤销、路径分区、节点重启和 unknown result，不能只靠地址映射把它们变成本地 cache miss。

观测上看 persistent kernel 占用、warp stall reason、signal polling time、remote outstanding、credit starvation 和 phase transition；若通信 kernel 长驻导致主 GEMM occupancy 下降，减少 launch gap可能仍得不偿失。

## Slide 61｜不同项目是在不同边界上融合，不能都叫“分布式 kernel”

| 方向 | 公开案例 | 这一层实际融合什么 |
|---|---|---|
| Distributed DSL / compiler | TileLink；Triton-distributed | tile 调度、通信 primitive、compute–communication overlap |
| Collective–GEMM fusion | FLUX；distributed GEMM / GEMM+AR/RS | collective chunk 与 GEMM tile/epilogue |
| Single persistent distributed MoE | FlashMoE | dispatch、expert compute、combine 的全局任务调度 |
| SM100 MegaMoE 实现 | DeepGEMM MegaMoE；FlashInfer CuTeDSL MegaMoE | FC1+activation/requant+FC2 与 token communication hooks |
| Device communication primitive | NVSHMEM；NCCL Device API LSA/GIN | symmetric memory、signal/barrier、device-side collective |

讲师说明：先按融合边界分类。TileLink/Triton-distributed 让 compiler/DSL 生成 tile schedule 和 communication primitive；FLUX/CUTLASS distributed GEMM 把 collective chunk 与 GEMM tile/epilogue 对齐；FlashMoE 追求跨 GPU 的 single persistent MoE；DeepGEMM 与 FlashInfer 的 MegaMoE 主要融合 FC1、activation/requant、FC2 与 token communication hooks；NVSHMEM/NCCL Device API 提供底层 device-side memory/signal primitive。[A18][B6][B7][B10][B11][B12][B13][B14][B15]

这些项目不能合并成一个“MegaMoE”品牌，也不能互相借性能结果。DeepGEMM MegaMoE 是 SM100 FP8 activation × FP4 weight 路径，PR #304/#328 的 kernel、layout、barrier 和 heuristics 仍在演进；FlashInfer CuTeDSL MegaMoE 是独立代码线，公开目录还覆盖不同架构/dtype；FlashMoE 又是另一项 single-kernel distributed MoE。引用时必须带项目、commit/PR、GPU、dtype、shape 和测试路径。

听众应问的不是“哪个项目最快”，而是它融合到哪一层：是否消除中间 HBM write/read、host launch、network round、layout transform，还是仅换了 DSL。只有消除 critical-path work 的融合才会稳定转化为端到端收益。

验证一项“融合”时画 baseline 与 fused 两条事件链，逐项划掉真正消失的 operation，再标出新增的 persistent state。若只是把多个 kernel 放进一个进程或 DSL，而 HBM round trip、completion round 和 consumer wait 都还存在，launch 数减少未必带来同等端到端收益。应报告 kernel count、HBM bytes、network rounds、signal/counter 数、SM residency 和 step tail，而不只报告单个 fused kernel latency。

## Slide 62｜DeepGEMM MegaMoE：真正融合的是端到端数据流

屏幕正文：

```text
EP dispatch / remote pull
        ↓
Linear1 gate/up GEMM (FP8 × FP4)
        ↓
SwiGLU + amax + FP8 requantization
        ↓
Linear2 GEMM
        ↓
remote BF16 combine-buffer writes
        ↓
final top-k combine reduction
```

实现抓手：

```text
persistent kernel + symmetric workspace
receive counters / arrival masks / token metadata
wave-and-phase scheduler
TMA + TMEM + two-CTA tcgen05 MMA
```

讲师说明：它的价值不只是减少 kernel launch，而是把 dispatch、两个 GEMM、激活/重量化、远端 write-back 和最终 combine 放进同一个进度系统。代价也由此而来：workspace 中的 counter、arrival phase、source token/top-k metadata 都成为正确性协议；phase 复用错误可能死锁，metadata 错误可能写错 combine slot。PR #304 中的 tile/thread 常数只描述该版本，PR #328 已继续调整调度与 heuristics；本稿没有本地 B200 复现，因此不引用项目 benchmark 作为通用性能结论。FlashInfer CuTeDSL MegaMoE 是独立实现，不能用其代码或结果替 DeepGEMM 背书。[B10][B11][B12]

建议图示：画出上述六段 dataflow，并在下方把 symmetric workspace 标成 control plane；不要只画一个写着 “fused kernel” 的大方框。

---
## 4.6 KV 与对象移动：用容量换延迟

> 本节关注 KV/object 的 placement、tiering、prefetch 与 publish；它们改变的是等待位置和容量约束，不是把远端存储变成 HBM。

### 4.6.1 Communication-Memory-Storage Co-design

## Slide 63｜KV cache 的一次 miss，会触发另一条完整通信路径

屏幕正文：

```text
GPU HBM hot blocks
   ↕ PCIe / C2C
CPU pinned DRAM full or warm copy
   ↕ RDMA / network object transfer
remote memory / distributed cache
   ↕ storage protocol / DMA
SSD / context-memory tier
```

讲师说明：decode kernel 需要某个 layer/token range 的 KV block。若 HBM 命中，直接进入 attention；若 miss，scheduler 必须查 block table，选择 host/remote/storage source，分配目标 slot，发起 transfer，等待 completion，更新映射，最后才允许 kernel 消费。每下降一级，容量通常增加、单位成本下降，但 startup、尾延迟、搬运 bytes 和失败模式增加。

这里最重要的性能量不是介质标称带宽，而是 `bytes requested per token`、hit rate、miss concurrency、prefetch accuracy、admission wait 和每级有效服务率。Little's Law 同样适用：更长 latency 要靠更多并发 request/bytes 才能打满带宽，而更多并发又需要 pinned buffer、request state 和 eviction headroom。

常见误区是把 host/remote tier 称作“更大显存”。它们没有自动获得 HBM 的访问延迟、failure semantics 或 memory ordering；runtime 必须把 object ready 转换成 GPU 可观察的 block mapping/completion。

这里调用者站得尤其高：attention kernel 只发出“需要 block k”的依赖，cache/runtime 隐藏 lookup、source choice、allocation、DMA/RDMA/storage request、publish 与 eviction；transport 又隐藏 packet/retry。TTFT/TPOT 上的一个 stall 可能来自 metadata miss、admission queue、PCIe、remote network、storage 或错误恢复。最小取证集合是 block id 的端到端 trace、每级 hit/miss、queue wait、transfer bytes/latency、publish time 和 attention resume time。

## Slide 64｜HiSparse：把完整 KV 留在 host，只把本轮需要的部分送回 GPU

屏幕正文：

```text
Decode GPU: fixed-size hot KV buffer
Decode CPU pinned memory: complete KV
sparse-attention top-k: on-demand host → device swap-in
```

讲师说明：HiSparse 的基本等待关系是：decode GPU 只保留固定大小 hot buffer，CPU pinned memory 保存更完整 KV；sparse-attention 选择 top-k blocks 后，runtime 才把需要的 blocks swap-in。它减少 HBM 容量需求和无用 KV movement，但增加 top-k decision、host lookup、PCIe/C2C transfer、LRU/slot management 和 graph-compatible staging。[B8]

数据路径必须按一次 miss 画：attention/selector 产生 block ids → coordinator 查 host pool → 分配 GPU slot → JIT swap-in kernel/DMA → completion 更新 device table → attention 消费。若 top-k 变化快或预取不准，PCIe 和 launch tail 会暴露；若 hot buffer 太小，thrashing 会使相同 blocks 反复搬运。观测时看 hit rate、swap-in bytes/token、host→device P50/P99、buffer occupancy 和 decode stall。

## Slide 65｜PD direct-to-host：先把 KV 放到最终 host tier，避免一次无效中转

屏幕正文：

```text
Prefill GPU ──RDMA──> Decode CPU pinned host pool
                            ↓ on demand
                       Decode GPU hot buffer
```

讲师说明：传统实现可能先把 P 的 KV 写到 D GPU staging，再搬到 D host full pool；如果 decode 最终只把少量 hot blocks 拉回 GPU，这次 staging 消耗 D GPU 容量和额外 PCIe/HBM traffic。direct-to-host 让 Prefill GPU 通过 RDMA 直接写 Decode pinned host pool，完成后由 decode scheduler 发布 blocks，按需 swap-in GPU hot buffer。[B8]

“直接”仍不等于没有控制路径：P/D 必须协商目标 host addresses/handles、request/layer offsets、buffer lifetime 和 completion；D 不能在部分写入时发布 block。Prefill 侧不感知 HiSparse，HiSparse 在 decode side 管 host/device tier；当前公开文档要求 PD disaggregation，DeepSeek V4 路径还区分 C4 与其他 KV 部分。

验证收益时同时统计省掉的 D GPU staging bytes、D HBM/PCIe traffic、host write bandwidth、RDMA P99 和 decode admission；若 host memory 或 NUMA 成为瓶颈，direct-to-host 可能只是把队列从 GPU 移到 DRAM。

## Slide 66｜DualPath 与 HiSparse 解决不同层次的问题

| | DualPath | HiSparse |
|---|---|---|
| 主要瓶颈 | storage loading bandwidth | decode GPU KV capacity |
| 路径变化 | 增加 Storage→Decode | Host full KV→GPU hot subset |
| 决策主体 | distributed serving scheduler | SGLang decode scheduler/coordinator |
| 可组合性 | 可为 decode 端供数 | 可消费进入 host pool 的 KV |

讲师说明：DualPath 解决“远端 KV 从 storage 到 serving node 的入口带宽和路径调度”，HiSparse 解决“KV 到达 decode node 后，哪些 blocks 必须驻留 GPU”。两者可组合：DualPath 把 object 放入 D host/remote pool，HiSparse 再按 attention 需求选择子集进入 GPU。它们分别改变路径/队列等待与 staging/consumer wait，不应当作替代方案。

组合设计要防止双重预取和重复副本：distributed scheduler、decode coordinator、object store 必须共享 block identity、版本和 ownership。否则同一 KV 可能从 P 和 storage 同时到达，浪费 bandwidth 或发布旧版本。

一眼判断二者谁该负责：若 object 尚未到 decode node，问题在 storage/network ingress，DualPath 改服务路径；若完整 object 已在 decode host DRAM，但 HBM 放不下或不值得全搬，HiSparse 改 host→GPU placement。验证时在 `object enters node` 处打边界时间戳；边界前慢看 DualPath/transport，边界后慢看 selection、slot、swap-in 和 attention wait。

## Slide 67｜Mooncake/HiCache：object metadata 决定 bytes 能否被正确复用

屏幕正文：

```text
key / request / layer / token range / dtype / layout / version
                  ↓ lookup + placement
replica locations → transfer engine → destination pool
                  ↓ publish / lease / eviction / failure cleanup
```

讲师说明：Mooncake Store 为 KV/object 管 placement、replica、eviction 和多介质 backend；SGLang HiCache 可接 Mooncake backend。当前 SGLang integration 还描述 HiSparse host pool / DSV4 C4 side pool 的 layer-first multi-buffer zero-copy 接口。[B2][B9]

这页要让听众看到：同样的一段 bytes，若缺少 layer/token range、layout、dtype 和 version，接收端无法安全复用；若 object 已在另一 replica，系统应选择更近路径，而不是重复从 storage 读取；若 transfer 部分失败，metadata 不能提前发布 ready。通信和缓存的边界因此不是“是否走 RDMA”，而是 payload completion 如何原子地更新 object state。

观测应分为 metadata hit/lookup latency、placement decision、transfer latency、publish wait、replica/eviction bytes 和 stale/orphan cleanup。仅测 network bandwidth 无法解释 cache hit 高但 TTFT 仍慢的情况。

## Slide 68｜Context-memory tier 的价值是容量与复用，不是替代 HBM 延迟

屏幕正文：

```text
HBM (G3) ↔ Ethernet-attached context memory / flash tier (G3.5) ↔ storage
```

讲师说明：NVIDIA Rubin 平台公开材料中的 ICMS，后续又使用 CMX Context Memory Platform 品牌，目标是通过 BlueField-4 和网络化 flash/context-memory tier 承载更多 KV/context。它适合存较冷、可复用、可提前取回的数据，不会自动拥有 HBM 的逐 token 访问延迟。[C2]

系统仍要决定 cache key、replication、prefetch horizon、bandwidth reservation、encryption/tenant isolation 和 failure recovery。如果一个 decode step 直接同步等待 remote flash，尾延迟很可能不可接受；合理用法通常是提前把即将使用的 blocks 提升到 remote memory、host DRAM 或 HBM。当前材料仍属快速演进公开预览，产品能力和名称应绑定日期，不能外推未披露的内部实现。

性能上用“是否进入 token critical path”区分两种模式。异步预取命中时，远端 tier 的 latency 被 request-level lead time 隐藏，只支付带宽与容量管理；同步 miss 时，lookup、queue、network/storage read、host/GPU promotion 全部暴露在 TTFT/TPOT。证据应包含 prefetch lead time、hit ratio、tier bandwidth/queue、promotion latency 和 exposed stall，而不是只引用 tier 峰值容量或带宽。

## Slide 69｜跨机房能搬“状态”，通常不能搬逐 token 的同步依赖

屏幕正文：

```text
local HBM shortage → rack/pod context tier → remote DC / regional placement
```

讲师说明：跨机房的 RTT、抖动和故障域远大于 rack/pod。适合跨域的是可异步复制的 prefix/KV object、checkpoint、权重版本或 cold tier；不适合的是每个 token 都要等待的 TP/EP/collective 边。一个简单判断是：远端等待能否通过 request-level prefetch、batching 或 replica 隐藏，如果不能，它会直接进入 TTFT/TPOT critical path。

设计上要明确 consistency 与 failure policy：跨域副本允许多旧，写入部分成功时谁清理，region failure 后是否可从另一副本继续，网络分区时是否阻止发布。NVIDIA ICMS/CMX 的公开定位是 context-memory tier，不应直接等同跨地域存储或承诺 WAN-transparent memory。[C2]

可用依赖频率做数量级判断：每个 token 都发生的边会把 WAN RTT 直接加到 TPOT；每个请求一次且能提前数十毫秒预取的 object，才可能把 WAN 移到后台。观测时按 dependency frequency、prefetch slack、WAN P50/P99、replica freshness 和 failover time 分开；“跨机房带宽足够”不能证明同步边可接受。

---
# 5. 哪些开销会在 Scale 下进入 Critical Path？（142–163 min）

> 本章坐标：把前四问放进时间轴。一项开销不是因为“存在”就自动位于 critical path；只有当它不能被计算或其他通信隐藏、不能被充分摊销，并阻塞下一条必需依赖时，才会决定 consumer-visible time。下面分别检查启动/重启、稳态执行和故障检测恢复，并用 MRC 与 Meta 100K+ GPU 案例说明 scale 如何改变成本模型。

## Slide 70｜一项开销什么时候真正进入 Critical Path？

屏幕正文：

```text
exposed cost = total cost
             - hidden overlap
             - amortized / off-path work

启动 / 重启：bootstrap · communicator · QP / resource setup
稳态执行：HBM footprint · queue · RTT/BDP · progress · contention
故障恢复：detection · retry / reroute · diagnosis · restart
```

讲师说明：critical path 是从 producer dependency 到 consumer start 的最长必要依赖链，不是所有发生过的工作之和。初始化若只发生一次且能摊销，可能不影响稳态 step；但如果大规模故障使作业频繁重启，它就会反复暴露。通信 buffer 若没有挤压模型和 batch，可能只是 footprint；当 HBM 不足导致 batch 下降、更多 checkpoint 或额外 shard，它就间接降低 goodput。高 BDP 本身也不是坏事；只有 in-flight state 不足导致链路空闲，或过量 burst 引发 queue/recovery，它才成为阻塞。

跨层优化的优先级通常是：先消除不必要 bytes，再改变落点和路径，然后减少同步轮次，最后才是在同一路径上追求更高利用率。每项优化都要重新计算完整代价：省了多少 bytes/round trip，增加了多少 compute、metadata、buffer、误差与 failure state，是否真正从关键路径移除。`zero-copy` 只表示少一次显式 copy，不保证没有 DMA、registration、burst 或 consumer wait；`100% link utilization` 也可能只是队列很深、尾延迟更差。

固定使用四步账本：`baseline critical path` 写出 bytes、rounds 和 waits；`eliminated` 标真正删除的 copy/message；`moved` 标转移到 CPU/GPU/NIC/DPU/storage 的工作；`new risk` 写新增的 buffer、精度、staleness 或 recovery。只有端到端 timeline 的 consumer-visible time 和 tail 改善，才算跨层优化成功。

---

## Slide 71｜Scale 不是一个更大的 N，而是成本模型发生变化

```text
per-rank state × rank count       → HBM / QP / control-plane footprint
rare failure × device count       → 日常 recovery 与 restart
RTT / topology heterogeneity      → 不同 BDP、tail 与 path health
local stall × synchronization     → collective-wide wait

MRC：阻止部分 path/link failure 升级成 job failure
Meta 100K+：同时重做 initialization、resource、transport 与 operations
```

讲师说明：scale 会把原本可忽略的常数项、罕见事件和局部等待变成全局成本。每 rank 几乎看不见的 metadata 乘以 communicator、channel 和 peer 数后会挤占 HBM/NIC context；单设备低概率故障乘以 100K 个 endpoint 后会反复发生；跨 rack、zone、building 的 RTT/BDP 不再能用一组 transport 参数覆盖；同步 collective 又会把一个局部 stall 扩散成所有 rank 的 barrier wait。

Slide 28 的 MRC case 在这里承担一个明确角色：它说明大规模同步训练中，路径/链路故障、丢包与重传会直接威胁 job progress，而 packet-level multipath、path health 与 selective recovery 可以让论文所报告的一些故障留在 transport/path 层，不升级为 QP 或 job failure；它不能透明覆盖任意 endpoint failure。接下来的 Meta 案例承担另一角色：它说明 scale 不只考验 data-plane resilience，还把 initialization、HBM/QP resource、BDP flow control、fault diagnosis 与规模测试一起推入系统关键路径。[A10][A44]

---

---

## 5.1 Meta 100K+ GPU：从 Steady State 扩展到完整通信生命周期

## Slide 72｜100K+ GPU：问题从 steady state 扩展到整个通信栈

屏幕正文：

```text
100K+ GPU、跨多个 building
        │
        ├─ communication library：初始化与 HBM/resource footprint
        ├─ transport：异构 RTT/BDP 与 MoE bursty all-to-all
        └─ operations：故障因果、性能归因、低成本仿真
```

讲师说明：SIGCOMM 2026 的 Meta 生产案例把一个常被拆散的问题放回同一条链路：物理拓扑跨多个数据中心 building，跨层延迟相对 rack 内最高约 30 倍；MoE 动态路由制造突发、非规则的 all-to-all；硬件故障从异常变成日常事件。[A44] 论文报告其 RoCE fabric 已连接超过 100,000 个 GPU，但这些数字是该部署的规模描述，不是所有集群的必要配置。最重要的观点不是“换一个 collective”，而是 library、transport 和 observability 必须共同设计。

---

## Slide 73｜CCLX：先把初始化和资源管理从关键路径中解耦

屏幕正文：

```text
Global communicator / process-group state reuse
        ↓
异步 I/O bootstrap + O(N) topology discovery
        ↓
lazy channel / buffer / metadata allocation
        ↓
模型加载、数据准备与通信初始化重叠
```

讲师说明：论文中的 CCLX（NVIDIA 平台版本也称 NCCLX，AMD 平台版本称 RCCLX）提供 host-initiated、带 GPU-resident metadata 的 host API 和 device-initiated API 等执行模式，并可在 baseline NCCL 与自定义 CTran 路径之间选择。[A44] 其关键不是把 NCCL 简单替换掉，而是复用 global communicator 状态、异步化 bootstrap、避免每个 process group 重复全局交换，并按实际算法和 channel 需求分配资源。论文报告初始化时间最高约 11 倍改善、通信 HBM 开销约 2 倍降低；这两个数字绑定其 testbed、rank 数和实现版本，不能当作通用保证。

---

## Slide 74｜为什么“轻量初始化”在 100K 规模会变成可靠性问题

屏幕正文：

```text
频繁重启 × 全局 bootstrap × O(N²) state exchange
                         ↓
                 restart downtime

CCLX：state reuse · async bootstrap · lazy provisioning · slab metadata
```

讲师说明：论文用一个运维预算说明量级：在其假设的失败频率和 90% effective training time 目标下，每次 restart 只有约 175 秒预算，而传统初始化可能超过这个预算。论文还报告 80 GB H100 中通信库在某些配置约占 10 GB（约 12.5%），因此初始化和 resource footprint 会反过来影响 batch、模型容量和 goodput。[A44] 这里的 175 秒、10 GB 和 12.5% 都是论文的部署/配置分析，不是所有 NCCL 作业的固定开销。slab allocator 解决的是大量小 metadata allocation 的碎片与对齐成本；它不等于消除 QP、buffer、registration 或 NIC context 的总状态。

---

## Slide 75｜DQPLB：把 zero-copy 的低延迟和 segmentation 的流控合起来

屏幕正文：

```text
zero-copy 整块 post  ──低延迟──▶  burst / switch buffer buildup
copy + segmentation  ──有节奏──▶  额外 copy

DQPLB：多 data QP + bounded outstanding + sequence reorder
       QP 数 × segment × outstanding ≈ path BDP
```

讲师说明：Dynamic Queue Pair Load Balancing（DQPLB）是论文的 transport 机制。它根据路径 RTT/BDP 和消息形态动态选择 data QP 数、segment size 与 outstanding limit，使跨 building 的高 BDP 路径能保持足够 in-flight data，同时避免一次性把大消息推成交换机 burst。[A44] 多 QP 会产生乱序，接收端用 sequence number、滑动窗口和有限缓存重排；小消息可走 dedicated fast path，避免每个操作都进入完整的 reorder bookkeeping。公式是设计直觉，不是协议常数，也不能由 BDP 直接推出最优 QP 数。

---

## Slide 76｜DQPLB 的收益边界：吞吐、buffer、拓扑与 workload 一起看

屏幕正文：

```text
目标不是“永远更多 QP”

same rack      → 小 BDP、小 outstanding
cross zone     → 更大 BDP、不同 pacing
cross building → 需要更多 in-flight，但要限制 burst
```

讲师说明：论文在其 400 Gb/s NIC 和 collective testbed 上报告：不同规模 All-to-Allv 的 peak switch buffering 可下降约 75–90%；256-GPU AllGather 的 peak buffering 下降约 72%，某个 8 MB case 的 bus bandwidth 提升约 13%，而 1 GB case 未观察到性能惩罚。[A44] 这些是论文特定 shape、拓扑、消息大小和对照实现的结果，不应改写成“DQPLB 普遍提升 13%”。更一般的可迁移结论是：transport 参数应是 `f(RTT, BDP, message shape, topology, queue budget)`，不能用一组全局固定值覆盖整个 fabric。

---

## Slide 77｜Fault Analyzer：从 cascading timeout 回溯 root cause

屏幕正文：

```text
collective trace
  scheduled → started → completed
                 ↓
       inter-collective dependency DAG
                 ↓
       culprit collective / rank / host / NIC
```

讲师说明：同步训练里，一个 rank 未启动或未完成，就可能让后续数百个 collective 一起 timeout。论文的 Fault Analyzer 用 CollTrace 和 inter-collective dependency graph 区分 root-cause collective 与 cascading stalls，再结合参数一致性、kernel launch、rank-pair network error 和 wait-for graph 缩小到 rank/host/NIC 或软件缺陷。[A44] 这和“看谁先报错”不同：先报错的往往只是受害者。论文案例把约 500 个 timeout 归因到一个未 launch 的 rank，也把另一个案例的数百个 timeout 归因到 NIC malfunction；应把它们作为案例，不当成故障率或诊断准确率的普遍统计。

---

## Slide 78｜PerfProfiler 与 CPU emulation：把可观测性和规模测试前移

屏幕正文：

```text
AlgoProfiler：registration / control sync / data transfer
SlowRankDetector：WQE issue → completion → rolling bandwidth

CPU emulation：mock CUDA + verbs + stable handles
               用 CPU rank 验证 control-plane scale
```

讲师说明：PerfProfiler 把 collective algorithm 层和 CTran transport 层的时间戳关联起来，区分 registration、同步、数据传输或 slow rank；论文案例中某些 rank 的 synchronization duration 变长约 100 倍，但 data-transfer duration 正常，根因是慢 I/O，而非网络。[A44] 分布式 CPU emulation 则通过 library interposition 模拟 CUDA、libibverbs、QP、memory region 和 event 生命周期，在论文中用 12K CPU server 表示约 96K virtual ranks。它验证的是 control-plane fidelity，不是 GPU data-plane 性能；因此不能替代真实带宽、PCIe、HBM 或 NIC 测试。

---

# 6. 如果重新划分 Compute、Memory 与 Interconnect 边界会怎样？（163–184 min）

> 本章坐标：前五问默认 GPU、HBM、NIC 与 network 的边界已经给定；本章把这些边界本身变成设计变量。每个案例都用同一张责任账本检查：哪些 bytes、状态和等待被真正删除，哪些只是转移或复制到 compiler、SRAM、I/O die、memory tier 或 network appliance，哪些形成新的 thermal、capacity、protocol 与 recovery 耦合。

## Slide 79｜为什么要重画边界：decode 把 memory、interconnect 与 packaging 绑在一起

屏幕正文：

```text
Prefill：通常更接近 compute-bound
Decode：通常更接近 memory/latency-bound

TTFT · TPOT · tokens/s/user · weight/KV capacity · fabric tail
```

讲师说明：这是趋势性分类，不是绝对定律。batch、序列长度、量化、并行策略和 kernel 实现会改变 roofline。Prefill 往往有更高算术强度；decode 每轮工作量小，却要反复读取权重并访问不断增长的 KV cache，因此常被 memory hierarchy、片间通信和排队抖动支配。TTFT 与 TPOT 不能被单一 tokens/s 数字替代。[A43] SIGCOMM 案例说明训练通信栈的全局规模问题；下面几页进一步讨论推理时的容量、带宽和低延迟硬件取舍。

---

## Slide 80｜Memory wall：每一层都在交换容量、带宽、延迟与寿命

屏幕正文：

```text
SRAM：低延迟/高带宽/小容量
HBM：高带宽/中等容量/封装成本
DDR：容量与成本/较弱带宽
Flash/HBF：大容量/页读取/写寿命约束

权重 ≠ KV cache ≠ 临时激活
```

讲师说明：decode 的压力不是缺一种“更快的内存”，而是对象生命周期和访问模式不一样。权重通常相对静态，KV cache 会随请求写入、回收和迁移，激活与通信 buffer 是短生命周期热数据。HBF 更适合低写入的冷权重或冷 context；不能默认承载热 KV。任何层次结构都要列出容量、有效带宽、访问粒度、尾延迟、写放大、寿命与故障恢复。[A43]

---

## Slide 81｜Cerebras CS-4：同一 WSE-3，靠时钟、供电和机架密度换性能

屏幕正文：

```text
用户提供的 SemiAnalysis 二手整理：
  WSE-3：约 44 GB 片上 SRAM/wafer（容量不变）
  约 43 PB/s 聚合片上 SRAM bandwidth（口径不可与 HBM 直接比较）
  更高时钟与供电/液冷，目标约 2× 性能
  机架从 2 个 wafer-scale engine 增至 3 个 backpack
  约 2.4 Tb/s off-wafer I/O（报道口径）
```

讲师说明：本页数字来自用户提供的 SemiAnalysis 付费文章摘录和公开披露的二手整理，不是完整产品规范。[C3] “约 44 GB”是每片 wafer 的 SRAM 容量，不是外部内存；“43 PB/s”是聚合片上带宽，访问粒度、数据复用和边界不同，不能与 Rubin/HBM 的外部带宽做同口径比较；“约 2×”是特定配置/工作负载的目标或比较，不能推成所有模型和并发都翻倍。文章还报告 CS-4 rack 约 125–135 kW、CS-3 单系统约 23 kW，但基准不同，不能直接计算 performance/W。SRAM 容量不增加意味着模型权重、KV cache 和长上下文仍是主要边界。

---

## Slide 82｜CS-4 I/O 与 disaggregated inference：把容量边界外移

屏幕正文：

```text
WSE/SRAM → proprietary wafer I/O → FPGA-based WIO/NIC
       ├─ Ethernet fat-tree（报道约 3 μs switched path）
       ├─ direct wafer path（报道约 2 μs）
       └─ HBM-based XPU / Trainium / other system

PDD：prefill ↔ decode     AFD：attention ↔ feed-forward
```

讲师说明：这些 2–3 μs 和 2.4 Tb/s 是文章报告的特定系统数字。[C3] PDD 把 prefill 与 decode 分开，AFD 进一步按 attention/feed-forward 拆分；外部 HBM 可以缓解 wafer SRAM 容量限制，但新增 network hop、序列化、流控、一致性和故障处理。固定的 P:D 资源比例也可能跟不上五年生命周期内 workload 变化。MoE 的 EP/ETP 对 token dispatch/combine 的跳数、尾延迟和 expert skew 敏感；“支持 disaggregation”不等于所有并行策略同样有效。文章关于 AWS/Trainium 特定合作方向属于推测，不能讲成互操作承诺。

---

## Slide 83｜Groq：用静态、空间化的数据流换可预测性

屏幕正文：

```text
compiler/static schedule
        ↓
spatial dataflow + distributed local SRAM
        ↓
可预测的 cycle、带宽与资源占用

边界：容量、动态请求、长上下文、MoE 路由、外部网络
```

讲师说明：本页只讲设计空间，不声称掌握 Groq 未公开的完整微架构。公开材料支持的稳妥表述是 compiler-managed/static scheduling、spatial dataflow 和 SRAM-centric local memory；不能由二手材料反推出所有执行都 cycle-level deterministic、确切功耗或 3D stacking。[C4] 静态调度可减少动态仲裁和 timing variance，但不会消除热设计、容量和网络边界。Cerebras wafer-scale 与 Groq 空间化数据流是相近问题下的不同设计点，不是同一架构。

---

## Slide 84｜HBF、PNM、3D stacking、低延迟互联：四条研究路线

屏幕正文：

```text
HBF                  冷权重/冷 context 容量
PNM                  逻辑靠近内存，减少 movement
3D memory–logic      带宽密度与能效
低延迟互联           小消息与同步边

研究方向 ≠ 成熟采购清单
```

讲师说明：HBF 的页粒度、读延迟、写寿命和写放大使它不适合默认承载热 KV。PNM 与 PIM 要区分：PNM 通常把逻辑和内存放在不同但相邻的 die，可能改善逻辑 PPA、内存密度和软件分片粒度；这不代表 PNM 在所有工艺、封装和热预算下都胜出。3D stacking 带来散热、良率、封装、接口标准与供应链约束。低延迟互联能缩短通信边，但不会自动增加容量或消除 KV 写入问题。[A43]

---

## Slide 85｜NetDAM：把内存和可编程处理放到网络边缘

屏幕正文：

```text
GPU/XPU ── scale-up / Ethernet ── [NetDAM]
                                  ├─ SRAM/HBM
                                  ├─ vector/reduce engine
                                  └─ programmable memory operations

不是透明共享内存，也不是免费的一致性域
```

讲师说明：NetDAM 是 2021 年 FPGA/100GE 研究原型，论文延迟和 jitter 只能作为当时实验平台的证据，不能线性外推到今天的 1 Tb/s 量产系统。[A39] 关键问题是 ownership、capability、ordering、completion、backpressure、partial failure 和 recovery。MoE dispatch/combine 还要保存 token、expert、sequence 和归约状态；这些 metadata 可能比算术更难。把操作编码到 packet/header 也必须回答重放、重复执行、未知结果和安全隔离。因此 NetDAM 是可复用的架构原型，不是透明远端 RAM。

---

## Slide 86｜架构选择矩阵：没有脱离 workload 的“赢家”

屏幕正文：

```text
GPU + HBM          通用性、动态 batching       容量/带宽/功耗压力
wafer-scale SRAM   低 batch decode             容量与跨 wafer 通信
Groq-style dataflow 可预测时序与资源占用     动态性、容量、生态
HBF/池化存储       冷权重、冷 context          页延迟、寿命、搬运
PNM/NetDAM         就地操作、减少 movement     状态、编程、安全、故障
低延迟 fabric      小消息与同步边             不能替代内存层次
```

讲师说明：比较时固定模型结构、输入/输出长度、并发与 batch、并行策略（PP/TP/EP/AFD/PDD）以及 TTFT/TPOT/吞吐/尾延迟/能耗目标，再画出通信 critical path、KV 热度和复制/恢复策略。一个系统可以在 tokens/s/user 上赢，却在容量、利用率、容错或多年 TCO 上输。结论应是“给定 workload 和故障模型下的选择”，不是某种芯片永远更快。[A43][C3][C4]

---

## Slide 87｜移动一个边界后，责任消失了还是被转移了？

屏幕正文：

```text
                 真正减少什么          新责任落在哪里
Cerebras         部分芯片间 movement    容量、pipeline、off-wafer I/O
Groq             动态调度与仲裁         compiler/static schedule、外部网络
HBF              热层的容量压力         placement、页延迟、写寿命
PNM / 3D         memory movement 距离    thermal、mapping、接口耦合
NetDAM           部分 collective/data movement       operation identity、ordering、recovery、programmability
```

讲师说明：Cerebras 减少部分细粒度芯片间边界，但 SRAM capacity 与 off-wafer I/O 成为更硬的约束；Groq 把更多 ordering/progress 决策前移到 compiler/static schedule，但动态请求、容量和外部故障仍需运行时处理；HBF、PNM 与 3D stacking 改变 memory-capacity/bandwidth boundary，却引入页延迟、寿命、散热和 software mapping；NetDAM 把部分 collective/data movement 放到 network/memory 附近，却必须新增 operation identity、权限、ordering、completion 与 partial-failure recovery。

因此不能只问“少走了几跳”或“带宽提高了多少”。对每个新边界都要重新画 payload、control/metadata、completion/publication 三类逻辑角色，并标出 recovery 闭环，再计算 compute、metadata、buffer、staleness、failure 和 thermal cost。责任可能被真正删除，也可能只是被转移、复制或变成更紧的跨层耦合；只有 GPU B 的 consumer-visible time、tail 和系统 goodput 改善，才算解决了原问题。

---

# 总结（184–186 min）

## Slide 88｜离场前，用六个问题重新检查 x[i]

```text
1 consumability：delivery / placement / completion / visibility / ordering 是否成立？
2 boundaries：x[i] 穿过哪些 memory、device、protocol 与 failure domain？
3 ownership：谁 maintain state，谁 initiate / progress / complete / recover？
4 workload：traffic 如何经过 topology、queue 与 synchronization 变成 wait-for graph？
5 critical path：哪些 startup、steady-state、recovery cost 没有被隐藏？scale 放大了什么？
6 redesign：移动 compute / memory / interconnect 边界后，责任是消失、转移还是复制？

Cross-cutting evidence：timeline · counter · topology · queue · P99/max-rank · failure trace
```

讲师说明：最后重新口述 Slide 2：A 产生 x[i]，B 必须等它。若听众能回答这六问，并为每个判断指出可证伪的 evidence，就已经拥有可迁移的 communication-system reasoning，而不是背了一套产品表。答案可能是 NCCL ring + GPUDirect + RNIC RC，也可能是 device put + scale-up endpoint，或 KV object 从 remote tier 提升；分析方法不变。

建议现场给一个新例子作 60 秒验收：`all_reduce()` 慢且 NIC 只有 60% 利用率。先不能回答“加带宽”；必须检查 source ready、NCCL schedule、GPU–NIC affinity、progress gap、destination reduction/HBM、pause/credit、completion tail 和 slowest rank。若没有证据，判断就还停留在猜测。

---

---
# 建议增加的 Demo

## Demo A｜读拓扑而不是背带宽

```bash
nvidia-smi topo -m
nvidia-smi nvlink --status
ibdev2netdev
ibstat
```

展示：GPU↔GPU、GPU↔NIC affinity；然后预测 NCCL ring/rail mapping。

## Demo B｜Ring AllReduce 动画

做一个 4-rank、8-chunk 的可视化：逐步切换 ReduceScatter 与 AllGather，并提供“GPU reduce / switch reduce”按钮，对比 bytes traversing links。

## Demo C｜Overlap timeline

三条 timeline：串行、multi-stream 但资源争用、chunked genuine overlap。用同一总工作量解释为什么 overlap 可能无收益。

## Demo D｜MoE skew simulator

滑块控制 expert load CV/max-to-mean；显示最热 rank、dispatch tail、复制一个 hot expert 后的变化，以及复制权重的额外成本。

## Demo E｜HiSparse hot-buffer simulator

输入 context length、top-k、device buffer size、host/device bandwidth；显示 hit/miss、swap-in bytes 与 decode concurrency。

## Backup Slide M1｜MCM / NUMA 研究路线：不要当成 GB200 框图

| 年份 | 工作 | 关键思想 |
|---:|---|---|
| 2017 | MCM-GPU | remote cache + distributed CTA scheduling + first-touch page placement |
| 2018 | CARVE | 在本地 video memory 划出 remote-data cache，容量换互联流量 |
| 2020 | HMG | 以 scoped GPU memory model 构建 hierarchical sharer tracking |
| 2021 | PROACT | 编译期 instrumentation + data-block readiness，流水化链路友好传输 |
| 2023 | FinePack | 透明聚合并压缩 4–32 B P2P stores，降低 packet/protocol overhead |

讲师说明：这条时间线说明研究问题如何从“把多芯片做成一个逻辑 GPU”逐渐走向“细粒度 remote memory 如何像本地 load/store 一样可编程，又像 bulk DMA 一样高效”。所有方框都标 `research proposal`；不要画箭头暗示某篇论文已经落入 Blackwell。MCM-GPU 论文报告三个 locality 机制组合后将 inter-GPM bandwidth 降低 5×；CARVE 摘要报告用 3% GPU memory 接近理想 NUMA；HMG、PROACT 与 FinePack 的性能数字均只在各论文模拟或实验配置下成立，不进入主讲横向对比。[A24][A25][A26][A27][A28]

## Backup Slide T1｜Link replay、端到端 retry 与应用恢复覆盖什么

| 故障/事件 | FEC / link replay | End-to-end transport | Runtime / application |
|---|---|---|---|
| 单链路随机 bit error | 主要处理层 | 可作兜底 | 通常无感 |
| 接收 buffer 即将溢出 | flow control，非 replay 本身 | CC/window/credit | backpressure policy |
| fabric drop、route churn | 覆盖不了完整路径 | ACK/NACK、retry、multipath | timeout policy |
| 永久 link/switch failure | 本链路无法继续 | reroute/fail connection | communicator repair |
| endpoint reset / process death | 无法解决 | connection error | rank recovery/checkpoint |
| 上层 silent corruption | CRC 覆盖范围外可能漏过 | end-to-end integrity 可检测一部分 | checksum、validation、rollback |

讲师说明：可靠性需要明确“保护边界”和“错误是否可重放”。UEC LLR 规范甚至定义 poisoned FCS：当 replay RAM 或上游数据已不可恢复时，应传播错误而不是反复重放错误副本。UALink 也把 link-correctable error 与 transaction/RAS error 分开处理。[A32][A33]

## Backup Slide T2｜细粒度 transaction：wire efficiency 与 packing latency 的交换

前序术语表把 `Bounded Transaction` 定义为具有稳定身份、有限大小和一次 retirement 的工作单元，并明确它不是数据库原子事务；`Transaction Fragment` 是自描述、幂等、可独立放置的逻辑片段，`Incarnation` 才是某个 fragment 的一次实际传输。`Local Retirement` 只表示 sender 收齐 fragment ACK、可解除 source obligation，不表示 remote consumer 已可见或已执行。目录把 `32–128 KiB` 列为拟讨论粒度，但本版 PDF 没有展开论证；本场的 RDMA message、UCCL chunk、通信 tile 和 GEMM tile 可能承担相似工程作用，却不是同一标准对象。UCCL 默认 32 KiB 来自 CPU/control-coalescing 取舍，GEMM tile 由 dtype、layout、SMEM/TMEM 与并行策略决定，EP token payload 和 KV block 又是另一套粒度。

```text
wire efficiency = useful payload bytes / total wire bytes

4–32 B load/store + fixed headers  →  low efficiency
pack many operations               →  better efficiency, extra wait/state
fixed-size flit                     →  simple scheduling, possible padding
compressed header                  →  less overhead, tighter fabric coupling
```

需要同时回答：

- 按 destination、VC 还是 ordering domain 建 packing queue？
- 什么条件触发发送：size、timer、barrier、credit 还是显式 flush？
- 一个慢 destination 是否阻塞同队列内其他 transaction？
- packet 丢失后，重放的是整个 pack 还是单个 operation？

讲师说明：Ethernet small-message efficiency 不能只用一个百分比概括；VLAN/IP/UDP、header 格式、FCS/IFG、FEC 与最小帧配置都会改变结果。SUE 选择按 destination/VC packing，SUE Lite 将 packing 上限限制为 1 KB；FinePack 则研究如何透明聚合细粒度 P2P store。[A28][A34]

## Backup Slide T3｜Scale-up domain 不是越大越好

```text
addressable accelerators ≠ efficient participants of every operator
```

决定有效域大小的因素：

1. TP/EP/PP/sequence-parallel 的实际 group size。
2. 一层还是多层交换、bisection bandwidth 与每跳延迟。
3. remote outstanding window、SRAM/HBM 配比与 overlap 能力。
4. collective barrier tail、expert skew 与 failure blast radius。
5. placement、partition 和调度器能否保持 locality。

讲师说明：UALink 1.0 的公开目标支持最高 1,024 accelerators，这是 addressability/system capability，不代表每个算子都应跨 1,024 卡。设计时应从模型通信 group 和故障域反推 scale-up domain，而不是从最大地址位宽正推应用规模。[A13][A33]

## Backup Slide T4｜远端延迟最终占用 XPU 的微架构窗口

```text
required outstanding bytes ≥ target bandwidth × observed latency
```

| 操作 | 延迟变大时被占住的资源 |
|---|---|
| remote load | load queue、MSHR/transaction entry、destination registers/buffers |
| remote store | store/commit state、credit、fence dependency、source buffer lifetime |
| TMA / DMA | descriptor、pipeline slot、staging buffer、barrier/counter |
| reliable transfer | replay buffer、sequence/gap state、timer、completion metadata |

讲师说明：异步引擎能把等待移出计算 warp，但不会消除 Little's Law。为了隐藏更长延迟，要增加并发、buffer 或分块；这些都会与 register、SMEM/L2、Tensor Core 和 I/O die area 竞争。公开资料不足以把这种 trade-off 换算成某个产品固定的 300–400 mm²，因此只讲资源方向，不给臆测面积。

## Backup Slide T5｜UCCL：把 transport control plane 放回软件

UCCL 要解决的不是单一算法问题，而是 RDMA transport 的演进速度跟不上 ML workload：

| Workload/部署变化 | 固化 RNIC transport 的缺口 | UCCL 验证的方向 |
|---|---|---|
| collective 的低 flow entropy | 单/少路径 ECMP collision | 多 QP + packet spraying |
| MoE transient incast | sender-driven CC 难保护最后一跳 | receiver-driven EQDS |
| lossy / 长 BDP fabric | Go-Back-N 放大重传 | GPU-memory reorder + selective retransmission |
| 应用知道数据重要性 | NIC 难做 application-transport co-design | 用户态可替换 policy，例如 semi-reliable 研究方向 |
| 多代、多厂商 NIC | CC/reliability 细节不一致 | 在公共软件层尽量统一控制行为 |

```text
collective / P2P / EP API
          ↓ plugin
UCCL CPU engines: CC · LB · pacing · ordering/completion
                  + software ACK/retry on UC/UD
          ↓ UC / RC / UD / AF_XDP
RNIC data path ──GPUDirect──> GPU memory
```

讲师说明：UCCL-Tran 的关键不是“用 CPU 重新发送每个 packet”。UC/RC 仍让 RNIC 做 segmentation/reassembly 和 GPU DMA，CPU 主要处理 transport control。论文中的默认实现按约 32 KB chunk 合并控制与选路决策；对 UC/RC，发送端按 chunk 指定目标 GPU buffer，软件根据 chunk sequence number 组织跨 QP 乱序和消息完成，其中 UC 做软件恢复、RC 保留硬件恢复；对 UD，scatter-gather 把固定 control header 与 payload 分到 CPU/GPU，接收端再把 packet-level reorder 融入已有 reduction kernel。[A40]

| 路径 | UCCL 如何借用现有 RNIC 能力 | 主要代价 |
|---|---|---|
| UC | write-with-immediate；绕过硬件 CC/可靠性，保留分段与重组卸载 | 不是所有 RNIC 都支持 UC |
| RC | 在条件允许时关闭硬件 CC，再复用 write-with-immediate | 仍受 RC 固化可靠性/乱序语义影响 |
| UD | send/recv + scatter-gather；软件做分段、重组和重排 | CPU 开销更高，GPU 需要额外 scattered copy |

为了接近硬件路径性能，论文还组合了四项工程手段：

1. run-to-completion engine，把 TX/RX、pacing、timeout 与 retransmission 放入同一轮询循环；
2. connection splitting，让一个高带宽 connection 可由多个 CPU engine 分担；
3. 默认约 32 KB control coalescing，以 chunk 而非逐 packet 做大部分控制决策；
4. UD 上 chained posting，一次 MMIO 提交多个 send/recv WQE。

论文用三类 case study 说明 extensibility：Swift/CUBIC 风格 sender-driven multipath、面向 incast 的 receiver-driven EQDS、以及 selective retransmission。其 UC/RC 默认可使用最多 256 个 QP path，并让同一 NIC pair 上的多条 UCCL connection 共享 QP 集合；“256 paths”不是要求每个应用 connection 永久独占 256 份完整 transport state。[A40]

论文对 QP scalability 的解释同样不能省略：ML collective 通常传输大消息和接近 MTU 的 packet，能摊薄 QP context swap；在论文采用的 PCIe topology 上，GPUDirect payload 主要经过 GPU/NIC 所在 PCIe switch，而 QP context fetch/verb posting 走 CPU 侧路径，降低了两类流量的直接竞争。这是论文 testbed 的解释，不是所有主板拓扑都天然成立。[A40]

讲师说明：论文报告的 4.5×、1.9× 和 EQDS tail-latency 改善都绑定具体 NIC、拓扑、GPU、消息大小和对照实现，不能写成“UCCL 普遍比 RDMA 快 4.5×”。论文在其 CX-7 环境中报告单 CPU core 可处理 400 Gb/s 单向 UC/RC traffic，EFA/UD 路径借助 chained posting 报告单核 100 Gb/s；这些同样是 testbed result。更重要的结论是：在 GPU server 中存在可利用的 host CPU 预算时，控制路径可以先在软件中快速迭代；但 CPU 利用率、PCIe/NUMA 位置、NIC timestamp/ECN 可见性、QP context 和 workload 粒度决定了它是否能保持线速。[A40][B16]

```text
UCCL: existing RNIC + software-extensible endpoint
Falcon: hardware/SmartNIC transport with programmable mechanisms
UET: standardized wire-level transport and endpoint semantics
```

三者不是同一个层次的替代品：UCCL 更适合验证和部署 transport policy，Falcon 把更多状态和处理放进专用硬件，UET 解决协议互操作与规范化；最终系统仍需分别回答 placement、ordering、completion、拥塞和故障恢复问题。[A31][A32][A40]

## Backup Slide MRC1｜MRC 一次路径故障的事件时间线

这张备份页用于答疑，不计入 88 页主讲编号：

```text
t0  chunk 被拆成 packet/placement units
    └─ ECMP entropy 或 static SRv6 选择多个 path
t1  packet spray 到达顺序不同
    └─ RDMA virtual address/remote key + placement metadata 直接写入目标 buffer，记录 gap/duplicate
t2  某条 path 出现 ECN、trim、NACK 或 health failure
    └─ 只重传缺失范围，并暂时避开/重映射受影响的 EV/path
t3  SACK 覆盖所需 bytes，transport completion 恢复
    └─ consumer fence/ordering 满足后，GPU 继续计算
t4  若语义是 SEND/RECV、READ 或 ATOMIC
    └─ 不能假设 MRC transport 已覆盖，需检查 fallback 与新 tail
```

| 观察点 | 应记录的证据 | 不能直接推出的结论 |
|---|---|---|
| 路径健康 | per-path RTT、ECN、trim、port status、bytes | 某个端口异常不等于整个 job 必然失败 |
| 可靠性 | SACK/NACK、gap、duplicate、retransmitted bytes | 重传完成不等于远端应用已经执行 |
| 训练进度 | QP state、step throughput、rank skew、checkpoint | throughput 暂时下降不等于协议违反 SLA |
| 语义覆盖 | WRITE/WRITE_IMM opcode、fallback path、ordering fence | “RC-compatible”不等于所有 verbs 已兼容 |

讲师说明：论文的 50K-GPU 光模块案例应按这条时间线讲，明确它是一个公开报告的故障观察，不是对所有 MRC 部署的保证。若现场有人把 MRC 与 RFC 5041 DDP 直接画等号，回到 Slide 27：两者共享 direct-placement 思想，但 wire identity、可靠性和支持的 RDMA 语义不同。[A9][A10][A30][A42]

## Backup Slide R1｜Rubin sparse Attention：减少 movement，但不是透明压缩

```text
dense QKᵀ scores in TMEM
  → tcgen05.ld{.red}.spcompress: select 2 of every 4 + metadata
  → sparse softmax on retained values
  → dtype/layout staging
  → sparse P × dense V
```

讲师说明：PTX 9.4 的 `tcgen05.ld{.red}.spcompress` 为 `sm_107a` architecture-specific feature，从 TMEM 读取 FP32 数据时执行 2:4 选择，输出压缩数据和位置 metadata；`.red` 还能返回 min/max reduction，但不等于完整 softmax。它减少 TMEM→register movement、保留值的 exponent/normalization 和后续 sparse MMA 工作，却仍有 conversion、layout repack、metadata staging 与同步成本。更关键的是，被删掉的 logits 通常不为零，Attention 语义和精度可能改变，所以不能宣称“免费 2× Attention”。[A19][A20]

放入备份页的原因：这能很好说明“算法改变 bytes”，但主线更关注通信；只有在讲到 compression 与 communication volume 时再展开。

---

# 制作图表清单

1. PCIe + NVLink/NVSwitch + NIC 的节点内物理图。
2. AMD xGMI/Infinity Fabric、Ascend HCCS 的同层对照图。
3. CloudMatrix 384/SuperPoD 独立画成跨 server/rack scale-up，不放入“单机”图。
4. Blackwell 双 compute-die 图：物理 die + HBM 资源 + NV-HBI，外框标 unified single GPU；不画未经披露的 HBM/L2 精确归属或 coherence 结构。
5. `address placement ↔ CTA placement ↔ cache placement` 三角图，并列出 locality 与 load balance 的冲突。
6. MCM-GPU→CARVE→HMG→PROACT→FinePack 时间线，所有节点明确标 research proposal。
7. Volta→Ampere→Hopper→Blackwell→Rubin data-movement 时间轴，统一画出 RF/SMEM/TMEM/HBM/remote GPU。
8. Rubin TMA descriptor sharing：per-expert descriptor vs shared descriptor + runtime override。
9. Blackwell bulk PDL 与 Rubin tile-level dependent coordination 的 timeline；Rubin 内部实现标“未披露”。
10. 普通 remote write+flag 与 counted write 的完成通知对照图。
11. Fat Tree、rail-optimized、3D torus 三图使用同一 endpoint 数量与图例。
12. Ring AllReduce 与 SHARP aggregation tree 的 reduce-location 对照。
13. reliability stack：FEC/LLR、flow control、E2E retry、runtime recovery 的故障覆盖矩阵。
14. multipath direct placement：三条乱序路径写入不同 offset，最后统一 completion。
15. Go-Back-N、selective retry、SACK bitmap 的发送/接收 buffer timeline。
16. BDP→replay/reorder/QP/PDC state→Die area 的资源流图；不标未经披露的 mm²。
17. Scale-up/scale-out reliability boundary：XPU—local fabric—I/O memory appliance—routed fabric。
18. DeepEP/NCCL EP/UltraEP/MoonEP 二维图：通信路径 × 负载均衡策略。
19. DualPath 与 HiSparse 用两张不同层次的数据流图，避免合并。
20. UCCL data/control split：GPU payload 走 GPUDirect，CPU engine 处理 CC/LB/order/completion，并在 UC/UD 路径处理 ACK/retry；旁边画 UC、RC、UD 三条兼容路径与信号可见性边界。

---

# 事实边界与演讲限定

- `Blackwell 双 Die / NV-HBI`：官方可讲“two reticle-limited dies”“10 TB/s chip-to-chip interconnect”“single, unified GPU”。这三个短语不能外推为所有路径等距、完整硬件 cache coherence、具体 cross-die latency、链路单向/双向拆分或 CTA affinity 实现。
- `MCM-GPU / CARVE / HMG / PROACT / FinePack`：均作为研究路线讲，不作为 GB200 内部实现证据。尤其不能把 L1.5、RDC、hierarchical directory、remote write queue 直接画进 Blackwell 产品框图。
- `coherence vs consistency`：cache coherence 管副本值，memory consistency/scope 管可观察顺序；kernel-boundary flush/invalidation 是机制，NUMA locality 是访问距离。正式 PPT 中四个术语不能混用。
- `CloudMatrix384`：华为官方可确认它是构建在 Atlas 900 A3 SuperPoD 上的云服务实例，后者最多包含 384 个 Ascend 910C；板级布线和交换结构如使用第三方图，页脚必须注明来源、发布日期和“非官方拓扑”。
- `Ascend 950 / collective engine`：华为官方发布页可确认 Ascend 950 路线、2 TB/s interconnect 和 UnifiedBus 方向，但本稿采用的一手资料不足以确认所谓 CCU 的内部微架构；主讲只保留“dedicated engine”作为设计空间，不画产品内部框图。
- `ICMS`：2026 公开材料中又出现 `CMX Context Memory Platform` 品牌。讲稿应说明名称演进，不把二者写成两个独立产品。
- `MegaMoE`：DeepGEMM 与 FlashInfer 是两个独立实现。DeepGEMM 主讲证据固定到 PR #304（merge `7f2a703e`）及后续 PR #328（merge `67fc6486`）；FlashInfer CuTeDSL 路径固定到审校时 commit `bac0eb790e93221a477cca7fcc1c505210b5bb92`。所有描述绑定 GPU 架构、dtype 与版本，不把项目 benchmark 当通用性能结论。
- `HiSparse`：按 SGLang feature 讲。引用固定到审校时 SGLang commit `22e4b3a81f6362123faac44d87e548a29e8f679f` 及列出的功能 PR；后续接口变化不反向修改本稿事实。
- `MoonEP/UltraEP`：均为 2026 新项目。项目自报性能只可作为各自配置下结果，不能直接横向比较。
- `Rubin tile-level dependent coordination`：官方只公开行为与 timeline；截至 PTX 9.4 Developer Preview，完整 runtime/PTX 接口与硬件调度实现未披露，不画 polling/barrier 微架构猜测图。
- `Counted writes`：Rubin 官方把它作为 NVLink 通信优化，但 `fabric.* counted::bytes` 已在 PTX 9.3、`sm_100+` 出现；必须区分“Rubin 官方重点能力”与“ISA 首次出现”。
- `TMA runtime override / applypriority async bulk`：PTX 9.4、`sm_107f` family-specific；`tcgen05.ld{.red}.spcompress` 是 `sm_107a` architecture-specific。不要把两类 target 混写。
- `Rubin 频率、L2 容量、I/O die 面积收益`：当前没有足够官方证据，不进入主讲结论；由峰值算力反推频率只可作为个人假设。Blackwell NV-HBI 的官方 10 TB/s 产品口径已单独用于 Slide 14，不把该数值外推到 Rubin。
- `lossless vs reliable`：PFC/CBFC/credit、LLR、端到端 retry 和应用恢复覆盖不同故障。正式 PPT 不用“无损即可保证永不丢包”或“LLR 可替代所有端到端可靠性”这类绝对表述。
- `RFC 5041 DDP`：Tagged Buffer 使用 STag + Tagged Offset；Untagged Buffer 使用 Queue Number + MSN + Message Offset。不要写成所有 iWARP/DDP packet 都带 MSN+MO；RFC 本身仍要求可靠、按序 delivery。
- `SUE / SUE Lite`：Broadcom 2025-09-26 官方 framework 可确认 full SUE 的 Go-Back-N、fixed-window CC，以及 SUE Lite 移除 end-to-end reliable transport/CC、只保留 hop-by-hop LLR。`up to 50%` 指 SUE IP，且 MAC/Link/PHY 大小不变；不能扩写为整个 I/O die 或 XPU 面积减半。
- `UALink 1.0`：可确认 accelerator↔switch 每段 link-level replay、credit flow control、正常路径 lossless，以及更高层的 RAS/drop/isolation/timeout。`end-to-end data protection` 不等于存在一个覆盖所有故障的透明 end-to-end retransmission protocol。
- `UEC 1.0`：规范的重点是 backend scale-out；它定义 RUD/ROD、SACK、packet window、multipath 与多种 CC。不要把它当成 UALink/SUE 的同层替代，也不要声称其所有实现都采用某个单一 rate-或window-based 算法。
- `Falcon`：官方可讲 lossy Ethernet、multipath、细粒度 RTT、hardware-enforced traffic shaping、fast retransmission、flexible ordering 与多 ULP。论文中的吞吐、Mops、tail 或丢包结果必须连同实验配置引用，不能提升为产品通用保证。
- `ConnectX-8 PSA/DPA`：官方公开材料可确认 advanced routing、telemetry-based congestion control，以及 DOCA DPA programmable congestion-control events；当前证据不足以画 PSA 内部流水线、八平面实现或断言某段算法一定运行在哪个处理器上。
- `UCCL`：论文 v2 描述的是在现有 RDMA NIC 上解耦 data/control path、由 host CPU 运行可扩展 transport control 的研究与实现。UC 是优先路径；RC/UD 是受 NIC 能力约束的兼容路径。论文性能数字只代表其 testbed，不外推为所有 NIC/拓扑的通用收益。当前开源仓库已扩展到 UCCL-Tran/P2P/EP，需与原论文范围分开。
- `前序演讲的候选词汇`：`Software Connection / Reliable Tunnel / Physical Path / DMA Context / Bounded Transaction` 在新版 PDF 的术语表和后续分层讨论中被提出，但仍不是当前标准协议的通用术语。讲稿把它们作为分析问题，不宣称 UET、Falcon、UCCL、SUE 或 UALink 已采用同一对象模型。
- `传统 RC QP`：QP 常把寻址、顺序、可靠性、路径和 queue progress 关联起来，但不同 RNIC 与传输类型已有 SRQ/DC/adaptive routing/selective recovery 等扩展；不使用“所有 RC 永远单路径、Go-Back-N、依赖 PFC、出错必杀 QP”的绝对表述。
- `Tile Load/Store 与 SQ/CQ`：新版前序 PDF 已将 Tile Load/Store、Descriptor、Barrier、Commit、Wait 作为架构语言展开，但它们不是跨厂商标准 API。地址式/tile 式 API 可以把 SQE/CQE bookkeeping 移入 compiler/runtime 或 device engine，但不能消灭有限 queue、credit、translation/protection、retry、completion 和 backpressure。`32–128 KiB` 只作为前序设计讨论的粒度范围，不当作跨 workload 或协议的固定最优值。
- `跨机器 memory hierarchy`：把远端资源映射进地址空间不会自动获得本地内存的 failure/coherence semantics。跨管理域仍需 capability、撤销/generation、partial completion、unknown result、endpoint reset 与一致性范围定义。
- `Scale-up/scale-out fusion`：通过 I/O memory/DPU/communication appliance 放置可靠性边界是架构选项。NetDAM 只能标为作者方案/研究设计；需要同时说明 staging、ownership、ordering、backpressure 和新增故障域。
- `未经采用的量化数字`：不使用“5% 丢包仍 90% goodput”“Scale-Up IP 300–400 mm²”“TPU 单算子最多 512 卡”等未完成一手核验或强依赖配置的数字。

---

# 主要参考资料

## 硬件、网络与协议

- [A1] NVIDIA, *NVLink and NVSwitch* product/architecture documentation: https://www.nvidia.com/en-us/data-center/nvlink/
- [A2] NVIDIA, *DGX/HGX platform architecture documentation*: https://docs.nvidia.com/dgx/
- [A3] AMD ROCm, *AMD Instinct MI300 Series microarchitecture*, including MI300 package and eight-GPU node-level Infinity Fabric topology: https://rocm.docs.amd.com/en/latest/reference/gpu-arch/mi300.html
- [A4] Huawei, *Groundbreaking SuperPoD Interconnect: Leading a New Paradigm for AI Infrastructure*, 2025-09-18: https://www.huawei.com/en/news/2025/9/hc-xu-keynote-speech
- [A5] NVIDIA Networking, ConnectX / BlueField / Spectrum documentation: https://docs.nvidia.com/networking/
- [A6] NVIDIA DOCA documentation: https://docs.nvidia.com/doca/
- [A7] AWS, *Elastic Fabric Adapter*: https://aws.amazon.com/hpc/efa/
- [A8] AWS Neuron documentation: https://awsdocs-neuron.readthedocs-hosted.com/
- [A9] OpenAI, *Supercomputer networking to accelerate large scale AI training*, 2026-05-05: https://openai.com/index/mrc-supercomputer-networking/
- [A10] *Resilient AI Supercomputer Networking using MRC and SRv6*, arXiv:2605.04333: https://arxiv.org/abs/2605.04333
- [A11] NCCL documentation and topology-aware collective literature: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/
- [A12] Google Cloud, TPU system architecture documentation: https://cloud.google.com/tpu/docs/system-architecture-tpu-vm
- [A13] UALink Consortium specifications/news: https://ualinkconsortium.org/
- [A14] NVIDIA, SHARP documentation: https://docs.nvidia.com/networking/display/sharpv320
- [A15] NVIDIA NCCL User Guide: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/
- [A19] NVIDIA, *Inside NVIDIA Rubin GPU Architecture: Powering the Era of Agentic AI*, 2026-07-21: https://developer.nvidia.com/blog/inside-nvidia-rubin-gpu-architecture-powering-the-era-of-agentic-ai/
- [A20] NVIDIA, *PTX ISA 9.4 — CUDA 13.4 Developer Preview*: https://docs.nvidia.com/cuda/developer-preview/13.4/parallel-thread-execution/index.html
- [A21] NVIDIA, *CUDA Programming Guide: Programmatic Dependent Launch and Synchronization*: https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/programmatic-dependent-launch.html
- [A22] NVIDIA, *CUDA Toolkit 13.4 Developer Preview Release Notes*: https://docs.nvidia.com/cuda/developer-preview/13.4/cuda-toolkit-release-notes/index.html
- [A23] NVIDIA, *NVIDIA Blackwell Architecture* / Blackwell launch announcement. Official wording: “two reticle-limited dies connected by a 10 terabytes per second (TB/s) chip-to-chip interconnect in a unified single GPU”: https://www.nvidia.com/en-us/data-center/technologies/blackwell-architecture.md and https://nvidianews.nvidia.com/news/nvidia-blackwell-platform-arrives-to-power-a-new-era-of-computing
- [A29] Mittal et al., *Revisiting Network Support for RDMA* (IRN), SIGCOMM 2018, DOI 10.1145/3230543.3230557: https://arxiv.org/abs/1806.08159
- [A30] IETF RFC 5041, *Direct Data Placement over Reliable Transports*, October 2007: https://www.rfc-editor.org/rfc/rfc5041.html
- [A42] Open Compute Project, *Multipath Reliable Connection (MRC) Specification 1.0*: https://www.opencompute.org/documents/ocp-mrc-1-0-pdf
- [A31] Singhvi et al., *Falcon: A Reliable, Low Latency Hardware Transport*, SIGCOMM 2025, DOI 10.1145/3718958.3754353: https://dl.acm.org/doi/10.1145/3718958.3754353 ; Google Cloud overview: https://cloud.google.com/blog/topics/systems/introducing-falcon-a-reliable-low-latency-hardware-transport
- [A32] Ultra Ethernet Consortium, *Ultra Ethernet Specification 1.0*, June 2025: https://ultraethernet.org/wp-content/uploads/sites/20/2025/06/UE-Specification-6.11.25.pdf
- [A33] UALink Consortium, *UALink 200G Specification Rev 1.0 — Evaluation Copy*, April 2025: https://ualinkconsortium.org/wp-content/uploads/2025/04/UALink200_Specification_v1.0_Evaluation_Copy.pdf
- [A34] Broadcom, *Scale-Up Ethernet Framework Specification*, Scale-Ethernet-RM104, 2025-09-26: https://docs.broadcom.com/docs/scale-up-ethernet-framework
- [A35] NVIDIA, *ConnectX-8 SuperNIC User Manual — Introduction*: https://networking-docs.nvidia.com/connectx8hw/introduction
- [A36] NVIDIA DOCA, *DPA Development* documentation, including Programmable Congestion Control events: https://networking-docs.nvidia.com/doca/archive/3-4-0/dpa-development
- [A37] Graham et al., *An In-Network Architecture for Accelerating Shared-Memory Multiprocessor Collectives*, ISCA 2020, DOI 10.1109/ISCA45697.2020.00085: https://doi.org/10.1109/ISCA45697.2020.00085
- [C2] NVIDIA Rubin/BlueField-4 ICMS/CMX public materials: https://resources.nvidia.com/en-us/accelerated-networking-resource-library/cmx-tech-blog

## 软件、论文与开源项目

- [A16] *Mooncake: A KVCache-centric Disaggregated Architecture for LLM Serving*, FAST 2025 / arXiv:2407.00079: https://arxiv.org/abs/2407.00079
- [A17] *DualPath: Breaking the Storage Bandwidth Bottleneck in Agentic LLM Inference*, arXiv:2602.21548: https://arxiv.org/abs/2602.21548
- [A18] Zheng et al., *TileLink: Generating Efficient Compute-Communication Overlapping Kernels using Tile-Centric Primitives*, MLSys 2025 / arXiv:2503.20313: https://arxiv.org/abs/2503.20313
- [A24] Arunkumar et al., *MCM-GPU: Multi-Chip-Module GPUs for Continued Performance Scalability*, ISCA 2017, DOI 10.1145/3079856.3080231: https://research.nvidia.com/publication/2017-06_mcm-gpu-multi-chip-module-gpus-continued-performance-scalability
- [A25] Young et al., *Combining HW/SW Mechanisms to Improve NUMA Performance of Multi-GPU Systems* (CARVE), MICRO 2018, DOI 10.1109/MICRO.2018.00035: https://research.nvidia.com/publication/2018-10_combining-hwsw-mechanisms-improve-numa-performance-multi-gpu-systems
- [A26] Ren et al., *HMG: Extending Cache Coherence Protocols Across Modern Hierarchical Multi-GPU Systems*, HPCA 2020, IEEE 9065597: https://research.nvidia.com/publication/2020-02_hmg-extending-cache-coherence-protocols-across-modern-hierarchical-multi-gpu
- [A27] Muthukrishnan et al., *Efficient Multi-GPU Shared Memory via Automatic Optimization of Fine-Grained Transfers* (PROACT), ISCA 2021, DOI 10.1109/ISCA52012.2021.00020: https://research.nvidia.com/publication/2021-06_efficient-multi-gpu-shared-memory-automatic-optimization-fine-grained-transfers
- [A28] Muthukrishnan et al., *FinePack: Transparently Improving the Efficiency of Fine-Grained Transfers in Multi-GPU Systems*, HPCA 2023, DOI 10.1109/HPCA56546.2023.10070949: https://doi.org/10.1109/HPCA56546.2023.10070949
- [A38] MPI Forum, *MPI: A Message-Passing Interface Standard, Version 4.1*, November 2023: https://www.mpi-forum.org/docs/mpi-4.1/mpi41-report.pdf
- [A39] Fang and Peng, *NetDAM: Network Direct Attached Memory with Programmable In-Memory Computing ISA*, arXiv:2110.14902, 2021: https://arxiv.org/abs/2110.14902
- [A40] Zhou et al., *UCCL-Tran: An Extensible Software Transport Layer for GPU Networking*, OSDI 2026, pp. 1143–1166: https://www.usenix.org/conference/osdi26/presentation/zhou-yang ; public preprint arXiv:2504.17307v2: https://arxiv.org/abs/2504.17307v2
- [A41] Jiang et al., *Orderlock: A New Type of Deadlock and its Implications on High Performance Network Protocol Design*, SIGCOMM 2025, pp. 575–591, DOI 10.1145/3718958.3750497: https://doi.org/10.1145/3718958.3750497
- [A43] Xiaoyu Ma et al., *Challenges and Research Directions for Large Language Model Inference Hardware*, arXiv:2601.05047: https://arxiv.org/abs/2601.05047
- [A44] Hongyi Zeng et al., *Connecting 100K+ GPUs: Building the Communication Stack for Large-Scale LLM Training*, ACM SIGCOMM 2026, pp. 505–518, DOI 10.1145/3789240.3829152: https://doi.org/10.1145/3789240.3829152. The local user-provided PDF reports Meta production deployment and experiment-specific results.
- [B1] NVIDIA NCCL Extensions / NCCL EP, commit `9f47d6eb3b60962d8157a579b4caaaa4ae6b19f4`: https://github.com/NVIDIA/nccl-extensions/tree/9f47d6eb3b60962d8157a579b4caaaa4ae6b19f4
- [B2] Mooncake repository, commit `51e594d3a21660bdf2f6f1f11ec544b7cfb06932`: https://github.com/kvcache-ai/Mooncake/tree/51e594d3a21660bdf2f6f1f11ec544b7cfb06932
- [B3] DeepEP repository, commit `01dc3aaac82068020353dce2c302e38153c0bfaa`: https://github.com/deepseek-ai/DeepEP/tree/01dc3aaac82068020353dce2c302e38153c0bfaa
- [B4] UltraEP repository, commit `94cab099b44fffa99a82fea99e7c12d89cf65e4f`: https://github.com/Dots-Infra/UltraEP/tree/94cab099b44fffa99a82fea99e7c12d89cf65e4f
- [B5] MoonEP repository, commit `7745ffa00532d9086b49bab84a65b17f687ede14`: https://github.com/MoonshotAI/MoonEP/tree/7745ffa00532d9086b49bab84a65b17f687ede14
- [B6] Triton-distributed repository, commit `8260bc34398c2b8f36dc840fd22f741ca9294584`: https://github.com/ByteDance-Seed/Triton-distributed/tree/8260bc34398c2b8f36dc840fd22f741ca9294584
- [B7] FlashInfer MoE EP / CuTeDSL MegaMoE, repository commit `bac0eb790e93221a477cca7fcc1c505210b5bb92`: https://github.com/flashinfer-ai/flashinfer/tree/bac0eb790e93221a477cca7fcc1c505210b5bb92/flashinfer/moe_ep/kernel_src
- [B8] SGLang HiSparse implementation at commit `22e4b3a81f6362123faac44d87e548a29e8f679f`; initial sparse-attention integration PR #20343, PD direct-to-Decode-DRAM PR #21591, DeepSeek V4 direct-to-host PR #24880: https://github.com/sgl-project/sglang/tree/22e4b3a81f6362123faac44d87e548a29e8f679f
- [B9] SGLang Mooncake Store integration at the same pinned commit: https://github.com/sgl-project/sglang/tree/22e4b3a81f6362123faac44d87e548a29e8f679f/python/sglang/srt/mem_cache/storage/mooncake_store
- [B10] DeepSeek, DeepGEMM PR #304, *Introducing Mega MoE, FP4 Indexer and other features/fixes*, merged as `7f2a703e`: https://github.com/deepseek-ai/DeepGEMM/pull/304
- [B11] DeepSeek, DeepGEMM PR #328, *Mega MoE optimizations & benchmarks*, merged as `67fc6486`: https://github.com/deepseek-ai/DeepGEMM/pull/328
- [B12] FlashMoE, *Fast Distributed MoE in a Single Kernel*, NeurIPS 2025 / arXiv:2506.04667; code commit `9cc0c32443d2a2da6825a68af5ef83060329483b`: https://github.com/osayamenja/FlashMoE/tree/9cc0c32443d2a2da6825a68af5ef83060329483b ; paper: https://arxiv.org/abs/2506.04667
- [B13] NVIDIA NVSHMEM repository, commit `f86be2c6c390448cc4e0c32db9f27f5dbc345b67`: https://github.com/NVIDIA/nvshmem/tree/f86be2c6c390448cc4e0c32db9f27f5dbc345b67
- [B14] ByteDance FLUX, a communication-overlapping library for tensor/expert parallelism, commit `19831ca2d820e3e782ed1d15d8b52d0898b78b26`: https://github.com/bytedance/flux/tree/19831ca2d820e3e782ed1d15d8b52d0898b78b26
- [B15] NVIDIA CUTLASS distributed GEMM examples, commit `dcf215af68a2d08d305076c152a06f201728cd53`: https://github.com/NVIDIA/cutlass/tree/dcf215af68a2d08d305076c152a06f201728cd53/examples/65_distributed_gemm
- [B16] UCCL repository, commit `d94b5bf2e45bd21c40ccd10163453e91fd9d30c8`; current project scope includes UCCL-Tran, UCCL-P2P and UCCL-EP: https://github.com/uccl-project/uccl/tree/d94b5bf2e45bd21c40ccd10163453e91fd9d30c8
- [C3] SemiAnalysis, *Cerebras's Next Generation CS-4: Fast Just Got Faster*, Myron Xie et al., 2026-08-19. User-provided excerpt from a paid secondary analysis; no stable public URL supplied.
- [C4] Public Groq architecture/product materials and user-provided zartbot commentary. Used only for the high-level compiler/static-scheduling, spatial-dataflow and SRAM-centric design-space description; unpublished microarchitecture and quantitative claims are intentionally excluded.

---

# 特别鸣谢

特别感谢微信公众号 **zartbot** 长期整理并分享 GPU 多 Die、缓存一致性、RDMA、Scale-Up/Scale-Out 与可靠传输相关资料。本文在确定问题脉络和扩展阅读范围时重点参考了以下文章（微信公众号文章未找到稳定公开永久链接，按标题与来源记录，访问日期 2026-08-21）：

- 《英伟达 GB200 架构解析 4：BlackWell 多 die 和 Cache 一致性相关的分析》
- 《谈谈 RDMA 和 ScaleUP 的可靠传输》
- 《“漫”谈 RDMA 现代化》及《谈谈 OpenAI 发布的 MRC》
- 《大语言模型推理硬件的挑战与研究方向》
- SemiAnalysis, *Cerebras's Next Generation CS-4: Fast Just Got Faster*（用户提供的付费文章摘录）
- 《Connecting 100K+ GPUs: Building the Communication Stack for Large-Scale LLM Training》（用户提供的 SIGCOMM 2026 PDF）

后两篇 RDMA 文章按科普/评论性二手阅读使用：吸收其问题意识和教学比喻，不把其中的厂商自报数字、竞争性评价或未限定结论作为科学证据。具体产品事实、协议字段和量化数字仍尽量回溯至上列官方文档、标准、论文和固定版本的开源仓库。文中若有疏漏，由本稿作者负责。
