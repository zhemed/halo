# DSH PreToolUse 闸门（任务必须先建）

由 2026-09-27 的"先动手后补任务"事故引入：把仅靠自觉的规则变成机器强制。

## 安装

```bash
install -m 755 trellis-pre-tool-gate.mjs ~/.dsh/hooks/trellis-pre-tool-gate.mjs
```

然后在 `~/.dsh/hooks/trellis-hooks.json` 里注册（与既有的 `SessionStart` 同级）：

```json
{
  "PreToolUse": [
    { "hooks": [{ "type": "command",
                  "command": "/usr/bin/node /root/.dsh/hooks/trellis-pre-tool-gate.mjs",
                  "timeout": 10 }] }
  ]
}
```

## 行为

- 在项目里（cwd 向上能找到 `.trellis/`）：若**本轮**还没有建过 Trellis 任务，
  **拦截一切工具调用**（exit 2），并在理由里给出 `task.py create` 命令。
- `task.py create|start` 命令本身放行；非 Trellis 项目放行；内部错误一律放行（fail-open）。
- 逃生开关：`export TRELLIS_GATE=off`，或 `touch ~/.dsh/hooks/trellis-gate-disabled`。
- 自测：`node trellis-pre-tool-gate.mjs --selftest`

## 注意

- **钩子配置在会话启动时加载**：修改 `trellis-hooks.json` 后，需**新开会话**才生效
  （2026-09-27 实测：配置改动晚于会话启动 → 本会话不生效）。
- 判定按 `turn` 计：同一轮内建过任务后，该轮后续调用全部放行，不反复拦截。
- 运行痕迹：`~/.dsh/hooks/trellis-gate.log`（决策与理由）与
  `~/.dsh/hooks/pre-tool-fired.log`（是否真的被调用过，用于区分手工模拟）。

