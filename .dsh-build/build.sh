#!/usr/bin/env bash
# 自维护分叉的一键构建脚本
#
#   ./build.sh                     # 编译 + 合并 console 资源 + 打镜像
#   ./build.sh --no-image          # 只产出 .dsh-build/application.jar
#   ./build.sh --tag mytag         # 指定镜像 tag
#
# 关键设计：从官方 jar 提取 console 前端资源（ui/ 目录）回填进我们编译的 jar。
# 原因：:application:copyUiDist 会把 ui/build/dist 复制进 jar；若未构建前端，
#       产物 jar 的 ui/ 只有壳（console.html 引用的 ui-assets 缺失），管理端会白屏。
# 这样做的收益：CI 里完全不需要 Node/pnpm，构建时间和不确定性都大幅下降。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f gradle.properties ] || { echo "构建根目录判定失败: $ROOT 下没有 gradle.properties" >&2; exit 1; }

# 版本基线：以仓库根的 FORK_BASE 为准（上游 tag 内 gradle.properties 常为 x.y.0-SNAPSHOT，
# 直接用它会推出错误的基座镜像 tag，进而拉不到镜像）
VERSION="$(tr -d ' \n\r' < "$ROOT/FORK_BASE" 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "缺少版本基线文件 FORK_BASE" >&2; exit 1; }
HALO_BASE="${HALO_BASE:-halohub/halo:${VERSION%.*}}"
JDK_IMAGE="${JDK_IMAGE:-eclipse-temurin:21-jdk}"
OFFICIAL_JAR="${OFFICIAL_JAR:-.upstream-official.jar}"
OUT_DIR="$ROOT/.dsh-build"
REV="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
TAG="${TAG:-v${VERSION}-custom.${REV}}"

MAKE_IMAGE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-image) MAKE_IMAGE=0; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

# 前置闸门：补丁不完整就不构建（避免产出"看起来正常但定制丢失"的镜像）
"$ROOT/.dsh-build/verify.sh" || {
  echo >&2
  echo "构建终止：定制补丁校验未通过。若确实需要临时绕过，请显式设置 SKIP_VERIFY=1。" >&2
  [ "${SKIP_VERIFY:-0}" = "1" ] || exit 1
  echo "警告：已按 SKIP_VERIFY=1 绕过校验，产物可能不符合分叉预期。" >&2
}

echo "== 分叉构建 =="
echo "  源码版本 : $VERSION (commit $REV)"
echo "  基座镜像 : $HALO_BASE"
echo "  镜像 tag : $TAG"

# ---------- 1. 准备官方 jar（用于提取 console 资源） ----------
if [ ! -f "$OFFICIAL_JAR" ]; then
  echo "== 下载官方 jar（$HALO_BASE）=="
  CID="$(docker create "$HALO_BASE")"
  trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
  docker cp "$CID:/application/application.jar" "$OFFICIAL_JAR"
  docker rm -f "$CID" >/dev/null
  trap - EXIT
fi
echo "  官方 jar : $OFFICIAL_JAR ($(du -h "$OFFICIAL_JAR" | cut -f1))"

# ---------- 2. Gradle 编译（不构建前端，不需要 Node） ----------
echo "== 编译（:application:bootJar -x test）=="
docker run --rm -v "$ROOT":/src -v halo-gradle-cache:/root/.gradle -w /src "$JDK_IMAGE" \
  ./gradlew :application:bootJar -x test --no-daemon

BUILT="$(ls -1 application/build/libs/halo-*.jar 2>/dev/null | head -1 || true)"
[ -n "$BUILT" ] || { echo "未找到构建产物 application/build/libs/halo-*.jar" >&2; exit 1; }
echo "  编译产物 : $BUILT"

# ---------- 3. 回填 console 前端资源并定稿 jar ----------
echo "== 回填 console 资源（ui/）=="
mkdir -p "$OUT_DIR"
python3 - "$OFFICIAL_JAR" "$BUILT" "$OUT_DIR/application.jar" <<'PY'
import shutil, sys, zipfile

official, built, dest = sys.argv[1], sys.argv[2], sys.argv[3]
src = zipfile.ZipFile(official)
ui = [n for n in src.namelist() if n == 'ui/' or n.startswith('ui/')]
print(f'  官方 jar 中 ui/ 条目: {len(ui)}')

shutil.copyfile(built, dest)
with zipfile.ZipFile(dest, 'a', zipfile.ZIP_DEFLATED) as z:
    names = set(z.namelist())
    added = 0
    for n in ui:
        if n.endswith('/'):
            continue
        # 以官方资源为准覆盖（这些文件我们不做修改）
        data = src.read(n)
        if n in names:
            zi = zipfile.ZipInfo(n, date_time=(1980, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
        else:
            z.writestr(n, data)
        added += 1
    print(f'  回填文件数: {added}')
print(f'  定稿 jar: {dest} ({__import__("os").path.getsize(dest)/1048576:.1f} MB)')
PY

# 完整性校验：确认 console 入口与资源都在
python3 - "$OUT_DIR/application.jar" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = set(z.namelist())
assets = [n for n in names if n.startswith('ui/ui-assets/')]
assert 'ui/console.html' in names, '缺少 ui/console.html'
assert len(assets) > 100, f'ui-assets 数量异常: {len(assets)}'
print(f'  校验通过: console.html 存在, ui-assets {len(assets)} 个')
PY

# ---------- 4. 打镜像 ----------
if [ "$MAKE_IMAGE" = "1" ]; then
  echo "== 打镜像: $TAG =="
  docker build \
    --build-arg HALO_BASE="$HALO_BASE" \
    --build-arg APP_JAR=.dsh-build/application.jar \
    -f "$OUT_DIR/Dockerfile" \
    -t "$TAG" \
    "$ROOT"
  echo
  echo "镜像已生成: $TAG"
  echo "试运行验证:  docker run --rm -p 8091:8090 -v /tmp/halo-probe:/root/.halo2 $TAG"
fi
