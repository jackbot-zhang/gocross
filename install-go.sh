#!/bin/sh
# =============================================================================
# 在镜像内安装一个或多个 Go 版本，每个版本独立目录 /opt/go/go<version>
#
# 用法: install-go.sh <版本> [<版本>...]
#
# 说明：
#   - 下载源由 GO_DIST_MIRRORS 指定，依次尝试，任一成功即可
#   - GO_SHA256 不为空时校验；默认不校验
#   - 已安装的版本目录直接跳过
# =============================================================================
set -eu

GOROOT_BASE=/opt/go
GO_DIST_MIRRORS=${GO_DIST_MIRRORS:-"https://golang.google.cn/dl https://go.dev/dl https://mirrors.aliyun.com/golang"}
TARGET_ARCH=${TARGET_ARCH:-amd64}

[ "$#" -gt 0 ] || { echo "usage: $0 <go-version>..." >&2; exit 1; }

mkdir -p "$GOROOT_BASE"

for ver in "$@"; do
    dest="${GOROOT_BASE}/go${ver}"
    if [ -x "${dest}/bin/go" ]; then
        echo "==> go${ver} already installed, skip"
        continue
    fi

    tarball="go${ver}.linux-${TARGET_ARCH}.tar.gz"
    tmp="/tmp/${tarball}"
    ok=0

    for mirror in $GO_DIST_MIRRORS; do
        echo "==> downloading ${tarball} from ${mirror}"
        if curl -fsSL --retry 2 --connect-timeout 10 "${mirror}/${tarball}" -o "$tmp"; then
            ok=1
            break
        fi
    done

    [ "$ok" = 1 ] || { echo "!! failed to download go${ver}" >&2; exit 1; }

    # 可选校验
    if [ -n "${GO_SHA256:-}" ]; then
        echo "${GO_SHA256}  ${tmp}" | sha256sum -c - >/dev/null \
            || { echo "!! sha256 mismatch for go${ver}" >&2; exit 1; }
    fi

    mkdir -p "$dest"
    tar -C "$dest" --strip-components=1 -xzf "$tmp"
    rm -f "$tmp"

    # 记录来源，便于排查
    printf 'version=%s\narch=%s\ndate=%s\n' "$ver" "$TARGET_ARCH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "${dest}/.gocross-installed"

    "${dest}/bin/go" version
done
