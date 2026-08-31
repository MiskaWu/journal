// journal-console —— 控制台的常駐伺服器（Go 版，2026-08-31 拍板對齊 canopy 模式）。
//
// 只做靜態伺服：資料語意維持零後端（瀏覽器直連 GitHub API，O9 拍板不翻案），
// 所以這支不持有任何憑證——PAT 住在使用者瀏覽器的 localStorage，爆炸半徑
// 趨近於零（D18 的同一套帳）。前端（console/web）build 後以 go:embed 進
// binary，單一執行檔部署，跟 canopy 一樣。
//
// 只綁 127.0.0.1，仍驗 Host 標頭（擋 DNS rebinding：外部網頁把自家網域解析到
// 127.0.0.1 後，瀏覽器會帶著該網域的 Host 對本機發請求）。埠號用
// JOURNAL_CONSOLE_PORT 覆寫，預設 8899。
//
// 建置：repo 根目錄 make console（先 npm build 再 go build）。
// 安裝／移除：journal init --console / --no-console（腳印見 common.sh，D20）。
package main

import (
	"embed"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
)

//go:embed all:dist
var dist embed.FS

func hostAllowed(raw string) bool {
	host := raw
	if h, _, err := net.SplitHostPort(raw); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	switch host {
	case "127.0.0.1", "localhost", "::1":
		return true
	}
	return false
}

func main() {
	port := os.Getenv("JOURNAL_CONSOLE_PORT")
	if port == "" {
		port = "8899"
	}
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		log.Fatal(err)
	}
	files := http.FileServer(http.FS(sub))
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !hostAllowed(r.Host) {
			http.Error(w, "Host not allowed", http.StatusForbidden)
			return
		}
		files.ServeHTTP(w, r)
	})
	addr := "127.0.0.1:" + port
	log.Printf("journal-console: http://%s/", addr)
	log.Fatal(http.ListenAndServe(addr, handler))
}
