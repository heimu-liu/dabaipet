# DabaiPet 技术架构与工程设计规范（TECHNICAL_SPEC v2）

> 本文档为所有模型共享的 **Single Source of Truth（唯一技术事实源）**。本文档正文仅使用角色代号（`ORCH`/`DEV-H`/`DEV-L`/`UIUX`），实际模型映射见 [README.md](../README.md)。

---

## 1. 产品定位、范围与硬性红线

### 1.1 已拍板核心决策
1. **运行目标**：**仅本机自用**，最低系统版本锁定 **macOS 26（`.macOS(.v26)`）**，Apple Silicon `arm64`。暂不做外部公证与跨机分发。
2. **代码签名**：使用本机自签名代码签名证书 **`DabaiPet Local Dev`**（见 README 一次性创建步骤），保证跨编译重建 Designated Requirement (DR) 稳定，避免 TCC 权限与 Keychain ACL 反复失效。
3. **测试框架**：本机仅装 Command Line Tools，**无 `XCTest.framework`**。项目 **100% 使用 Swift Testing（`import Testing`、`@Test`、`#expect`）**，严禁 `import XCTest`。
4. **渲染策略**：纯代码矢量绘制；**待机呼吸使用 `CALayer` Core Animation + 事件驱动重绘**（显著降低 App CPU 与 WindowServer 合成开销），仅在拖拽/滚动/戳肚皮等短时活跃动作期间启用 `NSView.displayLink` 逐帧驱动。
5. **滚动架构**：采用 **宽窗画布内滚动**（滚动开始时临时扩宽至覆盖当前屏 `visibleFrame` 内路径的宽窗，画布内由 `offsetX` 驱动完整滚动，结束后收缩并落位到终点），禁止跨屏滚动。
6. **合规与 AI 边界（零封号风险）**：
   - **严禁**读取、抓取或代理任何第三方消费级订阅凭证（`~/.codex`、`~/.claude` 等 OAuth token），**严禁**子进程套壳调用 `codex` / `claude` CLI。
   - 采用 **免配置本地快反模式（默认） + 标准 BYOK API 设置面板**（OpenAI 兼容协议 + Anthropic Messages 协议 + 本地 Ollama），API Key 仅存于 macOS Keychain。
   - **MVP 采用非流式 HTTP 请求**（回复简短、`max_tokens ~250–300`，更稳更易测）。
   - **情绪与动作严格分离**：大模型**仅允许输出情绪表情标签**（`PetEmotion`），**严禁大模型遥控“滚动”等物理动作**（动作仅由用户触发）。

### 1.2 非功能性性能红线（精确度量口径）

> 具体数值红线将在 **Iteration 0.5 Spike S4** 实测本机空壳基线后最终标定，以下为初始目标口径：

| 指标项 | 度量工具与口径 | 目标阈值 |
| :--- | :--- | :--- |
| 待机物理内存 | `/usr/bin/footprint -p <PID>` 的 `phys_footprint`（**禁止用 `ps -o rss`**） | `<= 空壳基线 + 25 MB`（初始预期 `<= 55 MB`） |
| 待机 CPU（App + WindowServer） | `top -l 31 -s 1 -pid <PID> -stats cpu`（**丢弃第 1 帧**取后 30 帧均值/P95），并记录 WindowServer CPU 增量 | App 均值 `<= 0.8%`；WindowServer 增量 `<= 1.5%` |
| 待机硬件传感器 | CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` & CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` | 麦克风/摄像头 **0 活跃会话** |
| 二期摄像头采样率 | `AVCaptureDevice` 帧间隔节流 + `alwaysDiscardsLateVideoFrames = true` | `5 – 8 FPS`（上限 `10 FPS`） |
| 增量单测耗时 | 增量编译后执行 `./scripts/test.sh`（CLT 适配的 `swift test`） | `< 15s`（冷编译只记录不卡门禁） |

---

## 2. SwiftPM 工程拓扑与目录结构

项目采用 **4 Target 清晰分层**（明确禁用 SwiftPM `resources:`，避免 `Bundle.module` 放进 `.app` 根目录导致 `codesign` 报 `unsealed contents`）：

- `DabaiPetCore`（Library）：100% 纯逻辑 + 设计 Token/几何参数。**严禁**导入 `AppKit`/`Cocoa`/`SwiftUI`/`Carbon`/`AVFoundation`/`Speech`/`Vision`/`CoreMediaIO`，开启 warnings-as-errors。
- `DabaiPetUI`（Library）：SwiftUI 纯视图与 `CALayer` 大白绘制组件，支持无权限离屏渲染（`ImageRenderer` / `cacheDisplay`），供 App 组装与 `--snapshot` 视觉验证。
- `DabaiPetApp`（Executable）：macOS AppKit 窗口壳、协调控制器、系统硬件服务；仅保留单一 `main.swift` 入口（手动 `NSApplication.shared.run()`，**禁止**再写 `@main` 冲突）。
- `DabaiPetCoreTests`（第 4 个 Target，使用 **Swift Testing**）同时发现 `Tests/DabaiPetCoreTests/` 与 `Tests/AcceptanceTests/`。其中 `Tests/AcceptanceTests/` 由 `ORCH` 在 `T0.3` 冻结，**开发模型严禁修改该目录**。

```text
dabaipet/
├── Package.swift                        # swift-tools-version: 6.2, platforms: [.macOS(.v26)]
├── README.md
├── Resources/
│   └── Info.plist                       # 完整 Bundle 元数据 + LSUIElement + TCC/本地网络权限键
├── scripts/
│   ├── build_app.sh                     # 编译并自签名生成 dist/DabaiPet.app
│   ├── verify_gate.sh                   # 【ORCH 编写】硬门禁 + 静态扫描自测夹具
│   └── evidence.sh                      # 【ORCH 编写】smoke-test/snapshot/footprint/音视频状态采集
├── docs/
│   ├── TECHNICAL_SPEC.md
│   ├── UI_UX_SPEC.md
│   ├── LOOP_ORCHESTRATION_AND_ACCEPTANCE.md
│   └── LOOP_STATUS.md
├── Sources/
│   ├── DabaiPetCore/                    # 【纯逻辑库，100% 无头 Swift Testing】
│   │   ├── Design/
│   │   │   ├── DesignTokens.swift       # 【UIUX 拥有】颜色分量、尺寸、对比度常量
│   │   │   └── BaymaxGeometry.swift     # 【UIUX 拥有】纯数据几何锚点、宽窗包络计算函数
│   │   ├── StateMachine/
│   │   │   ├── PetState.swift           # PetState / PetEvent / PetEffect / PetEmotion / PetAction / RPSPhase / RPSMove
│   │   │   └── PetStateMachine.swift    # 确定性状态转换表 + 优先级 + 副作用产出
│   │   ├── Motion/
│   │   │   ├── MotionPose.swift         # 渲染姿态值类型（Sendable）
│   │   │   └── MotionEngine.swift       # 注入可种子化 RNG；眨眼/拖拽/翻滚/戳肚皮纯数学计算 + 包络校验
│   │   ├── WindowMath/
│   │   │   └── ScreenGeometry.swift     # 多屏负坐标 visibleFrame 钳制、宽窗滚动路径计算、气泡防溢出定位纯函数
│   │   ├── Dialogue/
│   │   │   ├── ChatMessage.swift        # 对话消息 + 成对历史截断逻辑
│   │   │   ├── EmotionTagParser.swift   # 鲁棒情绪标签剥离（大小写/全半角/任意位置/多标签）
│   │   │   └── LocalReplyEngine.swift   # 本地关键词快反 + 大白台词库
│   │   ├── LLM/
│   │   │   ├── LLMConfig.swift          # Provider / BaseURL 规范化 / Model / maxTokens / timeout（不含 apiKey）
│   │   │   ├── SecretStore.swift        # 密钥存取协议（Core 提供 InMemorySecretStore 供测试）
│   │   │   ├── LLMTransport.swift       # HTTP 抽象协议（便于真实厂商响应 Mock）
│   │   │   ├── OpenAICompatibleClient.swift # 非流式 OpenAI / DeepSeek / Qwen / Ollama 客户端
│   │   │   └── AnthropicClient.swift    # 非流式 Anthropic Messages 客户端（顶层 system + 交替校验）
│   │   ├── Companion/
│   │   │   └── HealthReminderScheduler.swift # 注入时钟；含睡眠唤醒/锁屏/用户空闲/对话态排队规则
│   │   └── VisionLogic/                 # 【二期纯数学手势分类】
│   │       ├── HandLandmarks.swift      # 像素坐标 + 置信度（Sendable）
│   │       └── HandGestureClassifier.swift # 关节角 + 掌尺度归一化 + 置信度 + 双阈值滞回 + 窗口投票 + 公平裁判
│   ├── DabaiPetUI/                      # 【纯视图层，支持离屏 --snapshot】
│   │   ├── BaymaxLayerView.swift        # CALayer Core Animation 待机呼吸 + 矢量路径渲染
│   │   ├── ChatBubbleView.swift         # 对话消息列表与状态徽章
│   │   ├── SettingsView.swift           # BYOK API + 偏好设置表单
│   │   └── RPSOverlayView.swift         # 【二期】3-2-1 倒计时、大白矢量出拳徽章与记分板
│   └── DabaiPetApp/                     # 【macOS 原生 AppKit 外壳与硬件服务】
│       ├── main.swift                   # 唯一入口，解析 --smoke-test / --snapshot 参数或启动常驻运行
│       ├── AppDelegate.swift            # 单实例保护、Menu Bar Extra、系统睡眠/屏幕热插拔监听
│       ├── Controller/
│       │   └── PetController.swift      # 【App 脊柱】持有状态机、驱动 displayLink、执行 PetEffect、退出清理
│       ├── Window/
│       │   ├── PetFloatingPanel.swift   # 无边框透明置顶 NSPanel、ignoresMouseEvents 动态穿透、宽窗滚动
│       │   ├── PetInputOverlayView.swift# AppKit mouseDown/Dragged/Up/rightMouseDown、单击vs拖拽阈值
│       │   ├── ChatPanelController.swift# 独立 ChatPanel（canBecomeKey=true）+ NSTextField IME hasMarkedText 保护
│       │   └── SettingsWindowController.swift # LSUIElement App 激活并置顶设置窗
│       ├── Persistence/
│       │   └── PreferencesStore.swift   # UserDefaults schema 版本化（位置按屏幕配置保存、偏好设置）
│       └── Services/
│           ├── KeychainStore.swift      # macOS Keychain 实现 SecretStore
│           ├── VoicePermissionCoordinator.swift # 麦克风 + 语音双授权编排与中文错误码映射
│           ├── SpeechInputService.swift # macOS 26 SpeechAnalyzer（主）+ SFSpeechRecognizer on-device（备）
│           ├── SpeechOutputService.swift# AVSpeechSynthesizer（强引用 + 静音 + 与 STT 互斥）
│           ├── TypingCompanionMonitor.swift # CGEventSource.counterForEventType(.keyDown) 计数轮询
│           └── CameraRPSService.swift   # 【二期】独立串行队列 AVCaptureSession + Vision + 录制夹具模式
└── Tests/
    ├── DabaiPetCoreTests/               # DEV 编写并维护的单元测试
    └── AcceptanceTests/                 # 【ORCH 锁定】DEV 严禁修改的契约验收测试
```

---

## 3. 冻结核心契约（T0.3 必须固化为可编译代码）

### 3.1 完整状态机契约（`PetState` / `PetEvent` / `PetEffect`）

```swift
public enum PetEmotion: String, Codable, Equatable, CaseIterable, Sendable {
    case neutral, happy, care, dizzy, sleepy, excited
}

public enum PetAction: String, Codable, Equatable, Sendable {
    case roll, poke, healthScan, startRPS // 仅允许用户主动触发，严禁由 LLM 文本标签触发
}

public enum RollDirection: Equatable, Sendable {
    case left, right
}

public enum RPSMove: String, Codable, Equatable, CaseIterable, Sendable {
    case rock, paper, scissors
}

public enum RPSPhase: Equatable, Sendable {
    case preparing
    case countdown(remaining: Int, lockedBaymaxMove: RPSMove)
    case sampling(lockedBaymaxMove: RPSMove)
    case result(player: RPSMove?, baymax: RPSMove, outcome: RPSOutcome)
}

public enum RPSOutcome: String, Equatable, Sendable {
    case playerWin, baymaxWin, draw, unrecognized
}

public enum PetState: Equatable, Sendable {
    case idle
    case dragging
    case rolling(direction: RollDirection)
    case poked
    case listening
    case thinking
    case speaking(emotion: PetEmotion)
    case healthReminder
    case playingRPS(phase: RPSPhase)
}

public enum PetEvent: Equatable, Sendable {
    case dragBegan
    case dragEnded
    case pokeTriggered
    case rollRequested(direction: RollDirection)
    case rollCompleted
    case pokeAnimationCompleted
    case listenStarted
    case listenStopped(transcript: String?)
    case llmRequestStarted
    case llmReplyReceived(emotion: PetEmotion)
    case llmFailed
    case speakingFinished
    case healthReminderDue
    case healthReminderDismissed
    case rpsStarted(lockedBaymaxMove: RPSMove)
    case rpsPhaseAdvanced(RPSPhase)
    case rpsEnded
    case appWillTerminate
}

public enum PetEffect: Equatable, Sendable {
    case stopMicrophone
    case stopTTS
    case stopCamera
    case startRollWindowAnimation(direction: RollDirection)
    case showTransientBubble(text: String)
    case enqueueDeferredHealthReminder
}
```

**强制状态转换与副作用约束**：
1. 任何路径离开 `listening`（包括 `dragBegan` / `appWillTerminate` / `listenStopped`），状态机**必须**产出 `.stopMicrophone`。
2. 任何路径进入 `listening`，状态机**必须**先产出 `.stopTTS`（STT/TTS 严格互斥）。
3. 任何路径离开 `playingRPS`（包括关闭预览窗或退出 App），状态机**必须**产出 `.stopCamera`。
4. `healthReminderDue` 在 `listening` / `thinking` / `speaking` / `playingRPS` 期间到达时，**不打断当前状态**，产出 `.enqueueDeferredHealthReminder` 延后待机时展示。
5. `rolling` 具有固定时长 `2.2s`（减弱动态效果开启时降级为短平移动画不旋转），`rollCompleted` 后必归位 `.idle`。

### 3.2 窗口透明穿透、拖拽与 IME 聊天窗规范

- **跨应用透明穿透（P0 修正方案）**：
  - `PetFloatingPanel` 默认 `ignoresMouseEvents = true`；
  - 通过 `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` + local monitor（无需辅助功能权限）按 30–60Hz 节流检测指针是否落入大白身体命中区域（与绘制同源的椭圆/路径组合 + `2pt` 滞回防抖），命中时切 `ignoresMouseEvents = false`，离开时切回 `true`；拖拽期间锁定 `false`。
  - 窗口配置：`isOpaque = false`、`backgroundColor = .clear`、`hasShadow = false`、`level = .floating`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`、`canBecomeKey = false`（本体浮窗不抢工作焦点）。
- **AppKit 拖拽与单击判定**：
  - 使用 AppKit `PetInputOverlayView` 覆写 `acceptsFirstMouse(for:) -> true`，通过 `NSEvent.mouseLocation`（屏幕绝对坐标）计算位移与水平速度 `vx`，**严禁**在被拖动窗口内用 SwiftUI `DragGesture`。
  - 单击戳肚皮阈值：鼠标按下到抬起总位移 `< 3pt` 且耗时 `< 250ms` 触发 `.pokeTriggered`，否则视为拖拽。
  - 右键菜单走 `NSMenu.popUpContextMenu`，动画定时源绑定到 `.common` RunLoop 或 `NSView.displayLink`，防止弹出菜单时动画冻结。
- **宽窗画布内滚动 & 多屏安全**：
  - 窗口正常待机尺寸由 `BaymaxGeometry.idleWindowSize(scale:)` 计算；滚动开始前由 `ScreenGeometry.wideRollFrame(...)` 计算当前屏 `NSScreen.visibleFrame`（支持多屏负坐标、避开刘海与 Dock）内的宽窗矩形并一次性扩宽，画布内由 `MotionPose.offsetX` 驱动完整滚出+回弹，滚动结束收缩并落位终点。
  - 旋转角与水平位移按等效半径联动（减少视觉“打滑”），所有单测须数学证明任意 `t ∈ [0, 2.2s]` 变换后大白身体包络均完全落于窗口内（零裁切）。
  - 监听 `NSApplication.didChangeScreenParametersNotification`，外接显示器拔出时自动拉回主屏 `visibleFrame` 可见区；位置按当前屏幕布局持久化。
- **独立 `ChatPanel` 与中文 IME 保护**：
  - 聊天窗使用独立 `ChatPanel: NSPanel`（**严禁使用 `NSPopover`**），覆写 `canBecomeKey = true`。
  - 焦点策略：在 **Spike S2** 中优先实测 `.nonactivatingPanel` 下中文拼音输入法候选窗表现；若候选窗定位/上屏异常，立即切换为“打开聊天窗时 `NSApp.activate()`，关闭后归还焦点”。
  - 输入框包装 `NSTextField` / `NSTextView`，拦截回车前必须检查 `fieldEditor.hasMarkedText()`——处于拼音组字态时回车仅确认上屏，**绝不触发发送**；支持 `Esc` 关闭。

### 3.3 Swift 6 严格并发规范（防运行期崩溃）

1. **`AVAudioEngine.installTap`**：tap 闭包必须在 `nonisolated` 辅助函数中构造并显式标注 `@Sendable`，闭包内只向识别请求追加 buffer 与计算音量，**严禁访问 `@MainActor` 属性**；安装前必须校验 `inputFormat.channelCount > 0`（防止无麦 Mac 崩溃），并监听 `AVAudioEngineConfigurationChange`（如 AirPods HFP 切换）。
2. **`AVCaptureSession` 与 Vision**：`startRunning()` / `stopRunning()` 严禁在主线程调用，统一放在专用串行 `DispatchQueue`；`AVCaptureVideoDataOutputSampleBufferDelegate` 为独立 `nonisolated final class`，在采集队列完成 Vision 推理并转换为 `Sendable` 的 `HandLandmarks` 值类型后再 `Task { @MainActor in ... }`。
3. **并发逃生门管控**：`@unchecked Sendable`、`nonisolated(unsafe)`、`@preconcurrency`、`.swiftLanguageMode(.v5)` 由门禁脚本自动计数，任何新增必须经 `ORCH` 审查批准。

### 3.4 BYOK 非流式 LLM 客户端与日志隐私

- **协议支持（MVP 非流式）**：
  - `OpenAICompatibleClient`：规范化 BaseURL（自动兼容带/不带 `/v1` 与尾斜杠），忽略 DeepSeek 等模型返回的 `reasoning_content`，支持 `max_tokens`（可兼容 `max_completion_tokens`）。
  - `AnthropicClient`：`system` 放顶层字段，`max_tokens` 必填，严格携带 `x-api-key` 与 `anthropic-version`，历史窗口**成对（user+assistant）截断**保证首条为 `user` 且严格交替。
- **总超时硬保护**：用 Swift Concurrency `Task` 截止时间（默认 `20s`）包裹整个请求（不仅依赖 `URLSession` 空闲超时），超时取消请求并必发 `.llmFailed` 退出 `thinking` 状态。
- **情绪标签鲁棒解析（`EmotionTagParser`）**：不区分大小写，兼容 `[happy]` / `【happy】` / `**[Happy]**` / 中文 `[开心]`，全文剥离所有已知情绪标签并取首个有效情绪；未识别文本原样保留；**绝不解析或执行任何动作指令**。
- **测试连接**：优先发轻量 `GET /models`（若兼容端点未实现则回退极短 `max_tokens: 8` 探活请求）。
- **日志隐私红线**：全项目统一使用 `os.Logger`，任何 `Authorization` Header、API Key、用户对话正文、识别转写文本必须标注 `privacy: .private`。

### 3.5 语音（macOS 26）与隐私安全的敲键陪伴

- **STT 主备路径**（将在 **Spike S5** 最终确认 zh-CN 资产可用性）：
  - 主路径：macOS 26 原生端侧 `SpeechAnalyzer` + `SpeechTranscriber`（支持长时离线识别）；
  - 降级路径：`SFSpeechRecognizer(locale: "zh-CN")` 显式 `requiresOnDeviceRecognition = true`；若不支持端侧则清晰告知用户。
  - 停止机制：用户再次点击停麦 / 识别文本连续 `2.5s` 无变化 / 硬上限 `30s` 自动收尾。
  - 错误码映射：权限拒绝、听写未开、无输入设备、`kAFAssistantErrorDomain` 均映射为大白温和中文提示。
- **TTS**：强引用 `AVSpeechSynthesizer`，偏好中文温和声线并降级到系统默认 `zh-CN`，支持菜单栏一键静音。
- **敲键陪伴（`T2.5`，物理零隐私风险）**：
  - 默认关闭；开启后以低频定时轮询 `CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)` 的计数增量触发大白轻微点头/打气节拍。
  - 物理上**无法获取任何按键内容或组合键**（且在 Spike S1/S2 中验证是否完全免辅助功能权限）。

### 3.6 二期：Apple Vision 石头剪刀布算法规范

- **像素坐标转换**：读取 `VNHumanHandPoseObservation` 21 点前，先乘以当前帧图像宽高 `(width, height)` 转为各向同性像素坐标，消除 16:9 宽高比畸变。
- **多特征融合判定（`HandGestureClassifier`）**：
  - 关键手指关键点 `confidence < 0.3` 直接判 `.unknown`；
  - 主特征：食指/中指/无名指/小指的关节夹角（MCP-PIP-DIP 与 PIP-DIP-TIP）；
  - 辅助特征：掌尺度归一化距离 `dist(tip, MCP) / palmSize`（基准用 MCP 与掌宽，减少手腕被袖口遮挡影响）；
  - 双阈值滞回防抖（避免帧间边界抖动）。
- **公平对局与采样窗口**：
  - 大白出拳在倒计时开始时即随机生成并锁定（`lockedBaymaxMove`）；
  - 采样窗口设在 **“出！”之后 `150ms – 900ms`**（避开倒计时期间玩家握拳上下晃动），要求有效帧 `>= 3` 且众数占比 `>= 60%` 才判定胜负，否则提示重来。
- `VNDetectHumanHandPoseRequest.maximumHandCount = 1`；硬件停止由 CoreMediaIO 查询验证 `<= 1s` 熄灭绿灯。

---

## 4. `Info.plist` 与打包脚本要求

`Resources/Info.plist` 必须包含完整元数据（缺 `CFBundleIdentifier` 会导致 TCC 与 Keychain 异常）：
- `CFBundleIdentifier` = `com.dabaipet.app`
- `CFBundleExecutable` = `DabaiPet`
- `CFBundleName` / `CFBundleDisplayName` = `DabaiPet`
- `CFBundlePackageType` = `APPL`
- `CFBundleShortVersionString` = `0.1.0`；`CFBundleVersion` = `1`
- `LSMinimumSystemVersion` = `26.0`
- `LSUIElement` = `true`
- `NSPrincipalClass` = `NSApplication`
- `NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`、`NSCameraUsageDescription`
- `NSLocalNetworkUsageDescription` + `NSAppTransportSecurity`（`NSAllowsLocalNetworking = true`，支持局域网 Ollama）

`scripts/build_app.sh` 规范：
- 默认使用 `DabaiPet Local Dev` 自签名证书执行 `codesign --force --sign "DabaiPet Local Dev" --identifier com.dabaipet.app dist/DabaiPet.app`（可通过环境变量 `DABAI_CODESIGN_IDENTITY` 覆盖，但门禁默认校验非 ad-hoc）。
- **启动红线**：所有真机运行与权限验收**一律使用 `open dist/DabaiPet.app`**，严禁 `swift run` 或直接执行裸二进制做权限测试。
