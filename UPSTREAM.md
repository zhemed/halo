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

已脚本化：`.dsh-build/upgrade.sh`（check / apply / build）。

```bash
# 1) 取上游新版本（必须带历史：三方合并需要基线版本）
git clone https://github.com/halo-dev/halo.git /tmp/upstream-halo
git -C /tmp/upstream-halo fetch --tags          # 确保含 v2.26.1（我们的基线）

# 2) 体检：列出本仓库的定制改动、上游新增文件、版本基线
./.dsh-build/upgrade.sh check /tmp/upstream-halo

# 3) 三方合并：基线取上游 v2.26.1 的原始文件，非重叠自动合并、重叠留冲突标记
./.dsh-build/upgrade.sh apply /tmp/upstream-halo
#    可选：BASELINE_REF=<tag|commit> 显式指定基线版本

# 4) 若报"含冲突标记"，到 /tmp/upstream-halo 里解冲突（标记含 ours/base/theirs 三方内容）
#    解完并复核 diff 后，把结果取回本仓库，同步更新 FORK_BASE 与本文档基线

# 5) 构建并用临时实例验证
./.dsh-build/upgrade.sh build
```

### 合并语义说明

`apply` 采用 `diff3` 三方合并（ours=本仓库、base=上游基线的原始文件、theirs=新上游版本）：

- **改动不重叠** → 自动合并，我们的补丁与上游新改动都会保留；
- **改到同一区域/同一行** → 写入标准冲突标记（`<<<<<<<` / `||||||| base` / `=======` / `>>>>>>>`），
  需人工取舍，不会静默丢弃任何一方。

> 早期版本曾用 `patch` 套补丁，实测发现它在上游改动涉及同一文件时会**整文件替换**、
> 静默吞掉上游改动；已改为 `diff3`，此风险已消除。

## 上游 CI 的本地化改动（升级时要留意）

上游 `.github/workflows/halo.yaml` 的发布作业（`docker-build-and-push`、
`build-and-publish-container-image-with-buildpacks`）在 `push to main` 时无条件执行，
但它们依赖官方 artifact 与 registry 权限，在分叉里必然失败（历史遗留：每次 push 全红）。

本仓库给这两个作业加了 `github.repository == 'halo-dev/halo'` 守卫（并留 `# fork-guard:` 标记）。
`test` / `build` 作业**保持原样**，仍会跑上游全部单测与 spotless —— 这是有价值的回归网。

> 升级时若上游重构了该 workflow，diff3 会给出冲突；请把守卫按同样方式加回，
> 否则 push 会再次全红。`verify.sh` 会校验这两处守卫是否配对，缺失即报错。

## 升级检查清单

- [ ] `check` 输出的定制改动文件，在新基线上全部确认处理完毕
- [ ] `apply` 无"含冲突标记"，或冲突已全部人工解决并复核 diff
- [ ] `FORK_BASE`、`UPSTREAM.md` 基线、基座镜像 tag 三处同步更新
- [ ] 本地构建通过，并用临时卷实例验证定制行为确实生效（如模板 minlength 值）
- [ ] 打 tag 推送，确认 Actions 构建成功、镜像可拉取
- [ ] 生产实例换镜像后再验证一次

