# Halo（自维护分叉）

自用的 [Halo](https://github.com/halo-dev/halo) 分叉：基于上游 **v2.26.1** 快照，改了初始化表单的
用户名/密码长度下限，其余与上游一致。镜像 `ghcr.io/zhemed/halo`。

## 部署

```bash
mkdir -p ~/halo && cd ~/halo

curl -fsSLO https://raw.githubusercontent.com/zhemed/halo/main/deploy/docker-compose.yaml
curl -fsSLO https://raw.githubusercontent.com/zhemed/halo/main/deploy/halo.env.example
cp halo.env.example halo.env && chmod 600 halo.env    # 改掉里面的数据库密码

docker compose --env-file halo.env up -d
```

数据在 `./halo2`（站点数据）与 `./db`（数据库）；管理端 `http://<主机>:8090/console`
（首次进入初始化向导）。**升级**：改 compose 里的镜像 tag 后
`docker compose --env-file halo.env up -d`，数据不动。

## 自检

```bash
./.dsh-build/verify.sh      # 定制补丁是否还在（防被上游覆盖）
```

其余（构建、发版、上游升级、回滚、合规）：[docs/MAINTAINING.md](./docs/MAINTAINING.md)
