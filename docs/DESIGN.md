# journal —— 設計與交接規格 v5

> **這份文件是什麼**:`journal` 的完整設計。給接手實作的 Claude 對話當**唯一 source of truth** —— 不需要原規劃對話的上下文。
>
> **狀態**:設計已定案,3 項待拍板(§4)。程式碼**尚未動工**。
>
> 決策的完整理由見 [DECISIONS.md](DECISIONS.md)。本檔講的是「要蓋成什麼樣」。

---

## §0 六條鐵律(先讀)

1. **journal 不是 infra。** 它是**個人、home-scoped、免 root** 的工具,與 `/opt/infra` 完全分開。不套用 infra 的 ansible / `make` / rootful-Quadlet 慣例,不碰 infra 那個逼近 10 GiB 的 origin。infra 的 `CLAUDE.md` 憲法**不適用**於本工具 —— 本檔就是 journal 的規則。

2. **它是「觀察 host + 你的 home」的工具。** 凡遇「要不要隔離」的直覺都反過來想:它天生需要看得到 host 狀態與 `~/.claude`。

3. **原始 transcript 永遠不進 repo。** 只有蒸餾後的產物能被 commit。實測壓縮比約 **1900:1**;破這條線就是一年 2–4 GB。

4. **不建控制平面。** 不架伺服器、不收 webhook、不做 OAuth App、**不做容器 image**。§8 借的是 Cloudflare Pages 的**納管體驗**,不是它的架構。

5. **不假設機器上有任何 runtime。** 硬依賴只有 `sh`、`git`、`claude`,其餘一律「有就用、沒有就降級」(§9)。寫任何腳本前先問:**這台一定有嗎?**

6. **程式碼 repo 與資料 repo 分開,且方向不同。** 程式碼對 agent **唯讀**,資料對 agent **可寫**(§7)。任何「把日誌寫回程式碼 repo」的設計都是錯的。

---

## §1 需求

> 「我會在各種地方使用 claude(這台 infra 主機、本地開發機…等),想**統整每天完成的事情的摘要讓我回憶**;如果能**驗證我離目標還有多遠**更好。」

| | 能力 | 落在哪 |
|---|---|---|
| A | **回憶** —— 跨機跨 session,把「今天做了什麼」收斂到一處 | §5 §6 |
| B | **目標進度** —— 對照目標看「離終點多遠」 | §12 |
| C | **跨機** —— 資料散在多台機器的多個 session | §7 |
| D | **中心** —— 「還是要有一個中心來看所有的狀態」 | §7 |
| E | **別遺失** —— 「避免本地的資料過時間點就遺失」 | §6 |
| F | **好安裝** —— 「類似 Cloud Pages,和 GitHub 授權去處理」 | §8 |
| G | **環境不可控** —— 「我真的不能確保當下的環境會有什麼工具」 | §9 |

骨幹模型是使用者自己的 reframe:**這本質是「個人工作的可觀測性」**,借 log / trace / metric 的心智模型,但**只借概念,不搬重機械**。

---

## §2 環境實況

2026-07-27 在 dev 機實測。**換一台機器就要重驗** —— 這正是 `journal doctor` 存在的理由。

### Dev 機 `allstar-022a`

| 項目 | 實測 |
|---|---|
| OS | WSL2 (Linux 6.6.87.2-microsoft-standard) |
| systemd | ✅ PID 1 = systemd,`/etc/wsl.conf` 已設 `systemd=true` |
| user bus | ✅ `systemctl --user` = running |
| linger | ⚠️ `Linger=no` —— **待開** |
| `/bin/sh` | **dash**(不是 bash)—— 寫 POSIX sh 會被真的強制 |
| git | 2.53.0 |
| awk | GNU awk 5.3.2(但保底路徑仍須寫成 **POSIX awk**) |
| claude | `~/.local/bin/claude` |
| python3 | ✅ 可用(但**不得假設別台也有**) |
| node / perl | ❓ 未測 |
| jq / gh | ❌ 未安裝 |
| `/opt/infra` | ❌ **不存在於本機** |
| git identity | MiskaWu / miskawu@hotmail.com |
| 既有 ssh key | `id_ed25519_dev_github`、`id_ed25519_dev_gitlab` |

### Infra 機(hostname 待補)

24/7 常開 → **指定為 aggregator**。持有 `/opt/infra`、`docs/decisions.md`、`entra-sso-runbook.md`、邊緣 Caddy。**runtime 全未驗證**,由 `journal doctor` 現場產出。

### transcript 實測數據(整個設計的地基)

| 項目 | 值 | 後果 |
|---|---|---|
| `~/.claude/projects` 總量 | 5.8 MB / 14 session,集中單日 | 原始層約 **5.8 MB/日/機** |
| 單一 session 檔 | 最大 0.9 MB,平均約 0.4 MB | 即時蒸餾單 session 的輸入量可接受 |
| 蒸餾後 daily md | 約 3 KB | **壓縮比 ≈ 1900:1** → 一年約 2 MB |
| 若複寫原始資料 | 約 2–4 GB/年 | **紅線**,不做(鐵律 3) |
| slug 數量 | 7 個 | 含 `--claude-worktrees-*` 變體,映射表必須處理 |
| transcript 保留期 | `cleanupPeriodDays` 未設 → 預設 30 天 | 夜間 rollup 有 30 天餘裕;建議調高(O7) |

### ⚠ WSL2 排程陷阱

**WSL2 在 Windows 關機或睡眠時整個不存在。** 排在 23:00 的 timer,只要那時筆電是關的就**根本不會觸發**,而且不像實體機那樣「晚點開機就補跑」。

兩個對策**都要做**:

1. 所有 timer 加 `Persistent=true` —— 錯過的排程在下次啟動補跑。
2. **倚重事件驅動的即時層**(§6 L1)。`SessionEnd` hook 只在你真的在用電腦時觸發 —— 那正是資料產生的時刻。**在 WSL2 上,即時層不是加分項,是結構上的必需品。**

同一個理由**排除了 dev 機擔任 aggregator**:聚合者必須常開。

---

## §3 決策

完整表格見 [DECISIONS.md](DECISIONS.md)。最容易被誤解的幾條:

- **D7 防遺失**:縮短蒸餾窗口,**不複寫原始資料**。spool 存的是*指標*,機器死了指標指向的 transcript 也死,同步指標防護力接近零。業界對主機損毀一律接受遺失,只以秒級 flush 縮短窗口。
- **D10 依賴**:**無硬性 runtime 依賴**。JSON 減量是*優化*不是正確性,缺了退到 awk。
- **D15 不做 image**:容器自身依賴 podman/docker(普及率低於 python3);hook 與 `claude -p` 都把你逼回 host 安裝;且**能跑 Claude Code 的機器,依定義就是你能裝東西的機器**。
- **D17 互動邊界**:互動只在人在時。背景路徑若停下來等輸入會**靜默卡死**,正好是這工具最該避免的失效模式。
- **D18 雙 repo**:爆炸半徑 —— 自動化憑證只能寫資料,寫不了程式碼。

---

## §4 待拍板

| # | 問題 | 預設 |
|---|---|---|
| **O3** | `GOALS.md` 是否從 `/opt/infra/docs/decisions.md` 待辦段 + `entra-sso-runbook.md` 播草稿? | 是。**只能在 infra 機執行**。 |
| **O5** | aggregator 指定哪台? | infra 機。**明確排除 dev 機**。同時只能有一台。 |
| **O7** | 是否調高 transcript 保留期? | 建議 `"cleanupPeriodDays": 365`。改的是使用者個人設定檔,**不代為決定**。 |
| **O8** | **程式碼 repo 要不要公開?** | **已定案:公開**(2026-07-29 推上 GitHub)。bootstrap 因此變 trivial。 |
| **O9** | **中心 web 的可控旋鈕**(P5) | 使用者需求:`standup_lines`、摘要分組軸、價值門檻等可控項**都要能從中心 web 調**。檢視類走前端;生成類要寫回 `config.yml` —— 預設傾向「中心頁直連 git provider 的檔案編輯頁」,零新服務不違鐵律 4。細節見 DECISIONS O9。 |

已關閉:O1(GitHub)、O2(→D15)、O4(progress.md + 靜態頁)、O6(不做 SQLite)。

---

## §5 可觀測性骨幹

| 可觀測性 | journal 對應 | 關鍵後果 |
|---|---|---|
| **Log**(原始事件流) | transcript 逐行 + git commit | **索引,不複製**。journal = 冷的降採樣長存層;transcript = 熱的原始層(會過期)。 |
| **Trace**(跨 span 因果) | 一個目標的整條推進線,`trace_id = goal id`,每個 session 是一個 span | `journal trace <goal>` 把全過程串回來。掛接靠模型**推斷**,故 goal 標籤**可改**。 |
| **Metric**(可聚合低基數) | 每日 sessions/commits/files 數、目標狀態燈、staleness | 存進 frontmatter(**預聚合**)。*metric 只當導航,不當分數*(Goodhart)。 |

### 三種 alert,必須分得開

1. **goal staleness** —— 某目標 N 天沒動 / blocked 未解
2. **host staleness** —— 已註冊的機器 N 天沒回報
3. **agent unhealthy** —— 有回報但自檢失敗

### 與業界管線的對照

標準管線:`應用 → SDK 埋點 → 本機 agent → (gateway) → 後端儲存 → 查詢 UI`

**形狀一致的**:本機 agent(每台一個,觀察 host)、磁碟緩衝 + 重試、批次外送、取樣(業界 trace 留 0.1–10%,我們留 0.05%)、**存指標不存內容**(這就是 Loki 不索引 log 內容、Tempo 只索引 trace ID 的架構)、保留期金字塔(越聚合留越久)、**中央評估告警**(Prometheus rules + Alertmanager 去重)。

**刻意不同的**:省略 gateway 匯聚層(我們 2 台);聚合函數是 **LLM 語意蒸餾**而非 sum/count(這是壓縮比 1900:1 而非 100:1 的原因);後端是 markdown + git(git 在此的角色是 Tempo 底下那層**便宜物件儲存**,不是 Postgres);**不出 image**(業界 node agent 確實出 image,但實跑時是 DaemonSet + `hostPID` + host mounts,**系統性地把隔離拆光** —— image 在那裡是投遞格式而非隔離邊界;我們沒有 orchestrator,付拆隔離的代價卻拿不到艦隊投遞的好處)。

### 業界怎麼處理「主機死掉」—— 這條決定了 D7

**業界不處理,接受遺失。** 本地磁碟 buffer 保護的是行程崩潰與網路中斷;主機整台沒了 buffer 就跟著沒了,**沒有任何主流方案為此做同步複寫**。理由:telemetry 是衍生資料,丟了是失去可見性,不是失去工作本身。唯一的緩解手段是**把 flush interval 壓到秒級** —— §6 的 L1 就是它的人類尺度版本。

### analogy 的三個陷阱

1. 別搬重機械(TSDB / collector / OTel)—— 過度設計。
2. metric 是弱信號、trace 是推斷 —— 真相在 prose log 與 SLI。
3. **我們的 `trace_id` 比業界弱。** 真正的分散式追蹤把 `traceparent` 一路**傳遞**下去,因果**確定**;我們的 goal 標籤是 LLM **事後推斷**。所以標籤**設計上就允許被改**,且 trace 只當導覽、不當證據。

> **Pushgateway 的教訓**:Prometheus 為「跑完就死」的批次任務準備了 Pushgateway,但官方同時勸阻拿它當通用方案,因為它會變成單點與**陳舊狀態**的來源。對應到我們:**即時層只是保險,真相仍由夜間那次完整 rollup 重寫**。

---

## §6 三層 cadence

| 層 | 觸發 | 做什麼 | 損失窗口 | 誰跑 | 指令 |
|---|---|---|---|---|---|
| **L1 即時** | `SessionEnd` hook(事件驅動) | 蒸餾剛結束的單一 session → 機密 gate → append 當日 md → commit + push。**背景執行,絕不互動** | 一個 session | 每台 | `journal capture` |
| **L2 夜間** | timer(`Persistent=true`) | 重讀當天全部 session,整併成連貫四段敘事、重算 metrics、**覆寫**當日 md | 一天 | 每台 | `journal rollup` |
| **L3 聚合** | timer,排在 L2 之後 | pull → 跑本機能跑的 SLI → 讀所有 `status/` `hosts/` → 合成 `progress.md` → render → push | 一天 | **僅 aggregator** | `journal aggregate` |

**L1 保「不丟」,L2 保「好讀」。**

L1 送出去的是**已蒸餾、已過機密 gate** 的 markdown,不是原始 transcript —— 這正是「縮短窗口」與「複寫原始資料」的差別:前者窗口降到幾分鐘、量仍是 3 KB/日;後者量變成 2–4 GB/年。

**成本誠實揭露**:一天約 14 個小 commit 而非 1 個,每個 session 結束多一次 `claude -p`。嫌 commit 吵可在 L2 squash,但**別為此放棄 L1**。

---

## §7 兩個 repo、中心、權責

### 分工

| repo | 內容 | agent 的權限 | 誰 push |
|---|---|---|---|
| **`journal`** | `bin/` `lib/` `hooks/` `docs/` | **唯讀** | 只有你,手動 |
| **`journal-data`** | `GOALS.md` `config.yml` `daily/` `status/` `hosts/` `weekly/` `progress.md` `web/` | **可寫** | 每台機器自動 |

分開的理由:①歷史乾淨(否則 `git log` 被每日 rollup 灌爆);②**爆炸半徑** —— 自動化憑證只能寫資料。若同一個 repo,任一台機器的 deploy key 外洩即等於能改 `bin/journal`,而每台機器都會 pull 並執行它。

「`git push` 就是部署」仍成立,但變成**單向**:你 push 程式碼 → 各機唯讀 pull。

### 各機的本地佈局

```
~/.local/share/journal/     ← 程式碼 repo 的工作副本（唯讀 clone）
~/journal/                  ← 資料 repo 的工作副本（可寫）
~/.local/bin/journal        → symlink 到 ~/.local/share/journal/bin/journal
~/.config/journal/host.yml  ← 本機身分（host id、兩個 repo 的路徑），不入庫
~/.ssh/journal_<host>       ← 本機專屬 deploy key（只對資料 repo 有寫入權）
~/journal/.spool/           ← 本機指標，gitignored
```

### 中心的三個構件(都用既有東西,不架新服務)

| 構件 | 是什麼 | 誰能寫 |
|---|---|---|
| 資料中心 | `journal-data` 的 origin | 每台機器,但**只寫自己 host 命名的檔** |
| 聚合者 | 指定一台常開機器(預設 infra,O5) | **唯一能寫 `progress.md`** |
| 檢視面 | `web/progress.html`,掛既有邊緣 Caddy | 由 aggregator 的 `journal render` 產生 |

### 權責規則(必須照做)

1. 每台跑 `journal check`,結果**只寫 `status/<host>.yml`** —— per-host 檔名,永不衝突。
2. **非 aggregator 的機器絕不寫 `progress.md`。**
3. aggregator 合成規則:每個 goal 取**所有 host 中最新的非 `na` 結果**;若全部 `na`,標 `unchecked` 並列原因(**不得誤報成 fail**)。
4. 每筆結果帶 `checked_at`,staleness 才算得出來。
5. push 前一律 `git pull --rebase`。因為寫入的檔都帶 host 前綴,rebase 永遠乾淨。衝突**不自動硬解**。
6. aggregator 另讀 `hosts/*.yml` 的 `last_seen` 與 `agent_health`,區分沉默與不健康(§10)。

> **這修掉的是一個真 bug**:早期設計讓 `daily/…__<host>.md` 帶 host 前綴,**但 `progress.md` 沒有前綴、每次覆寫、又沒指定誰負責寫**。後果是兩台同時 push 就衝突;更糟的是 dev 機看不見 infra 的服務,它的 probe 全是 `na`,一 push 就把**看得見的那台的真實結果覆蓋掉**。

---

## §8 安裝與納管

目標:**在任何一台新機器上,一行指令就能接進系統** —— 含環境補齊、provider 授權、憑證、註冊、排程,以及裝完當場證明它會動。

### Cloud Pages 類比:借什麼、不借什麼

| Cloudflare Pages / Vercel | journal |
|---|---|
| OAuth 連接 git provider,不用手動貼 token | ✅ **借** —— `gh`/`glab` 已登入時全自動 |
| `git push` 就是部署 | ✅ **借**(單向,見 §7) |
| 裝完給你建置紀錄,當場知道成不成功 | ✅ **借** —— `init` 結尾跑端到端自檢 |
| 重跑不會弄壞既有狀態 | ✅ **借** —— 每步冪等 |
| 雲端控制平面代跑建置、收 webhook | ❌ **不借** —— agent 必須跑在被觀察的機器上 |
| 容器化保證環境一致 | ❌ **不借** —— 改用 §9 依賴分層 + 互動補齊 |

### `journal init` 的十一步(皆冪等,可重跑)

1. **環境自檢與互動補齊** —— 跑 `journal doctor`,逐項帶你補完再往下(見下)。
2. **決定 host id** —— 預設 `hostname`,可 `--host-id` 覆寫,寫進 `~/.config/journal/host.yml`。**解耦的理由(D14)**:hostname 會變,一變 daily 檔就分岔成另一條線,而且**不會有任何錯誤訊息**。
3. **取得程式碼 repo** —— clone 到 `~/.local/share/journal/`。公開的話直接 https clone(O8);私有則需唯讀 deploy key。
4. **產生 per-host deploy key** —— `ssh-keygen -t ed25519 -f ~/.ssh/journal_<host> -N "" -C "journal@<host>"`,並設 Host alias(`journal.github.com` → `github.com`),讓 journal 專用這把、**完全不碰你的個人金鑰**。<br>**落點優先 `~/.ssh/config.d/journal.github.com.conf`(O10)** —— 主檔常有別人在寫,journal 只擁有自己那一個檔。前提是主檔**檔首**有 `Include config.d/*.conf`:那行落進 `Host` 區塊裡會變成條件式包含、形同沒寫,所以只能插檔首,而且 `Include` 是 OpenSSH 7.3+ 才有的關鍵字,老版本讀到是 rc=255 全滅不是降級。因此**代改主檔一律先問過**(非互動路徑一律不動),並且不比對 `ssh -V` 而是用 `ssh -G` **功能探測**:寫完就驗,驗不過原樣還原、退回把 alias 附加到 `~/.ssh/config` 檔尾(舊做法,功能等價)。既有安裝在互動下會被問要不要搬進 drop-in;`uninstall --purge` 兩種落點都收得乾淨。
5. **連接 provider** —— 偵測到 `gh`/`glab` 已登入就自動建 repo 並上傳公鑰為 **write deploy key**;否則印出公鑰 + 直達設定頁的網址請你貼上。**兩條路產出相同**。dev 機實測 `gh` 未安裝 → 走手動路徑。
6. **取得資料 repo** —— 不存在就建立 + 骨架 + 首個 commit;已存在就 clone 到 `~/journal`。
7. **註冊本機** —— 寫 `hosts/<host>.yml`(per-host,不撞)。這就是**主機註冊表**,讓中心知道「誰應該回報」。
8. **指派角色** —— `--role aggregator` 才會成為聚合者。先掃註冊表,**已有 aggregator 就拒絕**(除非 `--force-takeover`)。
9. **安裝 agent** —— 建 `~/.local/bin/journal` symlink、註冊 `SessionEnd` hook、裝 systemd user timer(`Persistent=true`)。
10. **記錄降級狀態** —— 把本機落在哪一階(§9)寫進 `hosts/` 與 `status/` 的 `agent_health`。
11. **端到端自檢** —— 真實往返:**產生測試 capture → 過機密 gate → commit → push → 確認遠端收到 → 還原**。沒有這步,你要等到當晚才會發現 push 憑證是壞的。

### `journal doctor` —— 互動式補齊

| 模式 | 行為 | 誰用 |
|---|---|---|
| `journal doctor` | **互動**:列全貌 → 逐項帶你補 → 每項補完立刻複驗 | 人,手動執行 |
| `journal doctor --check` | **只報告,絕不等輸入**,以 exit code 表示 | **timer / hook 背景路徑**(D17) |
| `journal doctor --yes` | 非互動,自動修「journal 自己能做的」 | 腳本化重裝 |

```
$ journal doctor

  掃描 allstar-022a … 完成

  必要 ─────────────────────────────────────
  ✅ sh          /bin/sh (dash)
  ✅ git         2.53.0
  ❌ claude      找不到

  加速器（缺少會降級，不影響正確性）────────
  ❌ node
  ❌ python3     → 減量將以 awk 粗篩，蒸餾忠實度較低

  執行環境 ─────────────────────────────────
  ✅ systemd     user bus running
  ❌ linger      Linger=no → 登出後 timer 會被殺
  ❌ timer       journal-rollup.timer 未安裝
  ❌ hook        SessionEnd 未註冊

  1 項必須處理，4 項建議處理。要現在逐項補齊嗎？[Y/n]
```

逐項時**清楚區分「我幫你做」與「你自己做」**:

- **journal 自己做(問過才做)**:一切在 `~/` 底下的 —— symlink、ssh key、`~/.ssh/config`、hook 註冊、systemd **user** unit、建目錄。動既有檔案前一律**先備份**。
- **印指令給你做**:需要 `sudo` 的套件安裝、`loginctl enable-linger`(系統層)、provider 網頁操作。**journal 永不自行取得或使用 sudo。**

**發行版感知**:偵測 `apt`/`dnf`/`pacman`/`apk`/`brew`,只印對應的那一行,不印通用廢話。

### 憑證設計

| 方案 | Scope | 撤銷粒度 | 過期 | 判定 |
|---|---|---|---|---|
| **per-host deploy key** | 單一 repo | **單台** | 不過期 | ✅ **採用** |
| `gh`/`glab` token | **整個帳號** | 全部一起 | 會過期 | 僅用於**一次性設定** |
| fine-grained PAT | 可限單 repo | 單把 | **會過期** | 可接受的備案 |
| GitHub App | 可限單 repo | 細 | 1 小時需刷新 | ❌ 要自架 app,違反鐵律 4 |

**一次性的廣授權用於設定,長期的窄授權用於運行。** 筆電掉了只撤那一把,其他機器不受影響。

### Bootstrap

因為核心是 POSIX sh(D16),bootstrap 就是**一個可獨立傳輸的腳本檔**,不需要打包格式:

- **第一台**:`sh journal-bootstrap.sh --create`
- **後續機器**:若程式碼 repo 公開(O8),`curl` 拿到腳本就能跑,雞生蛋問題完全消失;若私有,先用該機既有憑證 clone 再跑 `./install.sh`。

### 移除與撤銷

| 指令 | 做什麼 |
|---|---|
| `journal uninstall` | 移除 timer 與 hook,**保留**資料與 repo |
| `journal uninstall --purge` | 另外刪掉兩個工作副本、`~/.config/journal`、deploy key |
| `journal revoke <host>` | **從別台跑**:標記 retired、停止對它發 staleness alert、印出要撤的 deploy key 指紋。**不刪除該機歷史的 daily 檔** —— 那是你的工作紀錄。 |

---

## §9 依賴策略與執行形態

> 使用者原話:「**我真的不能確保當下的環境會有什麼工具是有安裝的。**」
> 核心主張:**與其打包所有依賴,不如不依賴。**

### 三層依賴 —— 只有第 0 層是硬的

| 層 | 內容 | 缺了怎樣 |
|---|---|---|
| **0 · 地板** | `sh` · `git` · `claude` | **拒絕執行** + 印安裝指令 + 標 `agent_health: fail` |
| **1 · 加速器** | `node` → `python3` → `awk`(保底) | **自動降級**,標 `agent_health: degraded` |
| **2 · 便利** | `gh`/`glab` · `jq` · `timeout` | 走手動路徑,功能不減 |

Tier 0 這三樣**任何打包方案都逃不掉**:`claude` 必須在 host 上(它就是產生 transcript 的東西)、`git` 是儲存層兼素材來源、`sh` 在任何 Unix 上都有。

### 為什麼 runtime 只是「加速器」

**語意工作是 LLM 做的**,機械層要做的比看起來少:

| 工作 | 需要真的解析 JSON? |
|---|---|
| 依日期切出當天的行 | ❌ 頂層 `timestamp`,行導向,awk 就行 |
| 讀 `cwd` / `gitBranch` | ❌ 頂層字串欄位 |
| 讀寫 frontmatter | ❌ **格式是我們自己定的**,定成扁平好剖析 |
| 讀寫 `status/` `hosts/` | ❌ 同上 |
| **減量**(走進 `message.content` 陣列丟掉 tool 輸出) | ✅ **只有這一件** |

而減量是**優化,不是正確性** —— 把當天原始行直接丟給 `claude -p` 照樣產得出摘要,只是貴一點。

### 執行形態

| 形態 | host 需要 | 判定 |
|---|---|---|
| **POSIX sh 腳本** | `sh` | ✅ **採用** |
| python / node 腳本 | 該 runtime | ❌ 違反鐵律 5 |
| 編譯二進位 | 無 | ❌ 破壞 D13,需 per-arch build,且要把二進位 commit 進純文字 repo |
| 容器 image | podman/docker | ❌ 見 D15 |

> ⚠ dev 機 `/bin/sh` → **dash**,所以 `[[ ]]`、陣列、`$'...'` 這些 bashism **一律過不了**。保底 awk 也要寫成 **POSIX awk**,不能靠 gawk 擴充。

**什麼條件下改推容器**:機器數長到 5–10 台以上且異質時。現在 2 台,不成立。接手 agent 若發現條件已變,可以重開這題。

### WSL2 注意事項

- `loginctl enable-linger miskawu` —— 實測 `Linger=no`,不開的話 user timer 一登出就死。
- 所有 `.timer` 加 `Persistent=true`(D11)。
- **別把 aggregator 排在 dev 機**(O5)。
- L2 的 timer 設在你通常還開著機的時段,而非深夜 —— 配合 `Persistent=true`,實際觸發率會高很多。

---

## §10 韌性與可見的失敗

> 「順利執行」不是靠保證不出錯,而是靠**每個環節壞掉時都不擴散、而且看得見**。

### Fail-soft 矩陣

| 失效 | 行為 | 誰來補 |
|---|---|---|
| L1 `capture` 失敗 | spool 那行維持 `captured:false` | 當晚 L2 自動補 |
| `claude -p` 逾時/失敗 | 寫「(生成失敗)」佔位 + 記錯誤,**不靜默漏** | 下次 rollup 重試 |
| `push` 失敗 / 離線 | commit 留在本地 | 下次任何操作重試 |
| `pull --rebase` 衝突 | **停手,不自動硬解**,寫 marker | 人 |
| 機密 gate 命中 | **redact 後繼續**,印警告(不整篇拒收) | — |
| Tier 1 runtime 缺席 | 降級到 awk,標 `degraded` | — |
| SLI probe 跑不了 | 標 `na`(**不是 `fail`**)並記原因 | — |
| Tier 0 缺席 | **拒絕執行** + 印安裝指令 + 標 `fail` | 人 |

### 四種狀態必須分得開

| 狀態 | 判定 | 意義 |
|---|---|---|
| 🟢 正常但沒工作 | `last_seen` 新 + `health: ok` + 當日無素材 | 你那天沒用這台,**不需要 alert** |
| 🟡 降級運行 | `health: degraded` | 能動但吃虧 |
| 🔴 不健康 | `health: fail` | 有回報但自檢失敗 |
| ⚫ 沉默 | `last_seen` 超過 N 天 | 完全沒回報 —— 機器關著?agent 死了? |

早期設計只偵測得到**沉默**,分不出「你沒工作」和「agent 死了」。

### 失敗必須看得見

- systemd unit 加 `OnFailure=`,失敗時寫 marker 進 `status/<host>.yml` 的 `agent_health`。
- 每週跑一次 `journal doctor --check`,結果一併寫進 `status/`。
- aggregator 讀到 `fail`/`degraded` 就在 `progress.md` 標出來。

> **「壞掉了但你不知道」是這個工具最糟的失效模式** —— 它是要幫你回憶的,靜默失效等於騙你說那幾天沒做事。

### 併發與逾時

- **鎖**:L1 hook 與 L2 timer 可能同時跑。用 `mkdir` 當原子鎖(**POSIX 保證原子,不依賴 `flock`**);拿不到就等待或跳過,不硬上。鎖要記 PID 與時間,超過閾值視為陳舊鎖自動清除。
- **逾時**:`claude -p` 一律包逾時。有 `timeout` 就用;沒有就「背景執行 + 逾時後 kill」。
- **hook 絕不阻塞**:`SessionEnd` 只做「append 一行 spool + 背景 spawn」就立刻返回。**絕不讓 journal 拖慢你關視窗。**

### D17 互動邊界

**互動只能發生在人在的時候。** `journal init` 與手動 `doctor` 可以問問題;**timer 與 hook 觸發的路徑一律走 `--check`,絕不等待輸入。**

違反的後果:背景行程停在那裡等你按 Enter,timer 累積、日誌不再產生,而**你完全不會知道**。實作時用 `[ -t 0 ]` 判斷,非互動就自動退到 `--check`。

---

## §11 檔案格式

### 程式碼 repo `journal/`

```
bin/journal                    # 單一 CLI，POSIX sh
lib/
  doctor.sh                    # 環境自檢 + 互動補齊
  provision.sh                 # init / revoke / uninstall
  transcript.sh                # 日期切分、欄位擷取
  reduce.node.js               # 減量·快路徑
  reduce.py                    # 減量·快路徑
  reduce.awk                   # 減量·保底路徑（POSIX awk）
  gitlog.sh · frontmatter.sh · secrets.sh · sli.sh · render.sh
hooks/session-end.sh           # L1 觸發點，只 append + 背景 spawn
docs/DESIGN.md · DECISIONS.md
install.sh · journal-bootstrap.sh
config.example.yml
```

### 資料 repo `journal-data/`

```
GOALS.md                       # SLO：里程碑 + 可檢查 SLI（你維護）
config.yml                     # repo 清單、時區、slug 映射、aggregator 指定
daily/2026-07-27__allstar-022a.md
status/allstar-022a.yml        # SLI 結果 + agent_health
hosts/allstar-022a.yml         # 主機註冊表
weekly/2026-W30.md
progress.md                    # ★ 僅 aggregator 可寫
web/progress.html
.spool/                        # ★ gitignored
```

### `daily/<date>__<host>.md`

```markdown
---
date: 2026-07-27
host: allstar-022a
metrics: { sessions: 3, commits: 5, files_touched: 12 }
goals_touched: [gitlab-runner, journal-system]   # 模型推斷，可改
generated_by: rollup        # rollup（L2 定稿）| capture（L1 即時碎片）
reduced_by: awk             # node | python3 | awk
---
## 摘要
- infra | 功能 | gitlab-runner | k3s executor 的 runner 骨架完成並可註冊
## 完成
- k3s executor 的 gitlab-runner 骨架 + wiring（commit 0fa72f5）
## 拍板
## 待續
## 卡住
```

**兩層閱讀(D19)**:`## 摘要` 是回報層 —— 組長視角,只讀這段就知道當天產出了什麼價值、各專案進度在哪、哪裡有紅燈。逐條格式固定為 `專案 | 類型 | 標籤 | 一句話`,類型五選一(功能/修復/進度/拍板/卡住),門檻是「成果可見」,全天 5–8 行。**分組軸不烤進文字**:按專案、按標籤、按類型都是同一份資料在檢視時的樞紐(`journal brief` 與 render 出的頁面做分組,資料本身不動)。

四段固定:**完成 / 拍板 / 待續 / 卡住** —— 這是細節層,想知道詳細才點開。`generated_by` 分辨即時碎片與整併定稿;`reduced_by` 讓你事後知道那天是不是降級跑的 —— 摘要品質有落差時查得到原因。

### `status/<host>.yml`

```yaml
host: allstar-022a
checked_at: 2026-07-27T23:10:04+08:00
agent_health: ok            # ok | degraded | fail
degraded_reason: ""
results:
  entra-sso:   { state: partial, kind: checklist, detail: "4/6" }
  edge-tls:    { state: na,      kind: probe, detail: "此機無法觸及該端點" }
```

### `hosts/<host>.yml`

```yaml
host: allstar-022a
registered_at: 2026-07-27T22:10:00+08:00
os: wsl2                       # linux | wsl2 | darwin
roles: [node]                  # node | aggregator
agent: { version: 0.1.0, hook: installed, timer: journal-rollup.timer }
capabilities:                  # 供 SLI 判斷這台能不能跑某個 probe
  paths: ["/home/miskawu/projects"]
  can_reach: []
last_seen: 2026-07-27T23:40:12+08:00
```

### `.spool/<date>__<host>.jsonl`(每行約 200 bytes)

```json
{"session":"f703ac8b-…","transcript":"/home/miskawu/.claude/projects/-home-miskawu-projects/f703ac8b-….jsonl",
 "cwd":"/home/miskawu/projects/hydrogen","branch":"main",
 "started":"2026-07-27T14:02:11+08:00","ended":"2026-07-27T15:19:40+08:00","captured":false}
```

**存指標不存內容**,且 gitignore(D9)。`captured` 讓 L2 知道哪些已處理、哪些是 hook 沒觸發而漏掉的 —— L2 補做這些,這就是「補刷」的實作。

---

## §12 CLI 與 SLI

### 指令

| 指令 | 層 | 作用 |
|---|---|---|
| `journal init` | 納管 | 十一步精靈,皆冪等。`--create`/`--role`/`--host-id` |
| `journal doctor [--check\|--yes]` | 納管 | 互動式補齊;背景路徑用 `--check` |
| `journal hosts` | 納管 | 列出已註冊機器、角色、`last_seen`、`agent_health` |
| `journal revoke <host>` | 納管 | 標記 retired 並印出要撤的 deploy key |
| `journal uninstall [--purge]` | 納管 | 移除 timer/hook |
| `journal capture <session>` | L1 | 由 hook 呼叫。單 session 蒸餾 → gate → append → push。背景、非互動 |
| `journal rollup [DATE]` | L2 | 重讀當天全部 session → 整併 → **覆寫**當日 md。冪等,可補跑 |
| `journal check` | L2/L3 | 跑本機能跑的 SLI → 寫 `status/<host>.yml` |
| `journal aggregate` | L3 | **僅 aggregator**。合成 `progress.md` + render + push |
| `journal render` | L3 | `progress.md` → `web/progress.html` |
| `journal digest [WEEK]` · `trace <goal>` · `show` · `progress` | — | 彙整、串線、檢視 |

### SLI 可檢查性

> **SLI 必須是「一條會回 0/非0 的指令」或「一個便宜可觀察的事實」,不是形容詞。**

| kind | 怎麼查 | 例 | 適合 |
|---|---|---|---|
| `probe` | 指令 exit 0 / 比對輸出 | `curl -fsS https://dev.baasgames.com` | 服務起來(最客觀) |
| `file` | test/grep/mountpoint | `mountpoint -q /srv/data` | IaC 狀態就位 |
| `checklist` | 數 `- [x]`/總數 | runbook 6 步 → `4/6` | 手順型目標 |
| `threshold` | 數字對目標 | N/M 服務遷入 | 量化但弱(Goodhart) |
| `judge` | LLM 讀證據給軟評,標 `~` | 「docs 讀起來清楚」 | 無 probe 時的最後手段 |

**規則**:能寫 `probe/file/checklist` 就別退到 `threshold`;無 probe 才用 `judge`;每格標種類;需密碼者標 `manual`;全部 **read-only**。

```yaml
- id: entra-sso
  title: Entra ID SSO 上線（GitLab 經 Casdoor）
  sli: { kind: checklist, source: /opt/infra/docs/entra-sso-runbook.md }
  done-when: Step 5 端到端驗證通過
  requires: { paths: ["/opt/infra"] }    # 對照 hosts/*.yml 的 capabilities 自動判定
```

**跨機語意**:probe 只在跑得動的機器上跑;每機把 `pass/fail/na` 寫進**自己的** `status/<host>.yml`;**aggregator** 取「所有 host 中最新的非 `na` 結果」。全 `na` → 標 `unchecked`,**不得誤報成 fail**。

---

## §13 資料流與機密

### rollup 流程

1. **session 指標捕捉(L1 入口)** —— `hooks/session-end.sh` append 一行進 `.spool/`,背景觸發 `journal capture` 後**立刻返回**。⚠ **動手前先確認當時 Claude Code 版本的 `SessionEnd` hook 名稱與 payload 欄位**,別照抄本檔假設。
2. **transcript 擷取** —— 優先讀 spool 指到的檔;缺漏時 fallback 到 glob `~/.claude/projects/*/*.jsonl`,依 `timestamp`(本機 local date)切出當天。
   > ⚠ **同一邏輯 repo 會有多個 slug**:實測本機 7 個,`dev-env-ansible` 就散成本體加三個 `--claude-worktrees-*`;infra 機另有 `-home-miskawu-infra` 與 `-opt-infra`(repo 搬過家)。`config.yml` 必須把 slug 映回邏輯專案,**別漏、別重複計**。L1 路徑天生免疫 —— hook 當下就知道真正的 `cwd`。
3. **減量** —— 依 §9 階梯選路徑,把 `reduced_by` 寫進 frontmatter。
4. **git 擷取** —— 對 `config.yml` 列的 repo 跑 `git log --since … --until … --stat`。
5. **生成** —— 丟給本機的 `claude -p`(headless,用 host 已登入的憑證),**包逾時**,固定 prompt → 產 frontmatter + 四段 prose。
6. **機密 gate** → **L1 與 L2 都要跑**,通過才 commit+push。
7. **push** —— 先 `git pull --rebase`;衝突不自動硬解。
8. **更新 `last_seen` 與 `agent_health`**。
9. **缺日佔位** —— 無素材或生成失敗都寫佔位行,**不靜默漏**。

### 機密處理:兩道防線

1. 生成 prompt 明令「不得抄任何機密 / token / 密碼」。
2. **產出後 gate** —— 讀 `/opt/infra/secrets.yml`(若存在)裡的**值**,加常見 pattern(`glpat-`、`AKIA…`、`sk-…`、長 hex/base64),掃剛生成的 daily 檔;命中就 **redact-and-keep**(替換成 `«REDACTED»` 保留摘要並印警告,比整篇拒收好用)。

> **gate 必須在 L1 與 L2 都跑。** L1 會 push,所以**不能**「先推上去、晚上再洗」—— 遠端一旦收過機密,git 歷史就洗不乾淨了。

資料 repo **必須私有**。SLI check 一律 read-only;需密碼者標 `manual`,**機密不進 `GOALS.md`**。

---

## §14 建置階段與驗收

> 每層獨立可驗,別一次全推。

### P1 · log 層(單機、離線也成立)

程式碼 repo 骨架 + `bin/journal`(**dash 相容**)+ `rollup` + **awk 保底減量** + 機密 gate + `init --local`。

**驗收**:`journal rollup` 產出今天的 daily 檔,四段合理;塞假的 `glpat-` 確認 gate 擋得住並 redact;**把 `node`/`python3` 從 PATH 藏起來再跑一次**,確認 awk 路徑產得出同樣結構的輸出。

### P2 · 即時層(WSL2 上優先度高)

`hooks/session-end.sh` + `capture` + `.spool/` + 鎖 + 逾時。**先查清當時版本的 `SessionEnd` hook 名稱與 payload。**

**驗收**:結束一個 session → spool 多一行、當日 md 多一段、產生 commit,而且**關視窗沒有卡頓**;故意硬殺一個 session,確認 L2 靠 `captured:false` 補回來;**同時觸發 L1 與 L2,確認鎖有效**。

### P3 · 目標 / SLI

`GOALS.md` 播種(O3,**須在 infra 機做**)+ `check` + `status/<host>.yml`。

**驗收**:infra 機對 `entra-sso` 吐 `checklist 4/6`;dev 機跑同一份 `GOALS.md`,確認那些項**正確標成 `na` 而不是 fail**。

### P4 · 納管與韌性

`init` 十一步 + **互動式 `doctor`** + `hosts/` 註冊表 + deploy key + `uninstall`/`revoke` + `OnFailure` 健康回報。

**驗收**:①**在一台全新機器上從零跑到端到端自檢通過,全程不用手動編輯任何檔**;②**重跑 `init` 確認冪等**;③故意刪掉 timer 後跑 `doctor`,確認它指出問題**並帶你修好**;④**把 `claude` 從 PATH 藏起來**,確認 Tier 0 擋住並印出正確的安裝指令;⑤**在非互動環境下觸發,確認它走 `--check` 而不是卡住等輸入**。

### P5 · 中心

`aggregate` + `render` + Caddy + timer 上線 + `trace` + `digest`。

**驗收**:兩台各推一天資料,`progress.md` **同時反映兩台且無衝突**;Caddy 網址看得到;**停掉 dev 機三天確認出現 host staleness**;**故意讓一台降級跑,確認標出 degraded 而不是當成正常**;dev 機關機一天後再開確認 `Persistent=true` 補跑;`trace entra-sso` 串得出跨天跨機的線。

---

## §15 接手起手式

1. 讀完本檔(§0 六條鐵律 + §2 環境實況 + §4 待拍板 + §9 依賴策略)與 [DECISIONS.md](DECISIONS.md)。
2. 確認 O3/O5/O7/O8(沒答就用預設,並**明講採了哪個預設**)。
3. **先確認你在哪台機器上**。`hostname` 若是 `allstar-022a`,你在 dev 機:`/opt/infra` 不存在,O3 播種**做不到**,infra 專屬 probe 應為 `na`。
4. **動手前先跑一次環境盤點** —— 有哪些 runtime?這決定先寫哪條減量路徑。但**無論如何 awk 保底路徑一定要有**,它才是正確性的基準。
5. 從 **P1** 開始,做完就地驗收再進下一階段。**P2 前先查清 `SessionEnd` hook 的名稱與 payload。**

### 最容易搞砸的八件事

1. **讓非 aggregator 的機器寫了 `progress.md`** —— 會靜默用「看不見的機器」覆蓋真實結果。
2. **把原始 transcript 或 `.spool/` commit 進去** —— 一年 2–4 GB,且 spool 對別台是死連結。
3. **L1 跳過機密 gate** —— 它會 push,遠端收過就洗不掉。
4. **假設機器上有 python3 / node / jq** —— 鐵律 5。**awk 保底路徑不是選配。**
5. **寫出 bashism** —— dev 機 `/bin/sh` 是 dash,`[[ ]]` 直接爆。
6. **在 timer 或 hook 路徑上做互動** —— 會靜默卡死而你永遠不知道。
7. **把日誌寫進程式碼 repo** —— 鐵律 6,爆炸半徑就是為此而分。
8. **用帳號級 token 當執行期憑證** —— 要 per-host deploy key。
