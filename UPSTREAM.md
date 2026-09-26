# 上游同步记录（自维护分叉）

本仓库是 **halo-dev/halo 的社区分叉**，采用"单快照历史"维护策略。

## 当前基线

|  项   |                值                 |
|------|----------------------------------|
| 上游版本 | **v2.26.1**                      |
| 上游仓库 | https://github.com/halo-dev/halo |
| 许可证  | GPL-3.0（见 `LICENSE`，必须保留）        |
| 基座镜像 | `halohub/halo:2.26`              |
| 快照提交 | 仓库首个提交，不含上游提交历史                  |
| 分叉镜像 | `ghcr.io/zhemed/halo:<tag>`      |

## 为什么不用 merge/rebase

按维护策略，仓库**不含上游提交历史**，因此无法用 `git merge upstream/main` 自动同步。
代价换来的好处：仓库体积小、历史干净，不会被上游数千个提交淹没。

## 升级流程（以升到 2.27 为例）

```bash
# 1) 取上游新版本到临时目录（不污染本仓库）
git clone --depth 1 --branch v2.27.0 https://github.com/halo-dev/halo.git /tmp/upstream-halo

# 2) 查清本仓库相对上游改了什么（三方 diff 的关键）
python3 - <<'PY'
import filecmp, os, subprocess
UP, LOCAL = '/tmp/upstream-halo', '.'

def upstream_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'ui', 'docs', 'openspec')]
        for f in filenames:
            p = os.path.join(dirpath, f)
            out.append(os.path.relpath(p, root))
    return set(out)

up = upstream_files(UP)
changed, added, removed = [], [], []
for rel in sorted(up):
    lp = os.path.join(LOCAL, rel)
    if not os.path.exists(lp):
        removed.append(rel)
    elif not filecmp.cmp(os.path.join(UP, rel), lp, shallow=False):
        changed.append(rel)
# 本仓库额外新增的文件（我们自己的基建）
tracked = subprocess.run(['git', 'ls-files'], capture_output=True, text=True).stdout.split()
own = [p for p in tracked if p not in up]

print('=== 与上游内容不同的文件（= 我们的补丁，需迁移）===')
for p in changed: print('  M', p)
print('=== 上游有、本仓库没有的文件（上游新增）===')
for p in removed: print('  D', p)
print('=== 本仓库自有文件（基建，天然保留）===')
for p in own: print('  A', p)
PY

# 3) 迁移补丁：对上面列出的每个 `M` 文件，用新版本对应文件为基准重新应用同样的改动
#    补丁集中且量少（例如初始化表单的 minlength / @Size），手工迁移即可，改完务必构建验证

# 4) 更新本文件与构建基线，重新构建镜像验证
```

## 升级检查清单

- [ ] 三方 diff 输出的 `M` 文件全部在新基线上重新应用
- [ ] `gradle.properties` 版本号、`UPSTREAM.md` 基线、基座镜像 tag 三处同步更新
- [ ] 本地构建通过并用临时卷实例验证（改动的行为确实生效）
- [ ] 打 tag 推送，确认 Actions 构建成功、镜像可拉取
- [ ] 生产实例换镜像后再验证一次

