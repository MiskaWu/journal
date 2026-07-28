#!/bin/sh
# install.sh —— 從這個 checkout 就地安裝
#
# 刻意很薄：真正的納管邏輯在 `journal init`，這裡只是讓你不必先知道 CLI 在哪。
# 完整的 bootstrap（新機器、clone、deploy key、provider 授權）是 P4 的
# journal-bootstrap.sh，還沒寫。

set -u

_dir=$( CDPATH='' cd -P "$(dirname "$0")" && pwd )
exec "$_dir/bin/journal" init --local "$@"
