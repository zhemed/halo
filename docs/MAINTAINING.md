# 维护本仓库（halo 自维护分叉）

本仓库是 [halo-dev/halo](https://github.com/halo-dev/halo)（GPL-3.0）的**社区分叉**，
在自有仓库里维护定制改动并产出可部署镜像。日常使用见 [README.md](../README.md)。

---

## 1. 版本与固定点

|   项   |                   值                    |                  说明                  |
|-------|----------------------------------------|--------------------------------------|
| 上游基线  | **v2.26.1**                            | 见仓库根 `FORK_BASE`（脚本据此推导基线 tag 与基座镜像） |
| 基座镜像  | `halohub/halo:2.26`                    | 构建时以此为准，仅覆盖 `application.jar`        |
| 产出镜像  | `ghcr.io/zhemed/halo:v2.26.1-custom.1` | tag 规则 `v<版本>-custom.<序号>`           |
| 上游许可证 | GPL-3.0                                | 保留 `LICENSE` 与版权声明，见第 8 节            |
| 历史策略  | **单快照**（不含上游提交历史）                      | 因此无法 `merge`/`rebase`，升级走第 5 节       |

> 上游 v2.26.1 的 `gradle.properties` 里 `version=2.26.0-SNAPSHOT`，
> **不要**用它推导镜像 tag；一律以 `FORK_BASE` 为准。

## 2. 工具链

- 本机只需 **Docker**（构建在 JDK 容器里跑，无需本机 Java / Node）
- `docker`（含 compose 插件）、`git`、`python3`、`curl`
- 构建缓存：命名卷 `halo-gradle-cache`（首次构建会下载依赖，之后复用）

## 3. 定制点（就这一处，加别的心谨慎）

**初始化表单的用户名/密码长度下限放宽**：

|                                         位置                                         |                  上游                  |           本仓库            |
|------------------------------------------------------------------------------------|--------------------------------------|--------------------------|
| `application/src/main/resources/templates/setup.html`                              | 用户名 `minlength="4"`、密码 `minlength=5` | `2` / `1`                |
| `application/src/main/java/run/halo/app/security/preauth/SystemSetupEndpoint.java` | `@Size(min=4)` / `@Size(min=5)`      | `2` / `1`                |
| 同上 `@Schema(minLength=…)`                                                          | 4 / 5                                | 2 / 1（同步，避免接口文档与实际校验不一致） |

**保持不动的**：字符集白名单（`NAME_REGEX` / `PASSWORD_REGEX`）、`@Email`、`@URL`、`@NotBlank`、
站点标题长度限制。**两处必须同步改**，只改一处会出现"前端放行、后端拒绝"的割裂。

**另有第二处定制：上游 CI 的本地化**（见第 6 节）。

新增定制时，务必同步更新 `.dsh-build/verify.sh` 里的期望值——否则防覆盖闸门拦不住新定制。

## 4. 日常操作

### 4.0 部署（面向使用者）

仓库根的 `install.sh` 是一键部署脚本（README 首推用法）：

```bash
curl -fsSL https://raw.githubusercontent.com/zhemed/halo/main/install.sh | bash
```

行为：取 `deploy/` 下的 compose 与 env 模板 → 生成随机数据库密码 → 探测本机 IP 作为
`halo.external-url` → `docker compose up -d` → 等就绪并打印管理端地址。

**幂等**：已存在 `docker-compose.yaml` / `.env` 时跳过，不会覆盖配置与数据。
参数：`--dir`（默认 `~/halo`）、`--url`、`--port`、`--no-start`；`-h` 看帮助。
管道执行时传参用 `bash -s -- --dir /opt/halo`。

> 改脚本后请实测三件事：① 首次准备生成 `.env`（600 权限）且随机密码；② 重复执行不改 `.env`（幂等）；
> ③ 指定 `--port` 时 compose 端口被改写且 `docker compose config` 仍通过。

### 4.1 构建镜像

```bash
./.dsh-build/build.sh                 # 校验补丁 → 编译 → 回填 console 资源 → 打镜像
./.dsh-build/build.sh --no-image      # 只产出 .dsh-build/application.jar
./.dsh-build/build.sh --tag my-tag    # 指定镜像 tag
```

两个关键设计：

1. **不构建前端**：`:application:copyUiDist` 对 `:ui:doBuild` 只有 `mustRunAfter`（非 `dependsOn`），
   所以 `bootJar` 不会触发 pnpm 构建，省掉整套 Node 工具链。
2. **回填 console 资源**：正因为跳过前端构建，产物 jar 的 `ui/ui-assets/*` 会是空的（管理端白屏）。
   `build.sh` 从官方 jar 提取 `ui/` 资源回填（约 513 个文件），并强校验 `ui/console.html`
   与 `ui-assets` 数量。代价：console 前端始终是官方 v2.26.1 的版本。

### 4.2 补丁完整性自检（防覆盖闸门）

```bash
./.dsh-build/verify.sh
```

- 校验**行为标记**（模板 `minlength`、后端 `@Size`、白名单未被越改、`FORK_BASE` 与基建存在、
  CI 守卫是否配对），不是文件哈希——上游重整格式不会误报，定制行为一旦消失立即失败。
- `build.sh` 会在编译前调用它；**校验失败即终止构建**，绝不产出"看起来正常但补丁丢了"的镜像。
  仅在显式 `SKIP_VERIFY=1` 时绕过。
- `.github/workflows/verify-patch.yml` 在每次 push/PR 跑同一校验。

### 4.3 数据与备份

站点数据在部署目录的 `./halo2`（含 `keys/`、附件、备份）与 `./db`（PostgreSQL 数据）。
**备份 = 打包这两个目录**；恢复 = 放回原位后 `docker compose --env-file halo.env up -d`。

## 4.4 DSH 侧的执行闸门（任务必须先建）

本机装了一道 `PreToolUse` 钩子（`deploy/hooks/trellis-pre-tool-gate.mjs` 为仓库内副本）：
在 Trellis 项目里，**本轮若尚未建任务，任何工具调用都会被拦截**（exit 2）。

由来：2026-09-27 出现"先动手、后补任务"的违规，用户要求把只靠自觉的规则变成机器强制。

- 安装与配置见 `deploy/hooks/README.md`
- **改配置后需新开会话才生效**（钩子在会话启动时加载）
- 逃生开关：`TRELLIS_GATE=off` 或 `touch ~/.dsh/hooks/trellis-gate-disabled`
- 自测：`node ~/.dsh/hooks/trellis-pre-tool-gate.mjs --selftest`
- 运行痕迹：`~/.dsh/hooks/trellis-gate.log`

## 5. 上游升级

```bash
# 1) 取上游新版本（必须带历史：三方合并需要基线版本）
git clone https://github.com/halo-dev/halo.git /tmp/upstream-halo
git -C /tmp/upstream-halo fetch --tags          # 确保含 v2.26.1（我们的基线）

# 2) 体检：列出定制改动、上游新增文件、版本基线
./.dsh-build/upgrade.sh check /tmp/upstream-halo

# 3) 三方合并（基线 = 上游 v2.26.1 原始文件；非重叠自动合并，重叠留冲突标记）
./.dsh-build/upgrade.sh apply /tmp/upstream-halo
#    可选 BASELINE_REF=<tag|commit> 显式指定基线

# 4) 若有冲突标记：到 /tmp/upstream-halo 解冲突（标记含 ours/base/theirs 三方内容），
#    复核 diff 后把结果取回本仓库，并同步更新 FORK_BASE 与本文件第 1 节

# 5) 构建 + 临时实例验证
./.dsh-build/upgrade.sh build
```

**合并语义**：`apply` 用 `diff3` 三方合并（ours=本仓库、base=上游基线原始文件、theirs=新上游）。
改动不重叠 → 自动合并；改到同一区域 → 写标准冲突标记（`<<<<<<<` / `||||||| base` / `=======` / `>>>>>>>`），
**不会静默丢弃任何一方**。

> 早期曾用 `patch` 套补丁：实测它在上游涉及同一文件时会**整文件替换**、静默吞掉上游改动，已弃用。
> 也试过"反向套补丁反推基线"，同样会静默失败导致吞改动，故改为从上游历史取基线。

**升级检查清单**

- [ ] `check` 列出的定制改动文件在新基线上全部处理完毕
- [ ] `apply` 无"含冲突标记"，或冲突已人工解决并复核 diff
- [ ] 第 3 节的定制点与 CI 守卫（第 6 节）都已保留
- [ ] `FORK_BASE`、本文件第 1 节、基座镜像 tag 三处同步更新
- [ ] `./.dsh-build/verify.sh` 通过
- [ ] 本地构建 + 临时卷实例验证（定制行为确实生效）
- [ ] 打 tag 推送 → Actions 构建成功 → 生产实例换 tag 后再验证

## 6. 上游 CI 的本地化改动

上游 `.github/workflows/halo.yaml` 的发布作业（`docker-build-and-push`、
`build-and-publish-container-image-with-buildpacks`）在 `push to main` 时无条件执行，
但它们依赖官方 artifact 与 registry 权限，在分叉里必然失败（历史现象：每次 push 全红）。

本仓库给这两个作业加了 `github.repository == 'halo-dev/halo'` 守卫（留 `# fork-guard:` 标记）。
`test` 与 `build` 作业**保持原样**，仍跑上游全部单测与 spotless —— 这是有价值的回归网，别关掉。

升级时若上游重构该 workflow，diff3 会给冲突；请按同样方式加回守卫，否则 push 会再次全红。
`verify.sh` 会校验这两处"标记 + 真实 if 条件"是否配对。

## 7. 发布

```bash
git tag v2.26.1-custom.2
git push --follow-tags        # 触发 build-image.yml：构建 → 推 ghcr.io/zhemed/halo
```

`build-image.yml` 也可手动触发（默认只构建不推送）。

## 8. 回滚

|     场景      |                                  做法                                   |
|-------------|-----------------------------------------------------------------------|
| 新镜像有问题      | compose 里改回上一个 tag → `docker compose --env-file halo.env up -d`（数据不动） |
| 数据被改坏       | 停容器 → 用 `./halo2` 与 `./db` 的备份覆盖 → 起容器                                |
| 补丁与上游冲突无法解决 | `git revert` 该补丁提交，`verify.sh` 会提醒（它校验的是"定制在不在"，撤定制时要同步改期望值）          |

## 9. 合规边界

- 本仓库为 GPL-3.0 派生作品，**保留原许可证与版权声明**；未声称获得 Halo 官方支持或背书。
- 对外分发本仓库构建的镜像时，须同时提供对应源码 —— 即本仓库本身（保持公开即可满足）。
- 请勿使用 Halo 官方名称/标识暗示官方身份。

