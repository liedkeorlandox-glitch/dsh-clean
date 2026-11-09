#!/usr/bin/env bash
# 一键安装 dsh-clean CLI + dsh-go 插件
set -euo pipefail
DSH_HOME="${DSH_HOME:-/root/.dsh}"
HERE="$(cd "$(dirname "$0")" && pwd)"

cp "$HERE/dsh-clean.sh" /usr/local/bin/dsh-clean
chmod +x /usr/local/bin/dsh-clean

mkdir -p "$DSH_HOME/dsh-go/plugins"
rm -rf "$DSH_HOME/dsh-go/plugins/local-clean"
cp -r "$HERE/plugins/local-clean" "$DSH_HOME/dsh-go/plugins/"

echo "已安装 CLI 与插件，重启 dsh-go App 生效"
