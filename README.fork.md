> ⚠️ **这是社区分叉（fork），不是 Halo 官方仓库。**
> 上游项目：<https://github.com/halo-dev/halo>（GPL-3.0）。原 `README.md` 内容见
> [`README.upstream.md`](README.upstream.md)。本文件说明本仓库的维护方式。

# halo（自维护分叉）

在自有仓库里维护对 Halo 的定制改动，并产出可直接部署的镜像。

## 仓库形态

|  项   |                          值                           |
|------|------------------------------------------------------|
| 上游版本 | **v2.26.1**（见 [`UPSTREAM.md`](UPSTREAM.md)）          |
| 历史策略 | **单快照提交**：只含 v2.26.1 的完整快照，不含上游提交历史                  |
| 升级方式 | 三方 diff 手工迁移（不使用 `merge`/`rebase`），流程见 `UPSTREAM.md` |
| 镜像产物 | `ghcr.io/zhemed/halo:v<版本>-custom.<短 commit>`        |
| 许可证  | GPL-3.0（保留 `LICENSE` 与版权声明；分发镜像须提供对应源码 = 本仓库）        |

## 目录约定

```
.dsh-build/
  Dockerfile      # 以官方镜像为基座，仅覆盖编译出的 application.jar
  build.sh        # 一键构建：编译后端 → 回填 console 资源 → 打镜像
.github/workflows/build-image.yml   # 打 tag 自动构建并推 ghcr.io
UPSTREAM.md       # 上游基线 + 升级流程 + 三方 diff 脚本
```

> 定制改动**直接改上游源文件**（例如初始化表单的模板与校验注解），
> 不使用 `patches/` 目录 —— 因为单快照策略下，改动清单由 `UPSTREAM.md` 里的三方 diff 脚本自动列出。

## 本地构建

```bash
# 只需要 Docker（无需本机 Java/Node）
./.dsh-build/build.sh                 # 产出 .dsh-build/application.jar 并打镜像
./.dsh-build/build.sh --no-image      # 只产出 jar
./.dsh-build/build.sh --tag my-tag    # 指定镜像 tag
```

构建原理与两个关键取舍：

1. **不构建前端**：`:application:copyUiDist` 只把 `ui/build/dist` 复制进 jar，且对 `:ui:doBuild`
   只有 `mustRunAfter`（不是 `dependsOn`），所以 `bootJar` 不会触发 pnpm 构建 —— 省掉整套 Node 工具链。
2. **回填 console 资源**：正因为跳过了前端构建，产物 jar 的 `ui/ui-assets/*` 会是空的（管理端白屏）。
   脚本从**官方 jar**（基座镜像内）提取 `ui/` 资源回填，并强校验 `ui/console.html` 与 `ui-assets` 数量。
   代价：console 前端资源与官方 v2.26.1 保持一致，不接受我们自己的前端改动。

## 部署（docker-compose）

```yaml
services:
  halo:
    image: ghcr.io/zhemed/halo:v2.26.1-custom.<短commit>
    # 其余配置与官方示例一致：端口 8090、卷 ./halo2:/root/.halo2、PostgreSQL 连接参数
```

数据目录、端口、数据库参数与官方镜像**完全兼容**，换镜像不需要迁移数据。

## 发布流程

```bash
git tag v2.26.1-custom.1
git push --follow-tags        # 触发 Actions：构建 → 推 ghcr.io/zhemed/halo
```

## 与上游的关系（合规）

- 本仓库为 GPL-3.0 派生作品，**保留原许可证与版权声明**，未声称获得 Halo 官方支持或背书。
- 若对外分发本仓库构建的镜像，须同时提供对应源码 —— 即本仓库本身（保持公开即可满足）。
- 请勿使用 Halo 官方名称/标识暗示官方身份。

