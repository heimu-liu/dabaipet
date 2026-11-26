# DabaiPet 多模型循环开发编排与验收标准（LOOP_ORCHESTRATION_AND_ACCEPTANCE v2）

> 本文档定义多模型闭环开发协议、按阶段可行性探针（Spike）、四级异构升级熔断规则、完整 Task DAG 与三段式验收门禁。角色代号与具体模型的唯一映射表见 [README.md](../README.md)。

---

## 1. 角色分工与四级异构升级熔断规则（已拍板）

### 1.1 角色边界（裁判与运动员分离）
- **`ORCH`（`codex 6.2 astra xhigh`）**：负责派发任务、冻结契约与锁定验收测试（`T0.3`）、编写与维护门禁脚本（`T0.2b`）、审查 Diff、裁决 AC、更新 `docs/LOOP_STATUS.md`。**不直接大段写业务代码**。
- **`DEV-H`（`codex 6.2 astra high`）**：负责所有 Spike 探针、AppKit 窗口/事件/IME、App 协调脊柱 `PetController`、Swift 6 并发与音视频管线、BYOK LLM 与 Keychain。
- **`DEV-L`（`SOL ultra`）**：负责边界清晰、契约已冻结的纯逻辑/脚手架/纯视图/TTS/单测任务。
- **`UIUX`（`Agy · Neon`）**：负责 `DesignTokens.swift`、`BaymaxGeometry.swift`、`UI_UX_SPEC.md` 及离屏联系表视觉走查。
- **`RESCUE-1`（`Agy · Neon`）** & **`RESCUE-2`（`Agy · Claude Opus 5.5`）**：异构排障与高难任务救援。

### 1.2 失败先分类，再触发升级（避免环境问题白烧额度）
每次门禁或 AC 不通过时，`ORCH` 必须先归类失败原因：
1. **`ENV`（环境/权限/人工前置未就绪）**：如缺少 `DabaiPet Local Dev` 证书、系统未授权 TCC、无麦克风硬件 → **不计入失败次数**，立即暂停并告知人类用户处理。
2. **`SPEC`（规范缺失或 AC 自相矛盾）**：→ **不计入失败次数**，退回 `ORCH` / `UIUX` 修订契约或 AC 后重派。
3. **`IMPL`（实现代码缺陷）**：→ 计入单 Ticket 失败次数，严格按以下 **4 次熔断阶梯**流转：

| 累计 `IMPL` 失败次数 | 下一步执行者 | 交接要求 |
| :---: | :--- | :--- |
| **第 0 次（首次实现）** | Ticket 默认主责模型（`DEV-L` 或 `DEV-H`） | 提供完整任务单：目标文件、契约片段、逐条 AC |
| **第 1 次失败 → 尝试 #2** | 若原为 `DEV-L`（`SOL ultra`）则升级 **`DEV-H`（`codex 6.2 astra high`）**；若原为 `DEV-H` 则由 **`DEV-H`** 带缺陷单二次修复 | 必须附精确失败 AC 编号、门禁日志、文件行号 |
| **第 2 次失败 → 尝试 #3** | 异构切换 → **`RESCUE-1`（`Agy · Neon`）** 做 1 次修复 | 附前 2 次失败根因与已排除路径，禁止重复原思路 |
| **第 3 次失败 → 尝试 #4** | 强异构切换 → **`RESCUE-2`（`Agy · Claude Opus 5.5`）** 做 1 次最终修复 | 附前 3 次完整诊断上下文与 Diff 摘要 |
| **第 4 次仍失败** | **熔断 `BLOCKED`，等待人工审核** | 停止自动化循环，输出《阻塞诊断报告》交由人类拍板 |

> **同源盲点防护**：由于 `ORCH` 与 `DEV-H` 同属 `codex 6.2 astra` 家族，对核心高风险 Ticket（`T1.4a/b/c`、`T1.5`、`T2.3a`、`T3.3b`）在进入人工签收前，建议由 `UIUX`（`Neon`）或 `RESCUE-2`（`Opus 5.5`）做一次轻量化异构 Diff/截图复核。

---

## 2. 三段式验收门禁体系

### 第一段：自动化硬门禁（`scripts/verify_gate.sh`，由 `ORCH` 编写，退出码判定）
每次提交必须全部返回 `0`（不消耗推理档位）：
1. **分模块编译**：`swift build --target DabaiPetCore`（warnings-as-errors）+ `swift build`。
2. **Swift Testing 单测与防偷懒保护**：
   - 运行 `swift test`，解析通过用例总数，要求**只增不减**（对比基线文件 `.gate_test_baseline`）；
   - 扫描并拦截 `import XCTest`、`.disabled`、`withKnownIssue`、无意义 `#expect(true)`；
   - 校验 `Tests/AcceptanceTests/` 在本次 DEV Diff 中**零改动**（锁定验收测试保护）。
3. **App 打包与签名 DR 校验**：
   - 执行 `./scripts/build_app.sh`；
   - `codesign --verify --deep --strict dist/DabaiPet.app`；
   - `codesign -d -r- dist/DabaiPet.app` 确认 Designated Requirement 指向 `DabaiPet Local Dev`（非退回 ad-hoc）；
   - `plutil -lint` + 逐键校验 `CFBundleIdentifier`、`LSUIElement`、`LSMinimumSystemVersion` 及 TCC 权限文案。
4. **精准安全与架构静态扫描（自带“正反样本自测夹具”）**：
   - `DabaiPetCore` 严禁：`^\s*(@\w+\s+)*import\s+(\w+\s+)?(AppKit|Cocoa|SwiftUI|Carbon|AVFoundation|Speech|Vision|CoreMediaIO)\b`；
   - 严禁读取 `~/.codex` / `~/.claude` 或通过 `Process()` / `executableURL` / `/bin/sh` 调用 `codex` / `claude` CLI（**避免误报 `claude-haiku-4-5` 等模型名**）；
   - 严禁硬编码真实密钥：`\bsk-(ant-)?[A-Za-z0-9_\-]{20,}`（排除测试夹具固定白名单前缀，避免误报 `task-`/`disk-`）；
   - 严禁在 `TypingCompanionMonitor` 中使用 `NSEvent` 键盘内容读取（仅允许 `CGEventSource.counterForEventType`）；
   - 并发逃生门计数：`@unchecked Sendable`、`nonisolated(unsafe)`、`@preconcurrency`、`.swiftLanguageMode(.v5)` 新增需 `ORCH` 明文批准。

### 第二段：可重复运行证据（`scripts/evidence.sh`，产出结构化产物）
- `--smoke-test`：`open -W -n dist/DabaiPet.app --args --smoke-test --out /tmp/dabai_smoke.json`，自检 `activationPolicy == .accessory`、窗口属性（`isOpaque/level/collectionBehavior/hasShadow`）、初始状态 `idle`、麦克风/摄像头会话 `nil`，写 JSON 并以退出码返回。
- `--snapshot`：离屏渲染全姿态 × 黑白背景 × `1.0x/1.25x` 联系表 PNG，产出像素差报告供 `UIUX` 审核。
- **资源采集**：`/usr/bin/footprint -p <PID>`（`phys_footprint`）+ `top -l 31 -s 1`（丢弃第 1 帧）+ WindowServer CPU 增量。
- **硬件释放脚本化检测**：CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`（麦克风）、CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere`（摄像头）。
- **金丝雀密钥防泄漏扫描**：注入临时 `sk-CANARY-<rand>` 走完保存/读取后，扫描 `~/Library/Preferences`、`Caches`、`Application Support`、`/tmp` 及 `log show --last 10m --predicate 'process == "DabaiPet"'`，全部零命中。

### 第三段：人工签收闸门（每个 Iteration / Spike 末一次）
仅保留机器无法判定的真机手感项（穿透手感、拖拽丝滑度、中文拼音 IME、TCC 弹窗时机、多屏视觉、真人对局），每项附 **30 秒操作步骤 + 预期结果**。**未完成人工签收，不得进入下一 Iteration。**

---

## 3. 全量迭代任务看板（Task DAG）与验收标准

### Iteration 0：工程基建、门禁与契约冻结

| Ticket | 任务名称 | 主责 | 依赖 | 核心交付物 |
| :--- | :--- | :---: | :---: | :--- |
| **T0.1** | SwiftPM 4-Target 骨架 + Swift Testing 入口 | `DEV-L` | 无 | `Package.swift`（Swift 6 / `.macOS(.v26)` / 4 targets / 无 resources）、单一 `main.swift`、首个 `@Test` |
| **T0.2a** | 完整 `Info.plist` + 自签名 `scripts/build_app.sh` | `DEV-L` | `T0.1` | `Resources/Info.plist`、`scripts/build_app.sh`（默认签 `DabaiPet Local Dev`） |
| **T0.2b** | 自动化硬门禁 `verify_gate.sh`（含自测夹具）+ `evidence.sh` | `ORCH` | `T0.2a` | `scripts/verify_gate.sh`、`scripts/evidence.sh`、`.gate_test_baseline` |
| **T0.3** | **核心契约冻结 + 锁定验收测试集** | `ORCH` | `T0.1` | 冻结 `PetState/Event/Effect/Emotion/Action/RPSPhase/RPSMove`、`MotionPose`、`SecretStore`、`LLMConfig` 签名，并在 `Tests/AcceptanceTests/` 写入 DEV 不可改的契约测试 |

**Iteration 0 验收标准**：
- `AC-0.1`：增量编译后 `swift test` 全部通过且 `< 15s`，全库 0 处 `import XCTest`。
- `AC-0.2`：`./scripts/build_app.sh` 产出有效 `dist/DabaiPet.app`，`codesign --verify --strict` 通过且 DR 绑定 `DabaiPet Local Dev`。
- `AC-0.3`：`./scripts/verify_gate.sh` 自身通过；其内置正反样本自测夹具确认“违规样本 100% 拦截，合法样本（如 `claude-haiku-4-5`、`task-1`）0 误报”。

---

### Iteration 0.5：MVP 前置可行性探针（Spikes S1–S4，真机二元签收）

> **目标**：花最短时间在真机把 macOS 系统边界隐患全部探明，任何一项 `FAIL` 立即调整架构后再进 Iteration 1。

| Spike | 验证目标 | 主责 | 依赖 | 二元判定（PASS / FAIL） |
| :--- | :--- | :---: | :---: | :--- |
| **S1** | 自签名证书跨编译稳定性 + TCC/Keychain + `CGEventSource.counterForEventType` 权限验证 | `DEV-H` | `T0.2a` + 人工已建证书 | 连续 2 次重编重签后 `open dist/DabaiPet.app`：Keychain 读写不弹密码、TCC 不掉授权；确认 `counterForEventType(.keyDown)` 是否免辅助功能权限 |
| **S2** | 透明浮窗 `ignoresMouseEvents` 动态穿透 + AppKit 拖拽/单击 + 独立 `ChatPanel` 中文拼音 IME | `DEV-H` | `T0.2a` | 透明区可正常点中背后窗口；拖动不抖动；拼音输入“nihao”组字按回车仅上屏不发送，再回车才发送（验证不激活 App 是否可行，不行则定案为激活） |
| **S3** | 宽窗画布内滚动在单屏/多屏（含负坐标与刘海 `visibleFrame`）下的实测 | `DEV-H` | `T0.2a` | 滚动扩宽/收缩无闪烁、无裁切、不跨屏 |
| **S4** | 真实性能基线标定（空壳 SwiftUI / Canvas 30FPS / `CALayer` 呼吸三组对比） | `DEV-H` | `T0.2a` | 产出 `footprint` + 30 帧 `top` + WindowServer 增量对比表，正式锁定 Iteration 1 性能红线数值 |

---

### Iteration 1：MVP 大白桌宠本体（可独立运行把玩）

| Ticket | 任务名称 | 主责 | 依赖 | 核心交付物 |
| :--- | :--- | :---: | :---: | :--- |
| **T1.1** | 核心状态机 `PetStateMachine`（含全部事件与副作用） | `DEV-L` | `T0.3` | `PetStateMachine.swift` + 单测（通过 `AcceptanceTests`） |
| **T1.2** | `MotionEngine`（注入可种子化 RNG）+ `ScreenGeometry` 纯数学模块 | `DEV-H` | `T0.3`, `S3` | `MotionEngine.swift`、`ScreenGeometry.swift` + 零裁切包络单测与多屏负坐标单测 |
| **T1.3** | 代码化设计资产 + `CALayer` 大白矢量视图 + `--snapshot` 离屏联系表 | `UIUX` → `DEV-H` | `T0.3`, `S4` | `DesignTokens.swift`、`BaymaxGeometry.swift`、`BaymaxLayerView.swift`、`--snapshot` 命令 |
| **T1.4a** | 透明置顶 `PetFloatingPanel` + `ignoresMouseEvents` 动态穿透 + Spaces | `DEV-H` | `T0.3`, `S2` | `PetFloatingPanel.swift`（可用占位图形先验证，无需强等 T1.3） |
| **T1.4b** | AppKit `PetInputOverlayView`（拖拽速度倾斜 + `<3pt/250ms` 戳肚皮 + 右键菜单） | `DEV-H` | `T1.4a` | `PetInputOverlayView.swift` |
| **T1.4c** | 宽窗画布内滚动联动 + 多屏 `visibleFrame` 钳制 + 显示器热插拔复位 | `DEV-H` | `T1.2`, `T1.4a` | 滚动控制器集成与屏幕变化监听 |
| **T1.4d** | 位置/偏好持久化 + 减弱动态效果 + 遮挡/休眠暂停动画 | `DEV-L` | `T1.4a` | `PreferencesStore.swift` + 系统状态监听 |
| **T1.5** | **App 协调脊柱 `PetController` + `--smoke-test` + 干净退出** | `DEV-H` | `T1.1`, `T1.3`, `T1.4b`, `T1.4c`, `T1.4d` | `PetController.swift`（串联状态机/动效/窗口/副作用） |
| **T1.6** | 顶部菜单栏图标（纯代码 template `NSImage`）+ 单实例保护 | `DEV-L` | `T1.5` | `AppDelegate.swift`（显隐、归位右下角、防双开、退出） |

**Iteration 1 验收标准**：
- `AC-1.1（契约与状态机）`：`AcceptanceTests` + `PetStateMachineTests` 100% 通过，覆盖离开 `listening`/`playingRPS` 必产停设备副作用。
- `AC-1.2（零裁切数学证明）`：单测遍历 `t ∈ [0, 2.2s]`（步长 `1/120`）与 `0.8x/1.0x/1.25x` 缩放，断言大白变换后包络 100% 落于窗口内、滚动路径 100% 落于 `visibleFrame` 内（含负坐标副屏夹具）。
- `AC-1.3（无头自检）`：`--smoke-test` 输出 JSON 断言：`activationPolicy == .accessory`、`isOpaque == false`、`hasShadow == false`、初始 `idle`、音视频会话均 `nil`。
- `AC-1.4（UIUX 视觉签收）`：`--snapshot` 生成黑白背景联系表 PNG，经 `UIUX` 签收并固化像素差基线。
- `AC-1.5（性能与干净退出）`：右键「关闭大白」1 秒内 `pgrep -x DabaiPet` 无残留；`evidence.sh` 实测待机 `phys_footprint` 与 CPU（含 WindowServer）满足 S4 标定红线。
- `AC-1.6（人工 30 秒真机签收）`：`open dist/DabaiPet.app` 后实测：透明区点中下层窗口、拖拽丝滑不跑出屏幕、轻点戳肚皮有果冻回弹、右键「滚动一下」在桌面滚出回稳不裁切、右键「关闭大白」彻底退出。

---

### Iteration 2：轻互动陪伴 + 本地快反对话 + 完整 UI

| Ticket | 任务名称 | 主责 | 依赖 | 核心交付物 |
| :--- | :--- | :---: | :---: | :--- |
| **T2.1a** | 鲁棒 `EmotionTagParser` + `ChatMessage` 成对历史截断 | `DEV-L` | `T0.3` | 支持大小写/全半角/任意位置/多标签剥离，不触发动作，含全量单测 |
| **T2.1b** | `LocalReplyEngine` 本地关键词快反 + 大白治愈台词库 | `DEV-L` + `UIUX` 审文案 | `T2.1a` | `LocalReplyEngine.swift` + p99 `< 5ms` 性能单测 |
| **T2.2** | `HealthReminderScheduler`（注入时钟 + 睡眠/锁屏/空闲/对话态排队） | `DEV-L` | `T0.3` | `HealthReminderScheduler.swift` + 全边界单测 |
| **T2.3a** | `ChatPanelController`（独立 `ChatPanel` + IME `hasMarkedText` + 四角防溢出定位） | `DEV-H` | `T1.2`, `T1.5`, `S2` | `ChatPanelController.swift` + 防溢出纯函数单测 |
| **T2.3b** | `ChatBubbleView` SwiftUI 对话消息视图 | `DEV-L` | `T2.1a`, `T2.3a` | `ChatBubbleView.swift` |
| **T2.3c** | `SettingsWindowController`（`LSUIElement` 激活置顶） | `DEV-H` | `T1.6` | `SettingsWindowController.swift` |
| **T2.3d** | `SettingsView` 设置表单视图（AI 参数 + 陪伴开关） | `DEV-L` | `T2.3c` | `SettingsView.swift` |
| **T2.4** | 本地快反 + 健康扫描联调接入 `PetController` | `DEV-H` | `T2.1b`, `T2.2`, `T2.3b`, `T2.3d` | 端到端免配置聊天 + 健康扫描闭环 |
| **T2.5** | 敲键陪伴（`CGEventSource.counterForEventType` 计数轮询） | `DEV-H` | `T1.5`, `T2.3d`, `S1` | `TypingCompanionMonitor.swift`（默认关闭，物理零字符读取） |

**Iteration 2 验收标准**：
- `AC-2.1`：免配置 API 时，`LocalReplyEngine` 单测 p99 `< 5ms`，真机输入“你好/有点累/巴拉拉拉”即刻弹出大白回复与对应表情。
- `AC-2.2`：`EmotionTagParserTests` 全覆盖 `[happy]`/`【Happy】`/`[开心]`/多标签/句末标签/未知标签与防 `[roll]` 动作触发。
- `AC-2.3`：`ScreenGeometry` 单测验证大白位于屏幕四角及副屏时 `ChatPanel` 永不溢出 `visibleFrame`。
- `AC-2.4（人工 IME 签收）`：中文拼音输入“nihao”组字按回车只上屏不发送，再回车才发送；`Esc` 关闭气泡。
- `AC-2.5（隐私门禁）`：静态与 Diff 确认 `T2.5` 仅读 `counterForEventType` 计数，默认关闭。

---

### Iteration 3：标准 BYOK 大模型 API + 按需原生语音（macOS 26）

| Ticket | 任务名称 | 主责 | 依赖 | 核心交付物 |
| :--- | :--- | :---: | :---: | :--- |
| **S5** | **【前置 Spike】语音探针**：macOS 26 `SpeechAnalyzer` zh-CN 端侧资产 vs `SFSpeechRecognizer` on-device 实测 | `DEV-H` | `T1.6` | 确认主备 STT 路径、资产下载流程与错误码（二元签收） |
| **T3.1** | 非流式 `OpenAICompatibleClient` + `AnthropicClient` + 真实厂商 Mock 夹具 | `DEV-H` | `T2.1a` | 双协议实现 + 20s `Task` 总超时 + `os.Logger` `.private` + 4 厂商 Mock 单测 |
| **T3.2** | `KeychainStore`（实现 `SecretStore`）+ 设置页「测试连接」打通 | `DEV-H` | `T2.3d`, `T3.1`, `S1` | Keychain 存取 + `GET /models` 优先探活 + 明确中文报错 |
| **T3.3a** | `VoicePermissionCoordinator`（麦克风 + 语音双授权编排 & 错误码映射） | `DEV-H` | `S5` | 权限顺序提示与无麦/拒权降级 |
| **T3.3b** | `SpeechInputService`（`nonisolated @Sendable` tap + 2.5s 无变化/30s 硬停 + 设备变更处理） | `DEV-H` | `T3.3a` | 按需 STT，离开必停 `AVAudioEngine` |
| **T3.3c** | `SpeechOutputService`（`AVSpeechSynthesizer` 强引用 + 静音 + 与 STT 互斥） | `DEV-L` | `T1.5` | 中文温和播报与一键静音 |
| **T3.4** | 语音/文字 ↔ BYOK API ↔ 情绪表情 ↔ TTS 完整联调 | `DEV-H` | `T3.2`, `T3.3b`, `T3.3c`, `T2.4` | 断网/401/429/超时温柔兜底，绝不卡死 `thinking` |

**Iteration 3 验收标准**：
- `AC-3.1（双协议单测）`：Mock 覆盖 OpenAI / DeepSeek（忽略 `reasoning_content`）/ Ollama / Anthropic（顶层 `system` + 成对截断 + `max_tokens`）及 401/429/超时/畸形 JSON。
- `AC-3.2（金丝雀零泄漏）`：运行 `evidence.sh` 金丝雀 Key 扫描，偏好文件、缓存、`/tmp` 及 `log show` 全部 0 命中；重启 App 仍可免密码读取 Keychain。
- `AC-3.3（按需开麦硬证据）`：待机时 CoreAudio 查询麦克风未运行；录音停止后 1 秒内 CoreAudio 查询返回未运行且系统橙灯熄灭；开麦瞬间 TTS 立即停止。
- `AC-3.4（人工签收）`：填写真实 API Key（或本地 Ollama）完成一轮语音提问→大白回复+情绪表情+语音播报；断网测试确认温柔中文提示不卡死。

---

### Iteration 4（二期扩展）：摄像头手势石头剪刀布

| Ticket | 任务名称 | 主责 | 依赖 | 核心交付物 |
| :--- | :--- | :---: | :---: | :--- |
| **S6** | **【前置 Spike】手势样本采集**：录制 ~200 帧真实 21 点关键点 JSON（多角度/距离/左右手） | `DEV-H` | `T1.6` | `Tests/Fixtures/rps_real_landmarks.json` |
| **T4.1** | `HandGestureClassifier`（像素转换 + 关节角 + 掌尺度 + 置信度 + 滞回 + “出！”后采样 + 预锁定公平裁判） | `ORCH` 给公式 → `DEV-L` | `T0.3`, `S6` | 算法实现 + 合成单测 + 真实夹具回归测试 |
| **T4.2** | `CameraRPSService`（串行队列 `AVCaptureSession` + Vision `maximumHandCount=1` + 5–8 FPS 节流） | `DEV-H` | `T4.1` | 严格非主线程启停 + 退出释放 |
| **T4.3** | `RPSOverlayView`（迷你取景窗 + 3-2-1 摇臂 + 大白矢量出拳徽章 + 记分板 + 回放模式） | `UIUX` → `DEV-H` | `T1.3`, `T4.2` | 完整对局体验 + 离线回放验证 |

**Iteration 4 验收标准**：
- `AC-4.1（真实夹具准确度）`：在 `S6` 真实关键点夹具上，分类准确率 `>= 95%`、`unknown` 率 `<= 10%`；大白出拳在倒计时开始前即锁定（单测验证）。
- `AC-4.2（摄像头释放硬证据）`：退出游戏后 **1 秒内** CoreMediaIO 查询确认摄像头 `not running` 且绿灯熄灭，内存回落。
- `AC-4.3（人工真机对局签收）`：连续完成 5 局石头/剪刀/布真机对局，倒计时节奏自然、识别准确、退出无残留。

---

## 4. 给 `ORCH`（`codex 6.2 astra xhigh`）的启动调度 Prompt

直接复制下方 Prompt 发给 **`codex 6.2 astra xhigh`** 即可启动完整循环开发：

```markdown
你是 DabaiPet 项目的总控调度与验收官（ORCH = codex 6.2 astra xhigh）。

请先完整阅读以下 4 份规范文档：
1. `README.md`（含唯一角色→模型映射表与环境基线）
2. `docs/TECHNICAL_SPEC.md`
3. `docs/UI_UX_SPEC.md`
4. `docs/LOOP_ORCHESTRATION_AND_ACCEPTANCE.md`
5. `docs/LOOP_STATUS.md`

你的执行铁律：
1. 严格遵循“裁判与运动员分离”：你负责派发任务、编写门禁（T0.2b）、冻结契约与锁定验收测试（T0.3）、执行三段式门禁、审查 Diff、裁决 AC 与维护 `docs/LOOP_STATUS.md`。
2. 每次仅派发依赖全部 DONE 的 Ticket，任务单必须包含：Ticket ID、允许编辑路径、契约片段、逐条 AC，并明确禁止 `import XCTest`（本机仅支持 Swift Testing `import Testing`）与禁止修改 `Tests/AcceptanceTests/`。
3. 失败必须先分类：
   - `ENV`（如未建 `DabaiPet Local Dev` 证书/权限/硬件）或 `SPEC`（规范冲突）→ **不计入失败次数**，直接停下沟通或修规范；
   - `IMPL`（代码实现缺陷）→ 严格执行四级异构熔断：
     - 第 1 次失败 → 尝试 #2：由 `codex 6.2 astra high` 修复；
     - 第 2 次失败 → 尝试 #3：切换 **`Agy · Neon`** 修复；
     - 第 3 次失败 → 尝试 #4：切换 **`Agy · Claude Opus 5.5`** 修复；
     - 第 4 次仍失败 → 立即标记 `BLOCKED` 输出《阻塞诊断报告》，等待人工审核。
4. 先推进 **Iteration 0（T0.1 → T0.2a → T0.2b → T0.3）**，确认 `DabaiPet Local Dev` 自签名证书就绪后推进 **Iteration 0.5（Spike S1–S4）** 并请人类用户做 10 分钟真机二元签收；签收通过后再进入 **Iteration 1（MVP 大白桌宠）**。

现在请检查 `docs/LOOP_STATUS.md`，从 `T0.1` 开始第一轮派发。
```
