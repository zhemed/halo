# Halo（自维护分叉）

自用的 [Halo](https://github.com/halo-dev/halo) 分叉：基于上游 **v2.26.1** 快照，改了初始化表单的
用户名/密码长度下限，其余与上游一致。镜像 `ghcr.io/zhemed/halo`。

## 部署

```bash
curl -fsSL https://raw.githubusercontent.com/zhemed/halo/main/install.sh | bash
```

装到 `~/halo`：自动生成数据库密码、探测本机 IP 作为访问地址、拉起 Halo + PostgreSQL，
完成后打印管理端地址（首次进入初始化向导）。**幂等**，重复执行不会覆盖已有配置与数据。

想指定目录/地址/端口，或先看脚本再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/zhemed/halo/main/install.sh
less install.sh && bash install.sh --dir /opt/halo --url http://10.0.0.91:8090/
```

<details>
<summary>不想用脚本，手工三步</summary>

```bash
mkdir -p ~/halo && cd ~/halo
curl -fsSLO https://raw.githubusercontent.com/zhemed/halo/main/deploy/docker-compose.yaml
curl -fsSLO https://raw.githubusercontent.com/zhemed/halo/main/deploy/halo.env.example
cp halo.env.example halo.env && chmod 600 halo.env    # 改掉里面的数据库密码
docker compose --env-file halo.env up -d
```

</details>

数据在部署目录的 `./halo2`（站点数据）与 `./db`（数据库）。**升级**：在部署目录里改
`docker-compose.yaml` 的镜像 tag，然后 `docker compose up -d`，数据不动。

## 自检

```bash
./.dsh-build/verify.sh      # 定制补丁是否还在（防被上游覆盖）
```

其余（构建、发版、上游升级、回滚、合规）：[docs/MAINTAINING.md](./docs/MAINTAINING.md)
