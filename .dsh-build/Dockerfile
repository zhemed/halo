# 自维护分叉：构建用镜像定义
#
# 思路：以官方 Halo 镜像为基座（保留官方启动脚本、JVM 参数注入、预置 jsa、console 分层资源），
#       仅用本仓库编译出的 application.jar 覆盖同名文件，实现"官方运行时 + 我们的代码"。
#
# 构建：
#   docker build \
#     --build-arg HALO_BASE=halohub/halo:2.26 \
#     --build-arg APP_JAR=.dsh-build/application.jar \
#     -t ghcr.io/zhemed/halo:<tag> .
ARG HALO_BASE=halohub/halo:2.26
FROM ${HALO_BASE}

ARG APP_JAR=.dsh-build/application.jar
COPY ${APP_JAR} /application/application.jar

# 官方 ENTRYPOINT 保持不变：
#   sh -c 'exec java ${JVM_OPTS} -XX:SharedArchiveFile=application.jsa -jar application.jar "$@"' --
# 覆盖 jar 后 jsa 与真实类不再匹配，HotSpot 会拒绝加载并自动回退到普通启动，仅损失一点启动速度。
