# DabaiPet 循环开发运行态看板（LOOP_STATUS）

> 由 **`ORCH`（`codex 6.2 astra xhigh`）** 实时维护。每完成一次派发、门禁校验、升级切换或人工签收均须更新本表。

- **交付范围**为 Iteration 0–3 的桌宠、本地及 BYOK 对话、按需持续语音。2026-11-27 用户确认新版可用、麦克风可正常关闭，并决定暂缓 Iteration 4 摄像头猜拳。
- 过程回执保存在项目本机的 `.local-evidence/`，其中包含设备信息和诊断日志。克隆仓库后的构建与复验入口见 [README](../README.md)。
- **Orca 调度**：当前 Run 为 `run_0373dd1cd67c`。ORCH 使用下方登记的固定窗口派单，同一模型的任务依次执行。
- Neon 下次在原窗口启动时使用 Agy 的会话参数 `--mode accept-edits` 处理任务范围内的常规编辑。删除已有文件、修改系统或安全设置前先告知用户。
- **本轮放行依据**为用户对 G2 内置屏签名成品的回覆「G2 正常」。外接显示器真机测试与 WindowServer CPU 增量继续延期。
- **Escalation Policy**：`IMPL` 失败累计：尝试 #1（主责）→ #2（`codex 6.2 astra high`）→ #3（`Agy · Neon`）→ #4（`Agy · Claude Opus 5.5`）→ `BLOCKED`（人工审核）；`ENV`/`SPEC` 失败不计数
- **Test Count Baseline**：持续对话签名版的 `.gate_test_baseline` 为 `82`。

| 角色 | 固定执行窗口 | Orca 终端句柄 |
| --- | --- | --- |
| DEV-L | 6.2 Sol ultra（复用已结束手测的终端） | `term_46eb961f-163d-4df8-bfca-7ef55c545d9c` |
| DEV-H | 6.2 Astra high | `term_e1340ed6-7cbd-4ed3-b1cc-24bba88f452b` |
| UIUX / RESCUE-1 | Gemini 4 Neon | `term_c06a712e-676b-400d-b5fd-6ca8ddced243` |

---

## 前置人工准备

| 项目 | 状态 | 说明 |
| :--- | :---: | :--- |
| 钥匙串创建 `DabaiPet Local Dev` 代码签名证书 | `DONE` | 已导入 `login.keychain-db` 并仅信任 `codeSign`（`SHA-1: 8FB31CF5305E65E32FDE12A5A1D0BB62A73888E5`，`security find-identity -v -p codesigning` 返回 `1 valid identities found`） |

---

## 全量 Ticket 状态总表

### Iteration 0：工程基建、门禁与契约冻结
| Ticket | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 门禁结果 | 备注 / 证据 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| T0.1 | SwiftPM 4-Target 骨架 + Swift Testing | `DEV-L` (`SOL ultra`) | `DONE` | 0 | PASS | 4 targets；CLT Swift Testing 1/1，ORCH 增量实测 1.032s |
| T0.2a | `Info.plist` + 自签名 `build_app.sh` | `DEV-L` (`SOL ultra`) → `DEV-H` | `DONE` | 1 | AC-0.2 PASS | 首次签名后 build_app.sh 第 52 行提取证书参数错误（signer-: No such file or directory），已升级 DEV-H 改为按身份摘要单次签名，重验签名与 DR 通过 |
| T0.2b | 硬门禁 `verify_gate.sh`（含自测夹具）+ `evidence.sh` | `ORCH` (`codex 6.2 astra xhigh`) | `DONE` | 0 | AC-0.3 PASS | 24 个扫描夹具，完整门禁退出码 0 |
| T0.3 | 核心契约冻结 + 锁定 `AcceptanceTests` | `ORCH` (`codex 6.2 astra xhigh`) | `DONE` | 0 | PASS | 已锁定 7 项契约测试（SHA-256 清单），总测试 8/8；状态转换行为由 T1.1 验证 |

### Iteration 0.5：MVP 前置可行性探针（真机二元签收）
| Spike | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 真机签收 | 备注 / 基线数值 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| S1 | 自签名跨重建 TCC/Keychain + `counterForEventType` 权限 | `DEV-H` | `PASS（固定服务）` | 0 | 技术证据通过 | 主程序直接读取旧条目的两轮记录均为 FAIL（−25293）。固定签名 XPC 冷启动复测通过。既有独立实测记录麦克风授权跨重建保留、AX=false 时按键增量为 1。 |
| S2 | 透明穿透、拖拽与中文 IME | `DEV-H` | `DONE` | 0 | 人工 PASS | 用户按清单反馈“都正常”。本轮有 2 次短按、9 次拖拽结束；非激活聊天窗依次记录组字、上屏、发送。MVP 优先沿用此焦点模式。 |
| S3 | 内置屏宽窗画布内滚动与 `visibleFrame` 边界 | `DEV-H` | `DONE` | 0 | 内置屏人工 PASS | 三次滚动采样 264 / 265 / 266 帧均通过，用户确认画面正常。外接显示器真机验证延期。 |
| S4 | 性能基线标定（空壳 / Canvas 30FPS / CALayer 呼吸） | `DEV-H` | `DONE`（本轮范围） | 0 | 内存与 App CPU 达标，WindowServer 延期 | 默认呼吸两次增量为 +10.84、+10.47 个百分点。15 Hz 候选前两组空窗漂移分别为 +11.190、−12.170 个百分点。同窗交错实测增量为 +2.185 个百分点，95% 区间为 −2.665 至 +7.035，跨过 +1.5 门槛。[前两组测量](../.local-evidence/orca-run-0373dd1cd67c/s4-paired/report.md) · [同窗交错报告](../.local-evidence/orca-run-0373dd1cd67c/s4-crossover/report.md) |

本机原始证据位于 `.local-evidence/spikes/`。S1 的 `s1-passive/summary.json` 和 `keychain-acl.log` 对应两次干净重编；人工轮证据在 `manual-Yo8ntA/s1/summary.json` 和 `manual-Yo8ntA/parallel-counter/result.json`。S3 的 `s3-auto.json` 记录内屏与独立负坐标夹具；S4 的 `s4-run1/comparison.md`、`s4-repeat/diagnostic.md`、`s4-limited/diagnostic.md` 分别保留首测、默认复测及 15 Hz 候选实测。

S2 与 S3 内屏人工签收对应[本轮操作回执](../.local-evidence/spikes/interaction-HUO3bn/interaction.json)。主观体验以用户在会话中的“都正常”为据。

S4 首测空窗 / Canvas / CALayer 的物理内存分别为 12.666 / 97.436 / 12.977 MB，App 平均 CPU 分别为 0.037% / 5.600% / 0.000%。按空窗 +25 MB 计算的本机候选内存上限为 37.666 MB。保留 App CPU 0.8% 与 WindowServer 增量 1.5 个百分点的原目标。默认呼吸在两次物理采样中超线。试验结论属于架构可行性数据，计入探针结果，未触发代码修复熔断。

ORCH 已按预注册顺序，从同窗交错试验的原始 `top`、`footprint` 与窗口回执复算 8 块、32 段、160 个有效秒样本。候选内存平均增加 12,285 字节，App CPU 在 `top` 的显示精度下为 0.0%。专设空对空检查通过，但前四块与后四块的 WindowServer 平均增量分别为 +4.015 和 +0.355 个百分点，落在门槛两侧。该指标的技术结论仍为待验，用户已将其延期。[预注册规则](../Spikes/S4Crossover/protocol.md) · [逐块差值](../.local-evidence/orca-run-0373dd1cd67c/s4-crossover/block-differences.csv)

S1 由 ORCH 核对原始回执后裁决。A/B 主程序 CDHash 不同、DR 相同，服务 SHA-256 与 CDHash 相同；服务加入同一登录会话，先后使用两个不同 PID，禁交互新增及读取均返回 0，摘要匹配。错误标识的宿主在钥匙串操作前被拒绝（−67050）。测试条目删除成功，复查 −25300。构建期签名授权已完成。此结论仅覆盖固定服务产物。T3.2 已在签名候选上复现。单独更新服务后，旧密钥读改返回 −25293，回滚原服务后可读回原值。旧宿主直接写入的条目同样无法免交互迁移。[XPC 实测报告](../.local-evidence/orca-run-0373dd1cd67c/s1-xpc/report.md) · [升级与回滚记录](../.local-evidence/orca-run-0373dd1cd67c/t3.2/report.md)

### Iteration 1：MVP 大白桌宠本体
| Ticket | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 门禁结果 | 备注 / 证据 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| T1.1 | `PetStateMachine` 核心状态机 | `DEV-L` (`SOL ultra`) | `DONE` | 0 | AC-1.1 PASS | 7 项冻结契约和 14 项行为测试通过，契约哈希核对一致。T1.5 将串行执行副作用、取消旧动作并过滤过期异步回调。[状态机报告](../.local-evidence/orca-run-0373dd1cd67c/t1.1/report.md) |
| T1.2 | `MotionEngine`（可种子化 RNG）+ `ScreenGeometry` | `DEV-H` | `DONE` | 1 | 运动与几何组件复核 PASS | ORCH 重编原夹具，180 pt 与 40 pt 分别旋转 −351.63°、−78.14°，均为 1.95349°/pt。7 项定向测试通过，含 144 条轨迹、38,160 个包络采样时刻；三组 S3 离线回放终点一致。正式绘图的贴边表现随集成复核。[修复报告](../.local-evidence/orca-run-0373dd1cd67c/t1.2-radius/report.md) · [ORCH 复测](../.local-evidence/orca-run-0373dd1cd67c/t1.2-radius/orch-accept.log) |
| T1.3 | `DesignTokens`/`BaymaxGeometry` + `BaymaxLayerView` + `--snapshot` | `UIUX` → `DEV-H` → `UIUX` | `DONE` | 0 | AC-1.4 PASS，44/44 格视觉签收 | Neon 检查了 11 种姿态、两档缩放与黑白背景，0 个阻塞项。ORCH 复现相同 PNG，1,596 帧滚动光栅检查通过。正式基线 SHA-256 为 `04389288311635b729dd78f391a7b08fbea4345a53e9d925aea46eeb4ff169ef`。[基线 PNG](visual-baselines/T1.3-contact-sheet.png) · [签收报告](visual-baselines/T1.3-signoff.md) · [渲染与接线](../.local-evidence/orca-run-0373dd1cd67c/t1.3-render/report.md) |
| T1.4a | `PetFloatingPanel` + `ignoresMouseEvents` 动态穿透 | `DEV-H` (`codex 6.2 astra high`) | `DONE` | 0 | 构建和 15 项浮窗检查 PASS | 内置屏夹具确认显示时前台应用保持焦点，命中、穿透切换、拖动捕获和资源释放通过。成品跨应用点击、真实拖拽及 Spaces 体验随 G1 验收。[浮窗报告](../.local-evidence/orca-run-0373dd1cd67c/t1.4a/report.md) |
| T1.4b | AppKit 拖拽、戳肚皮与右键菜单 | `DEV-H` | `DONE` | 0 | 20 项原手势回归通过，边缘收件专项通过 | 浮窗与输入层共用命中判定。鼠标由外进入须命中身体；离开身体时 2 pt 带内仍响应，再向外恢复穿透。ORCH 重编受控夹具，0 个错误。跨应用实际手感留给 G1。[边缘修复](../.local-evidence/orca-run-0373dd1cd67c/t1.5-fringe/dev/report.md) · [ORCH 复跑](../.local-evidence/orca-run-0373dd1cd67c/g1.j5ruTO/fringe.log) |
| T1.4c | 宽窗滚动联动与内置屏 `visibleFrame` 边界 | `DEV-H` | `DONE` | 0 | 亮屏原生补验 23/23，退出码 0 | ORCH 回放核对 8 次收窗观测及 2 个负对照。正常完成和取消后，身体内可接收鼠标，透明区、窗外均穿透。原 15/16 记录缺少指针位置，已校验原件哈希。成品造型和跨应用体验随 T1.5/G1 验收。[补验报告](../.local-evidence/orca-run-0373dd1cd67c/t1.4c-hit/report.md) · [初次亮屏实测](../.local-evidence/orca-run-0373dd1cd67c/t1.4c/natural-unlock/attempt-1.log) |
| T1.4d | 位置和偏好恢复、减弱动态效果、动画暂停 | `DEV-L` (`SOL ultra`) | `DONE` | 0 | App 目标编译及 9 项组件测试 PASS | 独立进程成功恢复窗口位置与偏好。可控通知验证遮挡、休眠、锁屏和低电量可叠加，全部解除后才允许恢复动画。T1.5 接入后实测成品重启位置与系统状态变化时的动画。[实测报告](../.local-evidence/orca-run-0373dd1cd67c/t1.4d/report.md) |
| T1.5 | `PetController`、正常启动与 `--smoke-test` | `DEV-H`（Astra high） | `DONE` | 0 | AC-1.3 通过，集成夹具与快照复核通过 | ORCH 在独立偏好域重跑。滚动中断后收窗并保存落点，重启恢复；正常入口的菜单夹具 0.0721 秒内退出，剩余窗口与同名进程均为 0。快照像素差 0。跨应用点击与拖动手感留给 G1。[集成报告](../.local-evidence/orca-run-0373dd1cd67c/t1.5/report.md) · [ORCH 退出记录](../.local-evidence/orca-run-0373dd1cd67c/t1.5/orch.FvYjLy/result/entry-menu/exit.json) |
| T1.6 | 菜单栏图标与单实例保护 | `DEV-L`（Sol ultra） | `DONE` | 0 | 菜单、重开与并发启动夹具 PASS | 三轮各四路启动，每轮仅一个实例保留浮窗。菜单退出至确认无窗口最长 0.1262 秒。快照像素差 0，设置面板随 T2.3c 实现。[菜单与实例验证](../.local-evidence/orca-run-0373dd1cd67c/t1.6/report.md) |
| **G1** | **Iteration 1 人工真机签收闸门** | 人类用户 | `DONE` | - | AC-1.6 内置屏人工 PASS；签名、43 项测试及 24 个扫描夹具通过 | 2026-11-26 用户按实操清单回覆「G1 正常」。ORCH 随后查询无同名进程。签名快照像素差 0，待机内存 15,270,728 B（上限 37,665,528 B），App CPU 均值 0.0%（按 top 精度，上限 0.8%）。[人工签收记录](../.local-evidence/orca-run-0373dd1cd67c/g1.j5ruTO/human-acceptance.md) · [正式门禁](../.local-evidence/orca-run-0373dd1cd67c/g1.j5ruTO/verify-gate.log) · [资源报告](../.local-evidence/orca-run-0373dd1cd67c/g1.j5ruTO/collect-sol-s4/report.md) |

### Iteration 2：轻互动陪伴 + 本地快反对话 + 完整 UI
| Ticket | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 门禁结果 | 备注 / 证据 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| T2.1a | `EmotionTagParser` + `ChatMessage` 成对截断 | `DEV-L`（Sol ultra） | `DONE` | 0 | AC-2.2 通过 | 跳过不完整问答轮次，未知标签原样保留。ORCH 复跑 10 项行为测试和 7 项冻结契约。[报告](../.local-evidence/orca-run-0373dd1cd67c/t2.1a/report.md) · [复核日志](../.local-evidence/orca-run-0373dd1cd67c/t2.1a/orch-tests.log) |
| T2.1b | `LocalReplyEngine` + 大白台词库 | `DEV-L` + `UIUX` | `DONE` | 0 | AC-2.1 引擎性能通过，成品回复与表情已随 G2 签收 | ORCH 核对四句台词和表情，复跑 13 项测试。release 五条路径共 2,560 个样本，合并 p99 为 0.003209 ms，最慢路径 p99 为 0.003750 ms（门槛 < 5 ms）。[引擎报告](../.local-evidence/orca-run-0373dd1cd67c/t2.1b/report.md) · [原始样本复算](../.local-evidence/orca-run-0373dd1cd67c/t2.1b/orch-verify.json) · [复跑日志](../.local-evidence/orca-run-0373dd1cd67c/t2.1b/orch-tests.log) |
| T2.2 | `HealthReminderScheduler` | `DEV-L`（Sol ultra） | `DONE` | 0 | ORCH 复跑 31 项定向测试通过 | 支持关闭、30/45/60 分钟；忙时最多留一条。锁屏、休眠或连续无活动满 5 分钟，恢复后重新计时。5 分钟为本轮实现选值。系统活动和气泡由 T2.4 接入。[实现报告](../.local-evidence/orca-run-0373dd1cd67c/t2.2/report.md) · [复核日志](../.local-evidence/orca-run-0373dd1cd67c/t2.2/orch-tests.log) |
| T2.3a | `ChatPanelController`（IME 与定位） | `DEV-H`（Astra high） | `DONE` | 0 | AC-2.3 通过，Neon 独立复核通过，AC-2.4 随 G2 人工签收 | 25 项 AppKit 检查通过，ORCH 复跑含几何的 24 项测试。按文档保留 Esc 关闭，真实输入法与草稿行为已列入 G2 整轮签收。Neon 的占位视图边距观察交 T2.3b，非有限矩形未见于当前实屏输入。[实窗报告](../.local-evidence/orca-run-0373dd1cd67c/t2.3a/report.md) · [复核日志](../.local-evidence/orca-run-0373dd1cd67c/t2.3a/orch-geometry-dialogue.log) |
| T2.3b | `ChatBubbleView` | `DEV-L`（Sol ultra） | `DONE` | 0 | 21 项实窗检查通过；ORCH 复跑 19 项测试通过 | 用 12 轮合成对话验证可滚回首轮、追加后可见最新一条。清空保留草稿、光标和焦点。双方气泡与 12 pt 边距已复核。[实窗报告与截图](../.local-evidence/orca-run-0373dd1cd67c/t2.3b/report.md) · [复跑日志](../.local-evidence/orca-run-0373dd1cd67c/t2.3b/orch-tests.log) |
| T2.3c | `SettingsWindowController` | `DEV-H`（Astra high） | `DONE` | 1 | 首次激活缺陷已修复，6 个独立设置场景及 23 项回归通过 | 原实现曾在内置屏亮屏时显示窗口但未取得焦点。修复后从菜单栏和桌宠右键均可直接在 Base URL 输入，无需再点窗口。ORCH 对照原始时间线确认首次获得前台与 key 为 207–216 ms；打开聊天仍由原应用持有前台。[复验报告](../.local-evidence/orca-run-0373dd1cd67c/t2.3c-focus/report.md) · [逐场景观测](../.local-evidence/orca-run-0373dd1cd67c/t2.3c-focus/observations.tsv) |
| T2.3d | `SettingsView` 表单 | `DEV-L`（Sol ultra） | `DONE` | 0 | 正常入口隔离夹具 34 项通过，ORCH 复跑 21 项测试通过 | 静音与菜单同步，缩放即时更新绘制及命中，偏好跨进程恢复。密钥保存与连接测试待 T3.2。两条入口的首次激活已通过 T2.3c 复验。[报告与截图](../.local-evidence/orca-run-0373dd1cd67c/t2.3d/report.md) · [ORCH 复跑](../.local-evidence/orca-run-0373dd1cd67c/t2.3d/orch-project-tests.log) |
| T2.4 | 本地快反 + 健康扫描联调接入 `PetController` | `DEV-H`（Astra high） | `DONE` | 0 | 23 项正式入口、26 项计时、25 项聊天、10 项敲键回归与 47 项项目测试通过 | 三句各产生一轮问答、对应表情与短气泡，清空后旧回调未重发。主动健康扫描可在定时提醒关闭时使用，忙时提醒合并为一条。[联调报告](../.local-evidence/orca-run-0373dd1cd67c/t2.4/report.md) · [入口记录](../.local-evidence/orca-run-0373dd1cd67c/t2.4/verified-entry/raw.log) |
| T2.5 | 敲键陪伴（`counterForEventType` 轮询） | `DEV-H`（Astra high） | `DONE` | 0 | AC-2.5 隐私门禁通过 | 默认关闭。开启且桌宠可见、空闲、可动时，每秒只读按键总次数。35 项检查通过，ORCH 独立复跑其中 15 项启停断言、24 项项目回归和 24 个扫描夹具。真人节拍已随 G2 签收，App 待机资源达标。[隐私与实测报告](../.local-evidence/orca-run-0373dd1cd67c/t2.5/report.md) · [启停复跑](../.local-evidence/orca-run-0373dd1cd67c/t2.5/orch.EDF4TL/monitor.log) · [扫描结果](../.local-evidence/orca-run-0373dd1cd67c/t2.5/orch-gate-scan.log) |
| **G2** | **Iteration 2 人工真机签收闸门** | 人类用户 | `DONE` | - | 内置屏人工签收通过，工程门禁通过 | 用户回复「G2 正常」。72 项测试、24 个扫描夹具、严格签名与自检通过，快照零像素差。待机内存 16,532,392 B，30 帧 App CPU 均值/P95 均为 0.0%（top 精度）。外接屏与 WindowServer 增量延期。[人工签收](../.local-evidence/orca-run-0373dd1cd67c/g2.W5pRBT/human-acceptance.md) · [门禁日志](../.local-evidence/orca-run-0373dd1cd67c/g2.W5pRBT/verify-gate.log) · [资源与签名](../.local-evidence/orca-run-0373dd1cd67c/g2.W5pRBT/collect-sol-s4/report.md) |

### Iteration 3：标准 BYOK 大模型 API + 按需原生语音
| Ticket | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 门禁结果 | 备注 / 证据 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| S5 | macOS 26 中文端侧语音识别主备路径探针 | `DEV-H`（Astra high） | `DONE`（人工签收） | 0 | 本机文件转写两路均通过，用户回复「s5 验收」 | ORCH 独立复跑，规范化后的中文均逐字匹配。主选 SpeechAnalyzer，备选强制端侧 SFSpeechRecognizer。缺资产设备的实际下载与真人麦克风留待验证。[探针报告](../.local-evidence/orca-run-0373dd1cd67c/s5/report.md) · [签收记录](../.local-evidence/orca-run-0373dd1cd67c/s5/acceptance.md) |
| T3.1 | 非流式 OpenAI 兼容与 Anthropic 客户端 | `DEV-H`（Astra high） | `DONE` | 0 | AC-3.1 四厂商 Mock 通过；ORCH 复跑 24 项定向测试通过 | 本机持续传输时调用方在 20.004 秒超时，服务端在 20.098 秒观察到断开。真实端点与正式对话收尾待 G3 联调。[测试与回环报告](../.local-evidence/orca-run-0373dd1cd67c/t3.1/report.md) · [ORCH 复跑](../.local-evidence/orca-run-0373dd1cd67c/t3.1/orch-tests.log) |
| T3.2 | `KeychainStore` 与设置页「测试连接」 | `DEV-H`（Astra high） | `DONE`（实现） | 0 | ORCH 复跑 80 项测试通过。AC-3.2 全范围扫描待验（`ENV`） | 正式设置按端点隔离密钥，签名候选在 5 个进程中完成建、读、改、复读、清理。复用固定服务时重编宿主也能免交互读回。真实用户端点留至 G3。[实现及恢复验证](../.local-evidence/orca-run-0373dd1cd67c/t3.2/report.md) · [ORCH 测试](../.local-evidence/orca-run-0373dd1cd67c/t3.2/orch-swift-tests.log) |
| T3.3a | 麦克风与语音识别授权顺序及中文错误提示 | `DEV-H`（Astra high） | `DONE` | 0 | 29 项授权检查、10 项窗口检查、80 项项目测试通过 | 窗口夹具用受控会话核实先授权、停 TTS、再启动录音的顺序。拒权后保留文字草稿，关闭或隐藏后迟到回调无法开麦。真人授权及物理录音待 G3。[报告](../.local-evidence/orca-run-0373dd1cd67c/t3.3a/report.md) · [窗口记录](../.local-evidence/orca-run-0373dd1cd67c/t3.3a/window.log) |
| T3.3b | 按需开麦与中文端侧实时转写 | `DEV-H`（Astra high） | `DONE`（实现、独立复核） | 0 | 6 组原生框架文件流、44 项生命周期、6 项缓冲区、80 项项目测试通过。Neon 复核通过，0 个阻断项 | T3.4 已验证准备阶段取消、识别收尾按钮禁用及倾听光环三项修正。Sol 改进的停麦采样工具通过 9 组合成对照及原有 5 组回归。物理开麦、一秒释放和橙灯仍待 G3。[实测报告](../.local-evidence/orca-run-0373dd1cd67c/t3.3b/report.md) · [交互修正记录](../.local-evidence/orca-run-0373dd1cd67c/t3.4/neon-window.log) · [采样工具验证](../.local-evidence/orca-run-0373dd1cd67c/t3.3b-meter/report.md) |
| T3.3c | `SpeechOutputService` 中文播报、静音与识别互斥 | `DEV-L`（Sol ultra） | `DONE` | 0 | 39 项隔离检查、4 项原生合成检查、23 项 G2 实窗回归通过；ORCH 复跑 41 项 Swift 测试通过 | 已接入即时静音、停止与取消；进入 listening 时同步停播后才交给开麦方。该项使用模拟麦克风；真实硬件释放、橙灯与真人听感待 T3.3b/G3。[实测与接线](../.local-evidence/orca-run-0373dd1cd67c/t3.3c/report.md) · [ORCH 复跑](../.local-evidence/orca-run-0373dd1cd67c/t3.3c/orch-tests.log) |
| T3.4 | 语音/文字 ↔ BYOK API ↔ 情绪 ↔ TTS 端到端联调 | `DEV-H`（Astra high） | `DONE`（工程续验） | 0 | 43 项对话、44 项语音生命周期、15 项窗口与图层断言、23 项亮屏窗口回归及 80 项工程测试通过 | 新签名见证通过真实 Keychain 完成 5 次鉴权回环，清理后复查为空。合成中文播报 4.552 秒自然结束，20.011 秒超时后可立即重试。ORCH 复核最终候选、见证和 XPC 签名；原见证的封印错误及恢复过程已归档。[续验报告](../.local-evidence/orca-run-0373dd1cd67c/t3.4/report-after-unlock.md) · [ORCH 复核](../.local-evidence/orca-run-0373dd1cd67c/g3.4GDUOK/t3.4-verification.log) |
| **G3** | **Iteration 3 人工真机签收闸门** | 人类用户 | 真人体验已确认，硬指标部分待实测 | - | 首版正式门禁退出 0，80 项测试，自检及快照比对通过（差 0 像素）。30 帧待机 App CPU 均值/P95 在 top 精度下均为 0.0%，物理内存 14,451,504 B | 正常入口已核实。待机设备读数为麦克风 0/1 活跃、摄像头 0/2 活跃。用户已确认服务连接、连续语音体验和正常停麦；持续语音发布包的 82 项测试及收尾边界见本页下方。[正式门禁](../.local-evidence/orca-run-0373dd1cd67c/g3.4GDUOK/verify-gate.log) · [待机与扫描](../.local-evidence/orca-run-0373dd1cd67c/g3.4GDUOK/collect-sol-s4/report.md) · [真人验收记录](../.local-evidence/orca-run-0373dd1cd67c/g3.4GDUOK/human-acceptance.md) |

AC-3.2 的首次扫描读到 453,188 个文件与两个进程的 352 行日志，测试密钥零命中。23 处未能访问，扫描退出 1。ORCH 随后以现有权限单独复查，打开 6 个偏好文件和枚举 17 个目录（缓存 7、Application Support 10）时均收到 `EPERM`，临时目录未遇到拒绝。原始扫描仅记录各范围的计数，两次无法逐路径对应。全范围结论须在既定范围均可读的 macOS 测试环境复验。[首次扫描](../.local-evidence/orca-run-0373dd1cd67c/t3.2/canary/canary.json) · [独立访问复查](../.local-evidence/orca-run-0373dd1cd67c/t3.2/orch-access-inventory.json)

G3 正式包的五个跨进程钥匙串阶段均通过。正式扫描在 453,543 个文件和两个进程的 355 行日志中零命中；偏好、缓存与 Application Support 分别有 6、7、10 处不可读，退出 1。[正式扫描回执](../.local-evidence/orca-run-0373dd1cd67c/g3.4GDUOK/collect-sol-s4/canary/canary.json)

### G3 已发布基线 · 单点大白肚子开始一轮对话

用户已选定肚子上的麦克风图标。大白待机时释放麦克风，用户轻点一次即可说话，全程可关闭文字聊天窗。每次点击开始一轮；收音中再点可提前结束。沿用端侧转写、当前配置的回复服务、中文播报和已保存的静音偏好。

| 票 | 负责人 | 进度 |
| --- | --- | --- |
| T3.5a 肚子控件、三档缩放与手势分流 | DEV-L · Sol | 已完成。42 项实窗检查、28 项定向测试通过。ORCH 核对待机与收音截图、后台首击与拖拽回执。[控件实测](../.local-evidence/orca-run-0373dd1cd67c/g3-belly/control/report.md) |
| T3.5b 无聊天窗的一轮语音与异常恢复 | DEV-H · Astra | 工程验证通过。合成中文语音经端侧转写、实际 HTTP 回环及约 4.29 秒的中文播报完成一轮，始终没有打开聊天窗。ORCH 核对当前两份集成源码摘要、入口状态、14 次请求与 80 项工程测试回执。[无窗对话实测](../.local-evidence/orca-run-0373dd1cd67c/g3-belly/flow/report.md) |
| T3.5c 视觉与交互独立复核 | UIUX · Neon | 独立复核通过，0 个阻断项。已更新交互规格，9 张实窗截图覆盖三档缩放及无窗对话。[复核报告](../.local-evidence/orca-run-0373dd1cd67c/g3-belly/review/report.md) |

G3 补验正式包已发布到 `dist/DabaiPet.app`。门禁退出 0，80 项测试通过，宿主 CDHash 为 `ef695eb63b4c5a348d666867ddbf895e227769ea`，自检通过、冻结美术快照差 0 像素。[成品核验](../.local-evidence/orca-run-0373dd1cd67c/g3-belly/stage/collect/report.md)

用户同意切换后，旧 PID 91418 已正常退出。新版是唯一的正常实例（PID 43718），映射发布宿主 inode 40609488，内置屏浮窗可见。有效待机样本的 30 帧 App CPU 均值和 P95 在 `top` 显示精度下均为 0.0%，物理内存 15,139,728 B，比空壳增加 2,474,200 B，两项均达标。采样前后麦克风及摄像头均空闲。真人点肚子后通过已配置服务收到回答、听到中文播报、停麦后橙点在一秒内熄灭仍待签收。[运行与待机报告](../.local-evidence/orca-run-0373dd1cd67c/g3-belly/stage/collect/report-after-switch.md)

切换后，第一次设备复查见内置麦克风处于活动状态，来源待定。稍后连续约 3 秒的 7 次查询均显示内置麦克风空闲，随后全设备快照也显示 1 个麦克风、2 个摄像头全部空闲。这些是当前待机观察；一次真人录音结束后的释放耗时和橙点仍待成对测量。[定时只读观测](../.local-evidence/orca-run-0373dd1cd67c/g3-belly/stage/collect/orch-audio-state.ndjson) · [全设备状态](../.local-evidence/orca-run-0373dd1cd67c/g3-belly/stage/collect/orch-hardware-after.json)

### G3 已发布 · 连续语音对话

用户要求轻点一次肚子后可一直聊。每次答完，大白自动接听下一句；停顿不会结束会话。用户可以在倾听时独立说「拜拜」，或在任一对话阶段点肚子的停止键。结束后恢复待机，麦克风关闭。上方单轮签名版是已发布基线。

2026-11-27，切换到持续对话签名版后，用户反馈「测试可以」，随后确认「测试过麦克风可以正常关闭」。这两项记为真人体验通过。该反馈未区分两种终止方式，也未计时。AC-3.3 的一秒硬件释放与橙灯时延没有现场配对记录，断网恢复已有回环自动化证据，尚无真实服务断网的现场回执。AC-3.2 可读范围内测试密钥零命中，23 个受保护项目不可读。

收尾时复测了用户试用过的签名包。有效待机样本共 30 帧，App CPU 均值与 P95 在 `top` 的显示精度下均为 0.0%，物理内存 15,745,912 字节。采样前后麦克风与摄像头均空闲。[资源回执](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/stage/collect/standby-g7dogp9p/summary.json)

| 票 | 固定窗口 | 进度 |
| --- | --- | --- |
| T3.6a 停止控件与本地告别语 | Sol ultra | 51 项实窗检查、33 项定向测试通过，含告别语 12 个正例和 25 个反例。[控件与判定回执](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/controls/report.md) |
| T3.6a 补验：按住停止键时切换语音阶段 | Sol ultra | 已修复。修前实窗复现点击丢失，修后 21 项断言通过。同一会话内按住时阶段变化仍只终止一次，旧松手不会重新开麦。[实窗补验](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/stop-transition/report.md) |
| T3.6b 连续问答、历史及结束后的清理 | Astra high | 正常路径已完成。一次点按，两问两答，两次轮前各静默 32 秒，首轮连续发言 34.54 秒；端侧识别最终告别后未再次采集。回环服务收到 2 次请求，82 项仓库测试通过。[实测与复跑](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/flow/report.md) |
| T3.6b 补验：没听清一句后继续对话 | Astra high | 修复版实窗异常矩阵 71 项通过。仅临时听到「拜拜」时仍可重说，异常测试的回环只收到随后确认的 1 次普通发言。修复版另完成原生两轮问答、82 项仓库测试，ORCH 核对 10 份源码摘要一致。[修复与复跑回执](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/uncertain-turn/report.md) |
| T3.6c 独立交互复核 | Neon | 控件、两轮问答、主动停止等正常路径复核通过。原报告关于未确认转写的表述须结合下行补验，基线在收尾超时时会意外结束。[独立复核](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/review/report.md) |
| T3.6c 修复版复核 | Neon | 独立复核通过，0 个阻断项。两份源码清单各 10 项一致，核对 5 个变更文件、71 项异常矩阵与修复版两问两答；实际提示与交互规格一致。[修复版独立复核](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/review/uncertain-turn.md) |
| G3 多轮现场停麦采样 | Sol ultra | 工具已交付。18 组对照和一次终端操作回放通过，能区分轮间正常续听、最后释放超时及结束后额外开麦；连续版的物理麦克风与橙灯仍待现场验证。[采样入口与回执](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/meter/report.md) |
| G3 持续对话正式包与运行交接 | ORCH · Sol ultra | 持续对话版已发布到 `dist/DabaiPet.app`。24 个静态夹具与两轮各 82 项测试通过，发布门禁退出 0。10 份评审源码摘要、宿主和凭据服务签名、自检均通过，冻结快照相差 0 像素。经用户确认，旧单轮实例已正常退出。新版以唯一实例 PID 89833 启动，映射签名成品，内置屏浮窗可见。用户试用反馈见本节上方记录。[发布包续验](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/stage/collect/report-after-publish.md) · [桌面切换回执](../.local-evidence/orca-run-0373dd1cd67c/g3-continuous/stage/collect/switch-orch.json) |

### Iteration 1–3 收尾审查

Neon 独立审查了桌宠、语音停止和窗口生命周期。收尾修复了四个交互问题。同一服务地址下切换模型会保留尚未保存的密钥，切换服务地址或供应商会清空草稿。关闭设置窗会取消正在进行的连接测试并清空草稿。桌宠右键菜单可以切换播报静音，与菜单栏和设置同步。切换明暗外观后，空闲桌宠会更新绘制，切回原外观可还原到相同像素。

在已解锁的内置屏上，设置回归的 14 项检查及连接表单的 21 项检查通过。两套检查均使用测试凭据。连续语音的 40 项交互检查与 71 项未确认转写检查通过。打包门禁现会复核指定输出目录内的宿主和凭据服务签名。金丝雀写入后即使回执超时，验收脚本仍会尝试清理本轮创建的测试条目。设置回归可在仓库根目录通过 `zsh Spikes/SettingsRegression/run.zsh` 复跑。

最终发布包由 `scripts/verify_gate.sh` 生成，24 个静态夹具、1 项脚本回归和两轮各 82 项 Swift 测试通过。独立导出的干净源码也通过了 15 个套件的全部 82 项测试。正式包验签及自检通过，启动时麦克风和摄像头会话均为空。3808 × 5780 快照与仓库基线相差 0 像素。[本机门禁回执](../.local-evidence/orca-run-0373dd1cd67c/closeout/verified.ep1aCe/gate.log) · [快照比对](../.local-evidence/orca-run-0373dd1cd67c/closeout/verified.ep1aCe/snapshot.png.diff.json)

### Iteration 4（二期扩展，已暂缓）：摄像头手势石头剪刀布

2026-11-27 用户决定暂缓 S6、T4.1–T4.3 和 G4。前文 S4 指桌宠性能探针。

| Ticket | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 门禁结果 | 备注 / 证据 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| S6 | 【前置 Spike】录制 ~200 帧真实手部关键点 JSON 夹具 | `DEV-H` (`codex 6.2 astra high`) | 暂缓 | 0 | 暂缓 | 依赖 T1.6 |
| T4.1 | `HandGestureClassifier`（关节角 + 滞回 + “出！”后采样 + 预锁定） | `ORCH` 规格 → `DEV-L` | 暂缓 | 0 | - | 依赖 T0.3, S6 |
| T4.2 | `CameraRPSService`（串行队列 + Vision + CoreMediaIO 检查） | `DEV-H` (`codex 6.2 astra high`) | 暂缓 | 0 | - | 依赖 T4.1 |
| T4.3 | `RPSOverlayView` + 3-2-1 摇臂 + 矢量出拳 + 回放模式 | `UIUX` (`Neon`) → `DEV-H` | 暂缓 | 0 | - | 依赖 T1.3, T4.2 |
| **G4** | **Iteration 4 人工真机签收闸门** | 人类用户 | 暂缓 | - | - | 真机 5 局 + 绿灯熄灭 |
