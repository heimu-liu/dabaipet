#!/bin/bash
# Run the human portions of S1, S2 and S3 in sequence.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .local-evidence/spikes
run=$(mktemp -d "$PWD/.local-evidence/spikes/manual-XXXXXX")
printf '本次实测记录在 %s\n' "$run"
echo '麦克风权限窗口出现时，可选择允许或跳过。在另一应用点空白输入框，间歇敲几个普通键。仅统计次数。'
s1_status=0
python3 scripts/spike_s1.py --ask-microphone --seconds 15 --out "$run/s1" || s1_status=$?
if [[ $s1_status != 0 ]]; then
    # The known A→B Keychain failure is independent of mouse and IME testing.
    # Proceed only after the expected canonical app has been restored.
    python3 - "$run/s1/summary.json" <<'PYTHON'
import json, sys
with open(sys.argv[1]) as file:
    result = json.load(file)
if result.get("restoredCanonicalSignature") is not True or result.get("deleteStatus") != 0:
    sys.exit("S1 did not confirm bundle restoration and disposable item cleanup")
PYTHON
    echo 'S1 未通过，已恢复签名包并清理临时条目。继续独立的窗口测试。'
fi
echo '在大白上右键可打开聊天、翻滚或结束探针。切换到中文拼音后输入 nihao，按两次回车。'
open -W -n "$PWD/dist/DabaiPet.app" --args --spike-interaction --out "$run/interaction.json"
test -s "$run/interaction.json"
printf '操作记录已保存至 %s\n' "$run"
exit "$s1_status"
