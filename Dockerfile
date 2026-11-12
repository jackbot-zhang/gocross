# =============================================================================
# 基础镜像（Ubuntu 18.04 + versions.conf 里声明的所有 Go 版本）
#
# 目的：本地新系统编译出的二进制在线上老系统运行时报
#       "GLIBC_2.34 not found"。本镜像把编译环境固定在 Ubuntu 18.04
#       （glibc 2.27），产出的二进制对线上环境（glibc >= 2.27）兼容。
#
# 由 goenv.sh 构建一次后长期复用；项目每次编译只在其上叠加一层
# （Dockerfile.project-env），不重复安装工具链和 Go。
#
# 改了本文件后必须重建： ./goenv.sh apply --force
# =============================================================================
ARG BASE_IMAGE=ubuntu:18.04

FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# -----------------------------------------------------------------------------
# 1. 切换 apt 源
#    Ubuntu 18.04 已 EOL：官方源会 404，阿里云镜像仍保留 bionic 归档。
#    如果你的网络/内网有可用源，改这一行即可。
# -----------------------------------------------------------------------------
RUN sed -i 's@//.*archive.ubuntu.com@//mirrors.aliyun.com@g; s@//security.ubuntu.com@//mirrors.aliyun.com@g' \
        /etc/apt/sources.list \
    && apt-get update

# -----------------------------------------------------------------------------
# 2. C/C++ 工具链 + cgo 项目常用 C 库
#    - 不依赖 cgo 的项目：CGO_ENABLED=0，这些库不会被用到
#    - 依赖 cgo 的项目：常见依赖（openssl/sqlite3/zlib/bz2/lzma/curl/libxml2/
#      libuuid/libzmq 等）已预装，直接 CGO_ENABLED=1 编译即可
#    项目还需要其他库时，在下面这份列表里加，然后 ./goenv.sh apply --force
# -----------------------------------------------------------------------------
RUN apt-get install -y --no-install-recommends \
        ca-certificates curl wget git tar xz-utils unzip zip \
        gcc g++ make pkg-config \
        libssl-dev libsqlite3-dev zlib1g-dev libbz2-dev liblzma-dev \
        libcurl4-openssl-dev libxml2-dev uuid-dev libzmq3-dev \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 3. 安装多个 Go 版本，每个版本独立目录：
#      /opt/go/go<版本>/bin/go
#    每个项目用哪个版本由 Dockerfile.project-env 通过 GOROOT 指定，不靠 PATH，
#    这样切换版本是显式的，不会被 go 的工具链自动切换规则干扰。
#
#    GO_VERSIONS / GO_DEFAULT 由 goenv.sh 按 versions.conf 传入，这里不写默认值，
#    漏传会直接构建失败，避免出现"文档/默认值比清单新"的情况
# -----------------------------------------------------------------------------
ARG GO_VERSIONS
ARG GO_DIST_MIRRORS
ARG GOPROXY=https://goproxy.cn,direct

COPY install-go.sh /usr/local/bin/install-go.sh
RUN chmod +x /usr/local/bin/install-go.sh \
    && GO_DIST_MIRRORS="${GO_DIST_MIRRORS}" install-go.sh ${GO_VERSIONS} \
    && ls -d /opt/go/*

# 镜像默认版本 = versions.conf 里 GO_VERSIONS 的第一项（由 goenv.sh 传入）
ARG GO_DEFAULT
ENV GOROOT=/opt/go/go${GO_DEFAULT}
ENV PATH=${GOROOT}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV GOPATH=/root/go
ENV GOBIN=/root/go/bin
ENV GOPROXY=${GOPROXY}
ENV GOFLAGS=-mod=mod
ENV CGO_ENABLED=1

# 记录构建时的版本信息，便于 docker inspect 排查
ENV GOCROSS_BASE_IMAGE=${BASE_IMAGE}
ENV GOCROSS_GO_VERSIONS=${GO_VERSIONS}

WORKDIR /workspace

CMD ["/bin/bash"]
