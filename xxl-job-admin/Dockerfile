# Stage 1: Build the application using Maven
FROM maven:3.9.9-eclipse-temurin-21-alpine AS build

# Set the working directory
WORKDIR /workspace

COPY settings.xml /root/.m2/settings.xml

# Copy the entire project
COPY . .

# Build the project. This will build all modules.
# Skipping tests to speed up the build process.
RUN mvn -s /root/.m2/settings.xml clean package -Dmaven.test.skip=true

# Stage 2: Create the final Docker image
# FROM openjdk:21-jdk-slim

# 运行阶段
FROM eclipse-temurin:21-jre-alpine

# 设置构建参数，方便修改时区
ARG TIMEZONE=Asia/Shanghai

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 安装 tzdata 包并设置时区
RUN apk add --no-cache tzdata && \
    ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && \
    echo "${TIMEZONE}" > /etc/timezone
ENV TZ Asia/Shanghai

# Maintainer
MAINTAINER xuxueli

# Set params
ENV PARAMS=""

# Set timezone
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Copy the JAR file from the build stage to the final image
COPY --from=build /workspace/xxl-job-admin/target/xxl-job-admin-*.jar /app.jar

# Command to run the application
# log home: -e LOG_HOME=/data/applogs
# jvm options: -e JAVA_OPTS="-Xms128m -Xmx128m"
# app params: -e PARAMS="--server.port=8080"
ENTRYPOINT ["sh","-c","java ${LOG_HOME:+-DLOG_HOME=$LOG_HOME} -jar $JAVA_OPTS /app.jar $PARAMS"]
