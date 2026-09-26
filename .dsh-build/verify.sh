#!/usr/bin/env bash
# 分叉补丁完整性校验（防覆盖闸门）
#
#   ./.dsh-build/verify.sh
#
# 目的：让"我们的定制补丁被上游覆盖/丢失"这件事**无法静默发生**。
#   - build.sh 在编译前调用它：校验失败 → 构建终止，绝不产出"看起来正常但补丁没了"的镜像
#   - .github/workflows/verify-patch.yml 在每次 push/PR 上调用同一脚本
#
# 校验的是**行为标记**而非文件哈希：上游若重构格式（缩进/顺序变化），只要定制行为还在就通过；
# 一旦定制行为消失（被覆盖、被合掉、被改回默认值），立即失败。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
ok()   { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1"; FAIL=1; }

echo "== 分叉补丁完整性校验 =="

TEMPLATE="application/src/main/resources/templates/setup.html"
ENDPOINT="application/src/main/java/run/halo/app/security/preauth/SystemSetupEndpoint.java"

# --- 补丁 1：初始化表单的用户名/密码长度下限放宽 ---
[ -f "$TEMPLATE" ] || fail "缺少模板文件 $TEMPLATE"
[ -f "$ENDPOINT" ] || fail "缺少后端文件 $ENDPOINT"

if [ -f "$TEMPLATE" ]; then
  grep -qE 'name="username"' "$TEMPLATE" && grep -qE 'minlength="2"' "$TEMPLATE" \
    && ok "模板：用户名 minlength=2（定制生效）" \
    || fail "模板：用户名 minlength=2 **缺失**（补丁被覆盖？上游改回 minlength=4？）"

  # 密码两处（password + confirmPassword）都应为 1
  n=$(grep -cE "password\(.*minlength = 1," "$TEMPLATE" || true)
  [ "$n" -ge 2 ] && ok "模板：密码 minlength=1 出现 $n 处（password + confirmPassword）" \
    || fail "模板：密码 minlength=1 仅出现 $n 处（应为 2）"
fi

if [ -f "$ENDPOINT" ]; then
  grep -qE '@Size\(min = 2, max = 63\)' "$ENDPOINT" \
    && ok "后端：用户名 @Size(min=2)（定制生效）" \
    || fail "后端：用户名 @Size(min=2) **缺失**（补丁被覆盖？上游改回 min=4？）"

  grep -qE '@Size\(min = 1, max = 257\)' "$ENDPOINT" \
    && ok "后端：密码 @Size(min=1)（定制生效）" \
    || fail "后端：密码 @Size(min=1) **缺失**"
fi

# --- 反向校验：应当保留的约束不能被顺手去掉 ---
if [ -f "$ENDPOINT" ]; then
  grep -qE 'Pattern\(regexp = ValidationUtils\.NAME_REGEX' "$ENDPOINT" \
    && ok "后端：用户名字符集白名单仍在（未越改）" \
    || fail "后端：用户名字符集白名单丢失（超出定制范围）"
  grep -qE 'Pattern\(regexp = ValidationUtils\.PASSWORD_REGEX' "$ENDPOINT" \
    && ok "后端：密码字符集白名单仍在（未越改）" \
    || fail "后端：密码字符集白名单丢失（超出定制范围）"
fi

# --- 补丁 2：上游发布作业的本地化守卫（分叉无权推送官方 registry）---
# 校验方式：找 fork-guard 标记，要求紧随其后的 if 行真的带官方仓库守卫。
# 只查标记存在是不够的——标记留着、守卫被删的情况必须能被抓到。
UPSTREAM_WF=".github/workflows/halo.yaml"
if [ -f "$UPSTREAM_WF" ]; then
  guard_ok=$(python3 - "$UPSTREAM_WF" <<'PYEOF'
import sys, pathlib
lines = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
good = bad = 0
for i, ln in enumerate(lines):
    if '# fork-guard:' not in ln:
        continue
    for nxt in lines[i + 1:i + 4]:
        s = nxt.strip()
        if not s:
            continue
        if s.startswith('if:') and "github.repository == 'halo-dev/halo'" in s:
            good += 1
        else:
            bad += 1
        break
print(f'{good} {bad}')
PYEOF
)
  good="${guard_ok%% *}"; bad="${guard_ok##* }"
  if [ "$good" -ge 2 ] && [ "$bad" -eq 0 ]; then
    ok "上游 CI：$good 处发布作业守卫标记都与真实守卫条件配对"
  else
    fail "上游 CI：守卫不完整（配对 $good 处 / 未配对 $bad 处）。标记存在但 if 条件缺少 \`github.repository == 'halo-dev/halo'\` 时会命中此项。"
  fi
fi

# --- 基线声明存在，便于升级时不迷失 ---
[ -f FORK_BASE ] && ok "基线文件 FORK_BASE = $(tr -d '\n' < FORK_BASE)" \
  || fail "缺少 FORK_BASE（升级流程依赖它推导基线，见 docs/MAINTAINING.md）"

# --- 构建链路声明存在 ---
for f in .dsh-build/Dockerfile .dsh-build/build.sh .dsh-build/upgrade.sh docs/MAINTAINING.md; do
  [ -f "$f" ] && ok "维护基建存在：$f" || fail "缺少维护基建：$f"
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "结论：定制补丁完整 ✅"
else
  echo "结论：定制补丁**不完整** ❌ —— 见上方 ✗ 项。"
  echo "常见原因：升级时直接覆盖了文件、或 diff3 合并冲突被草率解决。"
  echo "处理办法：对照 docs/MAINTAINING.md 重新套用补丁，或在冲突标记处明确取舍后重跑本校验。"
fi
exit "$FAIL"
