# DabaiPet UI/UX 与大白动效设计规范（UI_UX_SPEC v2）

> 本文档由 **`UIUX`（`Agy · Neon`）** 负责演进与签收。由于本机无 Xcode `#Preview`，本规范采用 **“代码化 Design Token + 离屏 `--snapshot` 联系表 PNG”** 的可编译视觉闭环，彻底消除 Markdown 与代码漂移。

---

## 1. 代码化设计资产（Design-as-Code）

`UIUX` 直接拥有并维护以下两个纯数据 Swift 文件（位于 `DabaiPetCore`，零 GUI 依赖，受单测约束）：
1. **`Sources/DabaiPetCore/Design/DesignTokens.swift`**：浅/深色桌面色彩 RGBA 分量、轮廓对比度常量、圆角/间距与字体层级。
2. **`Sources/DabaiPetCore/Design/BaymaxGeometry.swift`**：大白头/躯干/眼/臂/脚的基准尺寸、锚点、命中路径定义（供绘制与 `ignoresMouseEvents` 穿透共用，保证视觉与点击区 100% 重合），以及各缩放档位下的安全包络窗口计算函数。

---

## 2. 大白矢量解剖与色彩 Token

基准比例以 `scale = 1.0` 定义（支持用户设置：小 `0.8x` / 标准 `1.0x` / 大 `1.25x`）；**待机窗口尺寸不再硬编码为 `160×180`**，而是由 `BaymaxGeometry.idleWindowSize(scale:)` 依据完整姿态包络 + `8pt` 安全边距计算得出，从数学上杜绝任何裁切。

### 2.1 色彩 Token（必须保证白底与黑底均清晰可见）

| Token | 浅色桌面 | 深色桌面 | 用途 |
| :--- | :--- | :--- | :--- |
| `baymaxBodyTop` | `#FFFFFF` | `#F8FAFC` | 充气棉花糖躯干顶部高光 |
| `baymaxBodyBottom` | `#E6ECF2` | `#D8E0EB` | 躯干底部立体柔和径向渐变 |
| `baymaxStroke` | `rgba(30, 41, 59, 0.16)` | `rgba(255, 255, 255, 0.22)` | 1.2pt 极细轮廓线（防白底隐身） |
| `baymaxEye` | `#1E242B` | `#1E242B` | 标志性双眼实心圆 + 中间细连线 |
| `baymaxChestPort` | `rgba(148, 163, 184, 0.28)` | `rgba(148, 163, 184, 0.34)` | 左胸医疗芯片插槽小圆环 |
| `baymaxBlush` | `rgba(255, 138, 155, 0.44)` | `rgba(255, 138, 155, 0.50)` | 开心 / 被戳肚皮时的脸颊红晕 |
| `groundShadow` | `rgba(15, 23, 42, 0.15)` | `rgba(0, 0, 0, 0.32)` | 脚底柔和椭圆落地影（不计入点击命中区） |
| `accentHeal` | `#38BDF8` | `#7DD3FC` | 倾听光环 / 健康扫描医疗柔蓝 |

### 2.2 几何结构
- **头部**：宽扁椭圆（`44×31pt`），双圆眼（直径 `6.2pt`，中心距 `18pt`）+ `1.5pt` 中间连线；眨眼时双眼压扁为 `1.5pt` 融成一条治愈横线。
- **躯干**：上窄下圆梨形贝塞尔曲线（`84×92pt`），左胸带 `10pt` 微弱圆环。
- **双臂与短脚**：胶囊形双臂绕肩部锚点旋转；底部圆墩墩短脚，拖拽离地时微微下垂，落地影同步缩小变淡。

---

## 3. 分层渲染与动效曲线规范（兼顾颜值与极低功耗）

### 3.1 待机 vs 活跃的双模渲染策略（已拍板）
- **待机（`idle`）**：大白矢量层使用 **`CALayer` / `CAShapeLayer` 组合**，呼吸通过 **`CABasicAnimation`（`transform.scale.y: 1.00 ↔ 1.028`, `scale.x: 1.00 ↔ 0.988`，周期 `3.6s`，`autoreverses = true`）** 交给系统渲染服务进程执行，**App 主进程 CPU 趋近于 0**。
- **离散眨眼**：由可种子化定时器每 `3.5s – 6.5s` 触发一次 `160ms` 短动画，结束后立即回归零重绘。
- **活跃动作（`dragging` / `rolling` / `poked` / `listening` / `speaking` / `playingRPS`）**：临时开启 `NSView.displayLink` 按 `MotionEngine` 输出的 `MotionPose` 逐帧驱动，动作一结束立即 `invalidate` displayLink 回归低功耗。
- **节能与无障碍**：
  - 窗口完全被遮挡（`occlusionState`）、系统休眠、锁屏、低电量模式时自动暂停所有动画；
  - 系统开启 **“减弱动态效果（Reduce Motion）”** 时，关闭翻滚 360° 旋转（改为平滑轻微横移+点头）、呼吸幅度减半。

### 3.2 核心状态演出
- **Dragging（拖拽）**：拎起轻微纵向拉长（`scaleY: 1.05, scaleX: 0.96`）；水平拖动速度 `vx` 驱动反向倾斜 `clamp(-vx * 0.08, -14°, +14°)`；松手 `350ms` 阻尼弹簧回正。
- **Rolling（右键「滚动」，宽窗画布内滚动，总时长 `2.2s`）**：
  1. `0.00–0.25s`：蓄力下蹲（`scaleY: 0.86, scaleX: 1.12`），双臂贴身；
  2. `0.25–1.25s`：在扩宽后的宽窗画布内横向滚出 `180pt`（靠右屏边自动向左滚，全程夹在当前屏 `visibleFrame` 内不跨屏），旋转角按等效半径联动（减少视觉打滑）叠加轻微弹跳；
  3. `1.25–1.85s`：弹性刹停并柔和回滚稳定；
  4. `1.85–2.20s`：站稳轻微晃头，头顶闪过 2 颗淡金小星星（`emotion = .dizzy`），宽窗收缩落位并归位 `idle`。
- **Poked（单击戳肚皮）**：仅当按下-抬起位移 `< 3pt` 且 `< 250ms` 触发；肚皮果冻回弹（`scaleX: 1.14, scaleY: 0.88`）+ 脸颊微红 + 弹出 2.2s 短气泡（如“巴拉拉拉～”）。
- **Listening / Thinking / Speaking**：倾听时扩散柔蓝呼吸光环；思考时头部轻摇 `±4°` + 头顶 3 点动效；说话时依据 `PetEmotion`（`happy` 弯眼红晕、`care` 胸口淡蓝柔光、`sleepy` 半眯眼、`excited` 轻跳）做表情反馈。
- **RPS Game（二期石头剪刀布）**：倒计时 `3-2-1` 双臂规律摇晃，“出！”瞬间一侧伸出高辨识度纯代码矢量「石头 / 剪刀 / 布」徽章。

---

## 4. 桌面交互与界面布局规范

### 4.1 右键菜单（原生 `NSMenu`）
1. `滚动一下`
2. `和大白聊聊…`
3. `健康扫描`
4. ---
5. `互动开关`（子菜单：`静音语音播报`、`久坐健康提醒`、`敲键陪伴（仅节拍）`、`石头剪刀布（二期）`）
6. `设置 API 与偏好…`
7. ---
8. `关闭大白`

### 4.2 顶部菜单栏图标（Menu Bar Extra）
- 纯代码绘制 `NSImage(isTemplate: true)` monochrome 大白头部剪影，自动适配浅/深色菜单栏。
- 菜单项：`显示/隐藏大白`、`归位到右下角`、`静音播报`、`设置…`、`退出大白`。

### 4.3 独立聊天窗（`ChatPanel`，严禁用 `NSPopover`）
- `290 × 270 pt` 毛玻璃圆角浮窗（`.ultraThinMaterial`，圆角 `16pt`），由 `ScreenGeometry.chatPanelFrame(...)` 纯函数根据大白位置与当前屏 `visibleFrame` 自动选择弹出方向（正上方优先，靠顶自动翻下方/侧方），保证四边永不溢出。
- 顶栏：模式徽章（`本地模式` / `OpenAI` / `Claude` / `Ollama`）+ 清空对话 + 关闭按钮。
- 输入栏：封装 AppKit `NSTextField`（回车发送前检查 `hasMarkedText()` 保护中文拼音组字）+ 按需麦克风按钮（平时灰、录音亮 `accentHeal` 脉冲）。支持 `Esc` 关闭。

### 4.4 设置窗口（`SettingsWindowController` + `SettingsView`）
- 打开时主动 `NSApp.activate()` 确保在 `LSUIElement` 模式下置顶可见。
- 分组表单：
  - **AI 连接（MVP 非流式）**：Provider（`本地模式` / `OpenAI 兼容` / `Anthropic (Claude)`）、`Base URL`（附 OpenAI / DeepSeek / Ollama 快捷预设）、`API Key`（`SecureField`，标注“仅存于本机 Keychain”）、`Model`（占位提示 `gpt-4o-mini` / `claude-haiku-4-5` / `deepseek-chat`）、「测试连接」按钮。
  - **陪伴与外观**：缩放比例（`0.8x / 1.0x / 1.25x`）、静音播报、健康提醒间隔（关闭 / 30m / 45m / 60m）、敲键陪伴（默认关闭，标注“物理级零按键内容读取”）。

---

## 5. 无 Xcode 下的 `UIUX` 视觉验收闭环（`--snapshot`）

无需开启“屏幕录制”权限，也无需 Xcode Preview。App 内置离屏截图命令：
```bash
open -W -n dist/DabaiPet.app --args --snapshot --out /tmp/dabai_contact_sheet.png
```
自动离屏渲染一张**固定联系表（Contact Sheet）**，涵盖：
- `idle`、`dragging(vx=+120)`、`rolling(t=0.15 / 0.75 / 1.50 / 2.00)`、`poked`、`listening`、`speaking(happy/care/sleepy)`；
- 分别叠加 **纯白背景** 与 **纯黑背景**，覆盖 `1.0x` 与 `1.25x` 缩放。

**`UIUX` 视觉签收标准**：
- [ ] 纯白与纯黑背景下大白轮廓清晰，无隐身、无脏边；
- [ ] 联系表中所有滚动与缩放姿态零裁切；
- [ ] 与基线 PNG 像素差超阈值时由 `UIUX` 人工复核确认；
- [ ] 聊天与错误文案保持大白温和治愈口吻，绝不暴露原始英文报错堆栈。
