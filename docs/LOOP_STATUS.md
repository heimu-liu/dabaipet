# DabaiPet 循环开发运行态看板（LOOP_STATUS）

> 由 **`ORCH`（`codex 6.2 astra xhigh`）** 实时维护。每完成一次派发、门禁校验、升级切换或人工签收均须更新本表。

- **Current Phase**：Iteration 0.5（真机探针）
- **Next Action**：Iteration 0 已由用户签收，S1–S4 已派发 DEV-H。
- **Escalation Policy**：`IMPL` 失败累计：尝试 #1（主责）→ #2（`codex 6.2 astra high`）→ #3（`Agy · Neon`）→ #4（`Agy · Claude Opus 5.5`）→ `BLOCKED`（人工审核）；`ENV`/`SPEC` 失败不计数
- **Test Count Baseline**：`8`（7 项冻结契约测试 + 1 项工程测试）

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
| S1 | 自签名跨重建 TCC/Keychain + `counterForEventType` 权限 | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | `PENDING` | - |
| S2 | 透明 `ignoresMouseEvents` 穿透 + 拖拽 + `ChatPanel` 中文 IME | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | `PENDING` | - |
| S3 | 宽窗画布内滚动（单屏/多屏负坐标/`visibleFrame`） | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | `PENDING` | - |
| S4 | 性能基线标定（空壳 / Canvas 30FPS / CALayer 呼吸） | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | `PENDING` | 产出红线标定值 |

### Iteration 1：MVP 大白桌宠本体
| Ticket | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 门禁结果 | 备注 / 证据 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| T1.1 | `PetStateMachine` 核心状态机 | `DEV-L` (`SOL ultra`) | `TODO` | 0 | - | 依赖 T0.3 |
| T1.2 | `MotionEngine`（可种子化 RNG）+ `ScreenGeometry` | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T0.3, S3 |
| T1.3 | `DesignTokens`/`BaymaxGeometry` + `BaymaxLayerView` + `--snapshot` | `UIUX` (`Neon`) → `DEV-H` | `TODO` | 0 | - | 依赖 T0.3, S4 |
| T1.4a | `PetFloatingPanel` + `ignoresMouseEvents` 动态穿透 | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T0.3, S2 |
| T1.4b | AppKit 拖拽 / 戳肚皮阈值 / 右键菜单 | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T1.4a |
| T1.4c | 宽窗滚动联动 + 多屏 `visibleFrame` + 热插拔 | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T1.2, T1.4a |
| T1.4d | 持久化 + 减弱动态效果 + 遮挡/休眠暂停 | `DEV-L` (`SOL ultra`) | `TODO` | 0 | - | 依赖 T1.4a |
| T1.5 | `PetController` 协调脊柱 + `--smoke-test` | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T1.1, T1.3, T1.4b–d |
| T1.6 | Menu Bar Extra + 单实例保护 | `DEV-L` (`SOL ultra`) | `TODO` | 0 | - | 依赖 T1.5 |
| **G1** | **Iteration 1 人工真机签收闸门** | 人类用户 | `PENDING` | - | - | 30 秒实测清单 |

### Iteration 2：轻互动陪伴 + 本地快反对话 + 完整 UI
| Ticket | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 门禁结果 | 备注 / 证据 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| T2.1a | `EmotionTagParser` + `ChatMessage` 成对截断 | `DEV-L` (`SOL ultra`) | `TODO` | 0 | - | 依赖 T0.3 |
| T2.1b | `LocalReplyEngine` + 大白台词库 | `DEV-L` + `UIUX` | `TODO` | 0 | - | 依赖 T2.1a |
| T2.2 | `HealthReminderScheduler` | `DEV-L` (`SOL ultra`) | `TODO` | 0 | - | 依赖 T0.3 |
| T2.3a | `ChatPanelController`（IME + 四角定位） | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T1.2, T1.5, S2 |
| T2.3b | `ChatBubbleView` | `DEV-L` (`SOL ultra`) | `TODO` | 0 | - | 依赖 T2.1a, T2.3a |
| T2.3c | `SettingsWindowController` | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T1.6 |
| T2.3d | `SettingsView` 表单 | `DEV-L` (`SOL ultra`) | `TODO` | 0 | - | 依赖 T2.3c |
| T2.4 | 本地快反 + 健康扫描联调接入 `PetController` | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T2.1b, T2.2, T2.3b/d |
| T2.5 | 敲键陪伴（`counterForEventType` 轮询） | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T1.5, T2.3d, S1 |
| **G2** | **Iteration 2 人工真机签收闸门** | 人类用户 | `PENDING` | - | - | 含拼音 IME 实测 |

### Iteration 3：标准 BYOK 大模型 API + 按需原生语音
| Ticket | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 门禁结果 | 备注 / 证据 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| S5 | 【前置 Spike】macOS 26 `SpeechAnalyzer` zh-CN vs `SFSpeechRecognizer` | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | `PENDING` | 依赖 T1.6 |
| T3.1 | 非流式 OpenAI 兼容 + Anthropic 客户端 + Mock 单测 | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T2.1a |
| T3.2 | `KeychainStore` + 设置页「测试连接」 | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T2.3d, T3.1, S1 |
| T3.3a | 麦克风 + 语音双授权编排 & 错误码映射 | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 S5 |
| T3.3b | 按需 STT 管线（`nonisolated @Sendable` tap） | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T3.3a |
| T3.3c | `AVSpeechSynthesizer` TTS + 静音与互斥 | `DEV-L` (`SOL ultra`) | `TODO` | 0 | - | 依赖 T1.5 |
| T3.4 | 语音/文字 ↔ BYOK API ↔ 情绪 ↔ TTS 端到端联调 | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T3.2, T3.3b/c, T2.4 |
| **G3** | **Iteration 3 人工真机签收闸门** | 人类用户 | `PENDING` | - | - | 含金丝雀与橙灯验证 |

### Iteration 4（二期扩展）：摄像头手势石头剪刀布
| Ticket | 名称 | 主责角色 | 状态 | IMPL 失败次数 | 门禁结果 | 备注 / 证据 |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- |
| S6 | 【前置 Spike】录制 ~200 帧真实手部关键点 JSON 夹具 | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | `PENDING` | 依赖 T1.6 |
| T4.1 | `HandGestureClassifier`（关节角 + 滞回 + “出！”后采样 + 预锁定） | `ORCH` 规格 → `DEV-L` | `TODO` | 0 | - | 依赖 T0.3, S6 |
| T4.2 | `CameraRPSService`（串行队列 + Vision + CoreMediaIO 检查） | `DEV-H` (`codex 6.2 astra high`) | `TODO` | 0 | - | 依赖 T4.1 |
| T4.3 | `RPSOverlayView` + 3-2-1 摇臂 + 矢量出拳 + 回放模式 | `UIUX` (`Neon`) → `DEV-H` | `TODO` | 0 | - | 依赖 T1.3, T4.2 |
| **G4** | **Iteration 4 人工真机签收闸门** | 人类用户 | `PENDING` | - | - | 真机 5 局 + 绿灯熄灭 |
