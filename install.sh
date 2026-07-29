#!/bin/sh
# install.sh —— 從這個 checkout 就地安裝
#
# 刻意很薄：真正的納管邏輯全在 `journal init`（十一步、皆冪等），這裡只是讓你
# 不必先知道 CLI 在哪。引數原樣轉交：
#   ./install.sh                    # 完整精靈（deploy key、provider、hook、timer、自檢）
#   ./install.sh --local            # 只做離線部分
#   ./install.sh --role aggregator  # 指定這台當聚合者
# 新機器連 clone 都不想手動的話，用 journal-bootstrap.sh。

set -u

_dir=$( CDPATH='' cd -P "$(dirname "$0")" && pwd )
exec "$_dir/bin/journal" init "$@"
