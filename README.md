# journal

把散在各台機器、各個 Claude Code session 裡做過的事，自動整理成每天一份短日誌，隔天早會唸得出來，過幾週也查得到。

給大量使用 Claude Code、回頭常想不起自己做過什麼的人。它解決三件事：

1. **回憶**：跨機器、跨 session，把「今天做了什麼」收斂到一處。
2. **目標進度**：在 `GOALS.md` 寫下能用指令檢查的目標，看離終點還有多遠。
3. **中心**：多台機器各自產出，由一台聚合成總表。

**這個 repo 是工具的原始碼。** 產出的日誌放在另一個你自己的私有 repo（見[兩個 repo 的分工](#兩個-repo-的分工)），也可以只留在本機。

## 用起來長這樣

裝好之後照常用 Claude Code。每關一個 session，`SessionEnd` hook 在背景把它濃縮成幾行，追進當天的檔案，不會拖慢關視窗。每晚 timer 重讀全天的 session 與 git commit，整併成定稿；那時機器沒開的話，下次開機會補跑。

隔天想知道昨天做了什麼：

```console
$ journal standup 2026-11-06
CSV 匯出遇到逗號欄位錯行的問題修好了，可以交給客服驗
CI 快取搬到物件儲存做到一半，今天接著收尾

$ journal brief 2026-11-06
修復   report-export      CSV 匯出遇到逗號欄位不再錯行  #report-export
拍板   report-export      匯出一律採 RFC 4180 引號規則  #report-export
進度   ci-cache           快取金鑰改好，儲存位置還沒搬  #ci-cache
```

`journal show` 印出全文：除了上面兩層，還有完成、拍板、待續、卡住四段細節。

想知道離目標多遠，把目標寫進資料 repo 的 `GOALS.md`，每個目標對應一條會回 0 或非 0 的指令：

```yaml
- id: ci-cache
  title: CI 快取搬到物件儲存
  sli: { kind: probe, cmd: "grep -q object-store $HOME/app/ci.yml" }
  done-when: runner 設定已切換
```

```console
$ journal check
check：2 個目標 @ laptop
✅ docs-site  pass  exit 0
✖  ci-cache  fail  exit 1
✅ 寫入 status/laptop.yml
✅ 已 commit：journal: check @ laptop
```

<sub>以上是實際執行 `journal` 的輸出。session 紀錄是假的，模型換成回固定內容的替身，所以句子是虛構的，指令與輸出格式是真的。</sub>

## 怎麼開始

**需要** `sh`、`git`、`awk`、`claude`。有 `node` 或 `python3` 時用來加速讀 transcript，沒有就退回 `awk`。夜間整併用 systemd user timer；沒有 systemd 的機器要自己排程跑 `journal rollup`。

### 只在這台機器用

日誌只存在這台機器，不推到任何遠端（蒸餾仍會呼叫 `claude`）：

```sh
git clone https://github.com/MiskaWu/journal.git ~/.local/share/journal
~/.local/share/journal/install.sh --local
```

這會建立資料 repo `~/journal`、把 CLI 連到 `~/.local/bin/journal`、在 `~/.claude/settings.json` 註冊 `SessionEnd` hook（動之前先備份），並裝好夜間 timer。重跑不會弄壞既有狀態。

兩個要注意的地方：

- 程式碼不能 clone 到 `~/journal`，那是預設的資料目錄，安裝會拒絕。要換資料目錄用 `--data-dir`。
- hook 指向這份 checkout，裝完不要搬動它。

裝好後跑 `journal doctor --check` 自檢，結果以 exit code 表示。

### 跨機器同步

`install.sh` 不帶 `--local` 就是完整精靈：產生這台專用的 deploy key、接上私有的 `journal-data` repo、裝 hook 和 timer，最後做一次端到端自檢。`gh` 已登入時會自動建 repo 並上傳金鑰；否則印出公鑰和網址讓你手動貼上。

新機器也可以一行接入（下載這個腳本後會接著跑 `journal init`，可以先讀過再跑）：

```sh
curl -fsSL https://raw.githubusercontent.com/MiskaWu/journal/main/journal-bootstrap.sh | sh
```

第二台之後的機器要指定既有的資料 repo，否則會長出一份歷史不相干的骨架：

```sh
journal init --data-remote git@journal.github.com:<你>/journal-data.git
```

多機時指定一台當聚合者：`journal init --role aggregator`。同時只能有一台，要換手加 `--force-takeover`。

## 指令

```sh
journal standup [DATE]          # 早會要唸的短句（行數由 config 的 standup_lines 控制）
journal brief [DATE]            # 組長視角摘要（專案｜類型｜標籤｜一句話）
journal show [DATE]             # 全文：早會 + 摘要 + 四段細節
journal rollup [DATE]           # 手動整併／補跑任意日期（冪等）
journal check                   # 跑 GOALS.md 的檢查，有 fail 時 exit 1
journal trace <goal>            # 一個目標的跨天跨機推進線
journal digest [YYYY-Www]       # 週報：整併該週所有 daily 的早會與摘要
journal hosts                   # 列出已註冊機器、角色、健康度、last_seen
journal progress                # 印出多機彙總 progress.md
journal aggregate [--preview]   # 僅聚合者：合成 progress.md；--preview 任何機器可跑，只印不寫
journal render                  # progress 資料 → web/progress.html（自足靜態頁）
journal doctor --check          # 環境自檢，以 exit code 表示
journal uninstall [--purge]     # 移除 hook 與 timer；--purge 連資料、設定、金鑰一起刪
```

`journal help` 有完整清單。

## 控制台

瀏覽器介面：總攬燈號、daily 三層瀏覽、目標軌跡、週報，以及**旋鈕面板**。改 `standup_lines`／蒸餾模型／排程時間，按儲存就是一個 commit，各機下一輪 pull 生效。

它是 Go＋React（`console/server`＋`console/web`），資料語意零後端：瀏覽器直連 GitHub API，Go 只伺服前端、不碰任何憑證。

建置 `make console`（需 go 與 npm），啟用 `journal init --console`：`http://127.0.0.1:8899/` 掛成 systemd user service（只綁 127.0.0.1；PAT 的 localStorage 綁 origin，入口固定 token 才不用重貼）。`--no-console` 移除，埠號用 `JOURNAL_CONSOLE_PORT` 覆寫。

首次使用貼一把 fine-grained PAT（只授權 journal-data 的 Contents），存在瀏覽器本機。連線頁的 repo 擁有者預設是作者的帳號，請改成你自己的。

## 它怎麼運作

心智模型是「個人工作的可觀測性」：transcript 是熱的原始層，journal 是冷的降採樣長存層。作者實測壓縮比約 **1900:1**（5.8 MB/日 → 3 KB/日）。

- **即時層（L1）**：`SessionEnd` hook 背景蒸餾該 session 追進當日檔，秒級返回不卡關窗。失敗也沒關係，晚上會補回來。
- **夜間層（L2）**：timer 重讀全天素材整併定稿，預設每天 21:30，`Persistent=true` 錯過補跑。
- **多機與中心**：`journal aggregate`、`journal render` 把各機結果合成總表。只有聚合者能寫 `progress.md`，避免看不到某些服務的機器把結果蓋掉。

**機密**：寫進日誌前有兩道防線。第一道是生成提示明令不得抄機密；第二道是產出後掃描，符合內建格式（`glpat-`、GitHub token、`AKIA`、`sk-`、JWT、PEM 標頭、48 位以上 hex 等）或 `config.yml` 指定的機密檔與 pattern 就換成 `«REDACTED»`，並保留其餘內容。原始 transcript 永遠不進 repo。

## 兩個 repo 的分工

| repo | 內容 | 誰能寫 | agent 的憑證 |
|---|---|---|---|
| **`journal`**（本 repo） | `bin/` `lib/` `hooks/` `docs/` —— 工具本身 | 只有你，手動 push | **唯讀** |
| **`journal-data`**（私有 repo） | `daily/` `status/` `hosts/` `progress.md` —— 產出的日誌 | 每台機器自動 push | 可寫，但只限資料 |

分開的理由不只是歷史乾淨（否則 `git log` 會被每日 rollup 灌爆），更重要的是**爆炸半徑**：自動化流程的憑證只能寫資料，寫不了程式碼。若兩者同一個 repo，任何一台機器的 deploy key 外洩就等於能改 `bin/journal`，而每台機器都會 pull 並執行它。

「`git push` 就是部署」的性質仍然保留 —— 只是變成單向：你 push 程式碼，各機唯讀 pull。

## 執行形態

- `bin/journal` 是 **POSIX sh** 腳本（本機 `/bin/sh` → dash，會真的強制 POSIX）
- 硬依賴只有 `sh`、`git`、`awk`、`claude`；`node`／`python3` 是**加速器**，缺了退到 `awk` 保底路徑
- 不做容器 image、不編譯二進位 —— 理由見 DESIGN.md §9

## 目前狀態

設計已定案（第五版，見 [`docs/DESIGN.md`](docs/DESIGN.md)，本 repo 自足，不需外部連結）。規劃的五個階段都已實作：日誌層、即時層、目標檢查、多機納管、中心（aggregate／render／trace／digest），第二台機器已納管實測。

還沒定案的問題（例如要不要從既有待辦文件產生目標草稿、要不要調高 transcript 的保留天數）記在 [`docs/DECISIONS.md`](docs/DECISIONS.md) 的「尚待拍板」。已定案的有：聚合者放在個人開發機、程式碼 repo 公開。

## 文件

- [`docs/DESIGN.md`](docs/DESIGN.md) —— 完整設計與交接規格（唯一 source of truth）
- [`docs/DECISIONS.md`](docs/DECISIONS.md) —— 每個決策與理由

## 開發

```sh
sh tests/smoke.sh    # 全程假資料與假 claude，不碰真實環境
```

## 授權

[MIT](LICENSE)
