# DabaiPet（大白 macOS 桌面宠物）— 多模型循环开发工程规范（v2 定稿）

本项目是一个面向 **本机自用（macOS 26+ Apple Silicon）** 的原生 Swift（AppKit + SwiftUI）极轻量级大白桌面宠物：
- **纯代码矢量绘制**（零外部美术依赖，Retina 无损高清）+ **CALayer 呼吸与事件驱动重绘**；
- **硬件传感器按需唤醒**（平时 0 麦克风/摄像头活跃实例）；
- **免配置本地快反 + 标准 BYOK 大模型 API**（OpenAI 兼容 / Anthropic / 本地 Ollama，Key 存 macOS Keychain，零订阅封号风险）；
- **三段式自动化门禁 + 按阶段真机探针（Spike）+ 四级异构熔断编排**。

> 本规范已整合 **Claude Opus 5.5 (High)** 独立架构评审的 29 项发现及用户最终拍板决策，所有代码实现与循环验收以本版文档为唯一事实源。

---

## 1. 文档导航

| 文档 | 定位 | 主要阅读角色 |
| :--- | :--- | :--- |
| [docs/TECHNICAL_SPEC.md](docs/TECHNICAL_SPEC.md) | 技术架构、SwiftPM + 自签名 `.app` 打包、完整模块契约、Swift 6 并发与安全/性能红线 | 全体模型（必读） |
| [docs/UI_UX_SPEC.md](docs/UI_UX_SPEC.md) | 代码化设计 Token、大白矢量几何、CALayer/宽窗翻滚规范、ChatPanel/IME 与离屏截图走查 | `UIUX` + 开发模型 |
| [docs/LOOP_ORCHESTRATION_AND_ACCEPTANCE.md](docs/LOOP_ORCHESTRATION_AND_ACCEPTANCE.md) | 角色路由、四级异构升级熔断规则、Iteration 0–4 全量 Task DAG、三段式验收门禁与启动 Prompt | `ORCH` + 全体模型 |
| [docs/LOOP_STATUS.md](docs/LOOP_STATUS.md) | 循环开发实时状态看板（由 `ORCH` 持续维护） | `ORCH` + 人类审核者 |
| [docs/SPIKE_ACCEPTANCE.md](docs/SPIKE_ACCEPTANCE.md) | S1–S4 真机探针的操作步骤、预期结果和证据位置 | 测试者 + 人类签收者 |

---

## 2. 唯一角色 → 模型映射表（Canonical Model Mapping）

> 文档正文统一使用左侧**角色代号**，避免模型名变动导致文档漂移。

| 角色代号 | 绑定模型 / 平台 | 核心职责 |
| :--- | :--- | :--- |
| **`ORCH`** | **`codex 6.2 astra xhigh`** | 总控任务派发、契约冻结（`T0.3`）、门禁脚本编写（`T0.2b`）、Diff 审查、AC 裁决、维护 `docs/LOOP_STATUS.md` |
| **`DEV-H`** | **`codex 6.2 astra high`** | 复杂开发主力（透明穿透窗口、宽窗滚动、IME 聊天窗、App 协调层、Swift 6 音视频与 Vision、BYOK 客户端）与 Spike 探针 |
| **`DEV-L`** | **`SOL ultra`** | 简单/边界清晰的开发任务（SwiftPM 脚手架、打包脚本、状态机、本地快反、标签解析、纯视图表单、TTS、手势纯数学分类、单测） |
| **`UIUX`** | **`Agy · Neon`**（`gemini-4-neon`） | 拥有 `DesignTokens.swift` / `BaymaxGeometry.swift` 与 `UI_UX_SPEC.md`，负责视觉/动效规范及离屏截图走查 |
| **`RESCUE-1`** | **`Agy · Neon`**（`gemini-4-neon`） | **第 3 次尝试（异构修复 1）**：当同一 Ticket 连续 2 次 `IMPL` 失败时接手修复 |
| **`RESCUE-2`** | **`Agy · Claude Opus 5.5`**（`claude-opus-5-5`） | **第 4 次尝试（异构修复 2）**：当 `RESCUE-1` 修复后仍有问题时接手最终修复；若第 4 次仍失败 → `BLOCKED` 等人工审核 |

---

## 3. 本地环境基线与人工一次性前置条件

### 已验证的本机环境
- **OS / 架构**：macOS 26.5 (`arm64`)
- **工具链**：Apple Command Line Tools + **Swift 6.3.1**（无 Xcode.app）
- **测试框架**：**强制使用 Swift Testing（`import Testing`）**（本机 CLT 无 `XCTest.framework`，严禁 `import XCTest`）
- **性能工具**：`/usr/bin/footprint`、`top`、CoreAudio / CoreMediaIO 系统查询

### 人工一次性前置准备（约 30 秒，Iteration 0 前完成一次即可）
为避免每次重建 `ad-hoc` 签名变化导致 macOS TCC 权限与 Keychain 反复失效，请在「钥匙串访问」创建一张本机自签名代码签名证书：
1. 打开 **钥匙串访问（Keychain Access）** → 顶部菜单 **证书助理 → 创建证书…**
2. 名称填写：**`DabaiPet Local Dev`**
3. 身份类型：**自签名根证书**；证书类型：**代码签名（Code Signing）**
4. 点击创建完成（存入「登录」钥匙串即可）。后续 `scripts/build_app.sh` 将固定使用该证书签名。

---

## 4. 标准构建与验收命令

```bash
swift build                                 # 编译全部 target
./scripts/test.sh                           # 调用 swift test，补齐本机 CLT 的框架与运行库搜索路径
./scripts/build_app.sh                      # 编译并自签名生成 dist/DabaiPet.app
./scripts/verify_gate.sh                    # 硬门禁脚本（退出码 0 才算过关）
open dist/DabaiPet.app                      # 真机运行（严禁直接执行裸二进制做权限测试）
```
