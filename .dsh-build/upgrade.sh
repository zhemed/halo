#!/usr/bin/env bash
# 上游升级 SOP：把本仓库的定制补丁迁移到新的上游版本
#
#   ./.dsh-build/upgrade.sh check  [上游仓库路径]   # 只体检：列出定制改动文件、与上游的版本差距
#   ./.dsh-build/upgrade.sh apply  [上游仓库路径]   # 三方合并：非重叠自动合并，重叠留冲突标记
#   ./.dsh-build/upgrade.sh build                   # 构建镜像并给出临时实例验证命令
#
# 典型流程（升级到 v2.27.0）：
#   1) git clone --depth 1 --branch v2.27.0 https://github.com/halo-dev/halo.git /tmp/upstream-halo
#   2) ./.dsh-build/upgrade.sh check /tmp/upstream-halo      # 确认哪些文件是我们改的、上游改了哪些
#   3) ./.dsh-build/upgrade.sh apply /tmp/upstream-halo      # 机械迁移，冲突文件会留下 .rej 与备份
#   4) 处理 .rej（若有）→ ./.dsh-build/upgrade.sh build     # 构建 + 临时实例验证
#   5) 更新 FORK_BASE 与 UPSTREAM.md → 提交 → 打 tag 发版
#
# 原理：本仓库采用"单快照历史"，无法 git merge；因此用三方 diff：
#   改动检测  = 上游 pristine 版本 vs 本仓库（自身文件不在对比集合内，天然排除）
#   三方合并  = diff3(ours=我们, base=反推基线, theirs=新上游)，非重叠自动合并、重叠留冲突标记
#
# ⚠️ apply 的前置要求：上游仓库必须是"带历史"的完整 clone（含我们分叉时的版本），
#   因为三方合并需要基线版本；脚本默认用 FORK_BASE 推出的 tag（如 v2.26.1），
#   也可用 BASELINE_REF=<tag|commit> 覆盖。浅克隆（--depth 1 且不含该 tag）会导致取不到基线。
#
# 行为说明：非重叠改动自动合并；两边改到同一区域时写入标准冲突标记
#   <<<<<<< ours / ||||||| base / ======= / >>>>>>> theirs
#   并计入"含冲突标记"，需人工解冲突后再继续。
#
# 安全约束：所有改动都发生在 [上游仓库路径] 内；本仓库只在 build 步骤被动使用。

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # 本仓库根
CMD="${1:-}"
UPSTREAM="${2:-}"

SKIP_DIRS='.git|build|node_modules|.gradle|.dsh-build|dist|ui|docs|openspec'

files_of() {
  find "$1" -type f \
    -not -path "*/.git/*" \
    -not -path "*/build/*" -not -path "*/node_modules/*" \
    -not -path "*/.gradle/*" -not -path "*/dist/*" \
    -not -path "*/.dsh-build/*" -not -path "*/ui/*" \
    -not -path "*/docs/*" -not -path "*/openspec/*" \
    -printf '%P\n' 2>/dev/null | sort
}

require_upstream() {
  [ -n "$UPSTREAM" ] || { echo "用法: upgrade.sh $CMD <上游仓库路径>" >&2; exit 2; }
  [ -d "$UPSTREAM/.git" ] || { echo "不是 git 仓库: $UPSTREAM" >&2; exit 2; }
  UPSTREAM="$(cd "$UPSTREAM" && pwd)"
}

# 生成"上游 → 本仓库"的补丁，写入 $1（目录），并打印摘要
make_patches() {
  local out="$1" list="$2" changed=0
  mkdir -p "$out"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # 上游新增、本仓库没有的文件不算"我们的改动"，跳过
    [ -f "$SELF/$rel" ] || continue
    if diff -q "$UPSTREAM/$rel" "$SELF/$rel" >/dev/null 2>&1; then
      continue
    fi
    changed=$((changed + 1))
    mkdir -p "$out/$(dirname "$rel")"
    # 用 git diff --no-index 产出可直接 patch 的 unified diff（标签路径不参与 -p1 剥离）
    git -C "$out" diff --no-index --binary --no-color \
      "$UPSTREAM/$rel" "$SELF/$rel" > "$out/$rel.patch" 2>/dev/null || true
  done < "$list"
  echo "$changed"
}

list_changed() {
  local list="$1"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # 上游新增、本仓库不存在的文件不是定制改动（否则会被误判为"0 行差异的改动"）
    [ -f "$SELF/$rel" ] || continue
    diff -q "$UPSTREAM/$rel" "$SELF/$rel" >/dev/null 2>&1 || echo "$rel"
  done < "$list"
}

# 探测补丁的剥离层级：git diff --no-index 的路径标签随调用方式变化
# （绝对路径 → -p3；相对路径 → -p1），用干跑逐个试，取第一个可用的。
detect_strip() {
  local patch_file="$1" workdir="$2" n
  for n in 1 2 3 4 5 6; do
    if (cd "$workdir" && patch -R -F0 -p$n --dry-run --batch < "$patch_file" >/dev/null 2>&1); then
      echo "$n"; return 0
    fi
  done
  echo 3
}

case "$CMD" in
check)
  require_upstream
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  files_of "$UPSTREAM" > "$TMP/up.lst"
  echo "== 上游基线 =="
  echo "  路径    : $UPSTREAM"
  echo "  版本    : $(git -C "$UPSTREAM" describe --tags --always 2>/dev/null || echo unknown)"
  echo "  本仓库  : $(git -C "$SELF" describe --tags --always 2>/dev/null || echo unknown) / FORK_BASE=$(tr -d '\n' < "$SELF/FORK_BASE" 2>/dev/null || echo '?')"
  echo
  echo "== 需要迁移的定制改动（本仓库相对上游的差异）=="
  list_changed "$TMP/up.lst" > "$TMP/changed.lst"
  if [ -s "$TMP/changed.lst" ]; then
    while IFS= read -r rel; do
      lines=$(diff "$UPSTREAM/$rel" "$SELF/$rel" 2>/dev/null | grep -cE '^[<>]' || true)
      printf '  M %-72s (%s 行差异)\n' "$rel" "$lines"
    done < "$TMP/changed.lst"
    echo "  共 $(wc -l < "$TMP/changed.lst") 个文件"
  else
    echo "  （无：本仓库内容与上游一致）"
  fi
  echo
  echo "== 上游新增文件（本仓库没有，通常无需处理）=="
  files_of "$SELF" > "$TMP/self.lst"
  comm -23 "$TMP/up.lst" "$TMP/self.lst" | head -15 | sed 's/^/  A /'
  echo "  （仅显示前 15 个）"
  echo
  echo "下一步: ./.dsh-build/upgrade.sh apply $UPSTREAM"
  ;;

apply)
  require_upstream
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  files_of "$UPSTREAM" > "$TMP/up.lst"
  list_changed "$TMP/up.lst" > "$TMP/changed.lst"
  [ -s "$TMP/changed.lst" ] || { echo "无定制改动，无需迁移"; exit 0; }

  # 基线版本：默认取本仓库 FORK_BASE 对应的上游 tag
  BASELINE_REF="${BASELINE_REF:-v$(tr -d ' \n\r' < "$SELF/FORK_BASE")}"
  if ! git -C "$UPSTREAM" rev-parse --verify --quiet "$BASELINE_REF^{commit}" >/dev/null; then
    echo "!! 上游仓库里找不到基线版本 $BASELINE_REF" >&2
    echo "   请 clone 到该版本之后保留历史（或设置 BASELINE_REF=<commit|tag>）" >&2
    echo "   例： git -C <上游路径> fetch --tags" >&2
    exit 1
  fi
  echo "基线版本: $BASELINE_REF"

  echo
  echo "== 三方合并到上游工作区（diff3）=="
  echo "  基线 = 上游 $BASELINE_REF 的原始文件；结果 = 上游新版改动 + 我们的补丁"
  ok=0; conflict=0; skipped=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # 若上游该文件已与本仓库一致，说明上一轮已合并过，跳过
    if diff -q "$UPSTREAM/$rel" "$SELF/$rel" >/dev/null 2>&1; then
      printf '  ○ %s（与上游已一致，跳过）\n' "$rel"; skipped=$((skipped + 1)); continue
    fi

    # 1) 取基线：用上游仓库历史里的原始版本（$BASELINE_REF 指向我们分叉时的上游版本）
    mkdir -p "$(dirname "$TMP/base/$rel")"
    if ! git -C "$UPSTREAM" show "$BASELINE_REF:$rel" > "$TMP/base/$rel" 2>/dev/null; then
      printf '  ✗ %s（上游历史里取不到基线 $BASELINE_REF，请确认 clone 到该版本或指定 BASELINE_REF）\n' "$rel"
      conflict=$((conflict + 1)); continue
    fi

    # 2) diff3 三方合并：ours=本仓库改动, base=基线, theirs=新上游版本
    mkdir -p "$(dirname "$UPSTREAM/$rel")"
    if diff3 -m "$SELF/$rel" "$TMP/base/$rel" "$UPSTREAM/$rel" > "$TMP/merged" 2>/dev/null; then
      cp "$TMP/merged" "$UPSTREAM/$rel"
      printf '  ✓ %s（干净合并）\n' "$rel"; ok=$((ok + 1))
    else
      cp "$TMP/merged" "$UPSTREAM/$rel"
      printf '  ⚠ %s（有冲突标记，需人工解）\n' "$rel"; conflict=$((conflict + 1))
    fi
  done < "$TMP/changed.lst"

  echo
  echo "== 结果 =="
  echo "  干净合并 $ok / 含冲突标记 $conflict / 跳过 $skipped"
  if [ "$conflict" -gt 0 ]; then
    echo
    echo "需手工处理冲突文件里残留的合并标记："
    grep -rl -E '^(<<<<<<<|=======|>>>>>>>)' "$UPSTREAM" --exclude-dir=.git 2>/dev/null | head -10 | sed 's/^/  ! /'
  fi

  echo
  echo "== 复核：上游工作区最终结果 vs 本仓库 =="
  echo "  下方列出合并结果与本仓库的差异：这些正是"新版上游带来的变化 + 我们补丁"的合成结果。"
  echo "  确认无误后，把上游工作区的改动取回本仓库（或按冲突标记手工取舍）。"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$SELF/$rel" ] || continue
    if diff -q "$UPSTREAM/$rel" "$SELF/$rel" >/dev/null 2>&1; then
      printf '  = %s\n' "$rel"
    else
      d="$(diff "$UPSTREAM/$rel" "$SELF/$rel" 2>/dev/null | grep -E '^[<>]' || true)"
      printf '  ≠ %s（%s 行）\n' "$rel" "$(printf '%s\n' "$d" | grep -c . || echo 0)"
      printf '%s\n' "$d" | head -6 | sed 's/^/      /'
    fi
  done < "$TMP/changed.lst"
  echo
  echo "下一步:"
  echo "  1) 复核上游工作区 diff 是否符合预期（尤其模板与校验注解）"
  echo "  2) 更新 FORK_BASE 与 UPSTREAM.md 的基线记录"
  echo "  3) ./.dsh-build/upgrade.sh build   # 构建 + 临时实例验证"
  ;;

build)
  echo "== 构建镜像（产物 tag 需自行指定）=="
  TAG="${TAG:-}" "$SELF/.dsh-build/build.sh"
  echo
  echo "== 临时实例验证（用完删除，不影响生产）=="
  cat <<'EOS'
  mkdir -p /tmp/halo-probe && \
  docker run -d --name halo-probe -p 8091:8090 -v /tmp/halo-probe:/root/.halo2 <镜像tag>
  # 等就绪后验证定制行为，例如：
  curl -s http://127.0.0.1:8091/system/setup | grep -oE 'minlength="[0-9]+"' | sort -u
  curl -s -o /dev/null -D - http://127.0.0.1:8091/system/setup | grep -iE '^(HTTP|location)'
  docker rm -f halo-probe && rm -rf /tmp/halo-probe
EOS
  ;;

*)
  sed -n '2,20p' "$0"
  exit 2
  ;;
esac
