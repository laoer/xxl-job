# ---------------------------------------------------------------------------
# XXL-JOB Admin 镜像
#
# 构建上下文：仓库根目录
#   Jenkinsfile: docker buildx build --platform linux/arm64 --file xxl-job-admin/Dockerfile . --load
# 前置条件：构建前需在上下文根目录存在 settings.xml（Jenkins 的
#   "Prepare Maven Settings" 阶段用 maven-settings 凭据写入）
#
# 跨平台说明（重要）：
#   Jenkins 以 `--platform linux/arm64` 构建，而构建机通常是 x86_64。构建机上若没有
#   QEMU binfmt 支持，任何在“目标平台”上执行的 RUN 都会报
#   `exec /bin/sh: exec format error`。因此本 Dockerfile 的约定是：
#     - 构建阶段固定跑在构建机原生平台（FROM --platform=$BUILDPLATFORM），编译不依赖 QEMU；
#     - 运行阶段（目标平台）只使用 COPY/ENV/EXPOSE/ENTRYPOINT，不执行任何 RUN 指令，
#       时区数据在构建阶段安装后 COPY 进运行阶段。
#   如果以后需要在运行阶段执行 RUN（apk/apt 装包、健康检查脚本等），构建机必须装 binfmt：
#     docker run --privileged --rm tonistiigi/binfmt --install arm64
# ---------------------------------------------------------------------------

# ===== 阶段 1：构建（构建机原生平台，不经过 QEMU）=====
FROM --platform=$BUILDPLATFORM maven:3.9.9-eclipse-temurin-21-alpine AS build

ARG TIMEZONE=Asia/Shanghai

WORKDIR /workspace

# Maven 私服配置
COPY settings.xml /root/.m2/settings.xml

# 复制源码（.dockerignore 已排除 .git、各模块 target/、doc 等）
COPY . .

# 只构建调度中心及其依赖模块（比全量构建快，且不受样例模块影响）；
# 跳过测试与 sources/javadoc 包：父 POM 默认把这两个插件绑在 package 阶段，
# 否则 target 下会出现 xxl-job-admin-<version>.jar / -sources.jar / -javadoc.jar 三个 jar。
RUN mvn -s /root/.m2/settings.xml -B -ntp \
        -pl xxl-job-admin -am \
        clean package \
        -Dmaven.test.skip=true \
        -Dmaven.source.skip=true \
        -Dmaven.javadoc.skip=true

# 精确取出可执行 jar：避免 "COPY *.jar /app.jar" 在通配符匹配到多个文件时报
# "must be a directory"（sources/javadoc 包即使被跳过，这里也再兜底一次）
RUN set -eu; \
    jar="$(ls -1 xxl-job-admin/target/xxl-job-admin-*.jar \
        | grep -v -e '-sources\.jar$' -e '-javadoc\.jar$' \
        | head -n 1)"; \
    test -n "$jar"; \
    cp "$jar" /app.jar; \
    ls -l /app.jar

# 时区数据：在本阶段（原生平台）安装，供运行阶段直接 COPY，
# 这样运行阶段就不需要 apk（否则在无 QEMU 的构建机上会 exec format error）
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories && \
    apk add --no-cache tzdata && \
    cp -L "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime.prepared && \
    echo "${TIMEZONE}" > /etc/timezone.prepared

# ===== 阶段 2：运行（目标平台，全部为 COPY/ENV，不执行任何 RUN）=====
FROM eclipse-temurin:21-jre-alpine

# 时区（--build-arg TIMEZONE=xxx 可覆盖）
ARG TIMEZONE=Asia/Shanghai
ENV TZ=${TIMEZONE}

# 从构建阶段复制时区数据（zoneinfo 是架构无关的数据文件）
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=build /etc/localtime.prepared /etc/localtime
COPY --from=build /etc/timezone.prepared /etc/timezone

# Maintainer
MAINTAINER xuxueli

# Set params
ENV PARAMS=""

# 可执行 jar（构建阶段已确认唯一）
COPY --from=build /app.jar /app.jar

# expose port
EXPOSE 8080

# Command to run the application
# log home: -e LOG_HOME=/data/applogs
# jvm options: -e JAVA_OPTS="-Xms128m -Xmx128m"
# app params: -e PARAMS="--server.port=8080"
ENTRYPOINT ["sh","-c","java ${LOG_HOME:+-DLOG_HOME=$LOG_HOME} -jar $JAVA_OPTS /app.jar $PARAMS"]
