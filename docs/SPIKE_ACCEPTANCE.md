# Iteration 0.5 真机签收

在已签名的 App 上测试。一次运行的人工作业入口为 `./scripts/spike_manual.sh`，它先检查授权，再打开桌面交互探针。记录保存在 `.local-evidence/spikes/manual-*/`。如要验证负坐标副屏，请在打开交互探针前接好显示器，并在系统显示器设置中将副屏排在内屏左侧。

| 项目 | 操作 | 通过条件 |
| --- | --- | --- |
| S1 权限与按键 | 在大白的提示框选择「请求麦克风权限」，在 macOS 弹窗允许。接下来约 30 秒在另一应用的空白输入框间歇敲几个普通键。 | 两个不同编译版本的签名要求一致，B 仍有麦克风授权，临时钥匙串值一致并清理成功。未授予辅助功能时，至少一个采样窗口观察到正按键增量。探针仅读取计数。 |
| S2 穿透与拖拽 | 把空白窗口放在大白后方，在大白透明边角点击下层窗口，然后点一下大白身体，再拖动身体。 | 下层窗口收到点击，短按身体有反馈，拖动跟手。 |
| S2 中文输入 | 右键「和大白聊聊…」，切换中文拼音，输入 nihao，按两次回车，再按 Esc。若首次测试异常，用「聊天（激活应用）…」重复。 | 候选窗随输入框出现，第一次回车确认上屏，第二次才发送，Esc 关闭。记录哪种焦点模式通过。 |
| S3 宽窗滚动 | 在内屏边缘右键「滚动一下」。有副屏时，拖到副屏再执行一次。通过菜单栏「大白探针 → 保存并退出探针」保存结果。 | 窗口扩宽、滚动、收缩时目视无闪烁、无裁切，始终在同一屏可见区域。单屏与多屏分别签收。 |

## 重跑机器采样

每次用新的输出目录。S1 会在同一应用路径轮换两份签名包，请依次运行各探针。以 `open` 启动 App 后，以本轮新生成的 JSON 及其字段裁决结果。

```sh
./scripts/verify_gate.sh
./scripts/spike_s1.py --out .local-evidence/spikes/s1-replay
open -W -n dist/DabaiPet.app --args --spike-interaction --auto --out "$PWD/.local-evidence/spikes/s3-replay.json"
./scripts/spike_s4.py .local-evidence/spikes/s4-replay
```

S4 各场景采用相同尺寸和位置，窗口就绪后预热 5 秒。内存由 footprint 查询，CPU 取 top 丢弃首帧后的 30 个样本。WindowServer 服务于整个桌面，采样期间请保持桌面工作负载稳定。每次的 `comparison.md` 和原始样本位于对应输出目录；实际结果与签收状态见 [运行看板](LOOP_STATUS.md)。

若要检查 WindowServer 背景负载漂移，运行 `./scripts/spike_s4.py --diagnostic 新目录`，它依次测量空窗、默认 CALayer、空窗。将参数换为 `--limited` 可复测请求 15 Hz 的候选动画；刷新率参数是提交给 Core Animation 的偏好，实际系统负载仍以采样为准。
