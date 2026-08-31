# journal 的建置入口 —— 目前只有 console 需要建置（Go＋React，2026-08-31 拍板
# 對齊 canopy 模式）。shell 本體（bin/journal、lib/）不需要 make。
#
#   make console   # npm build 前端 → go build 出 bin/journal-console
#
# 建置完跑 journal init --console 安裝／啟用常駐服務（腳印見 lib/common.sh，D20）。
.PHONY: console console-web console-bin

console: console-web console-bin

console-web:
	cd console/web && npm run build
	rm -rf console/server/dist && cp -r console/web/dist console/server/dist

console-bin:
	cd console/server && go vet ./... && go build -o ../../bin/journal-console .
