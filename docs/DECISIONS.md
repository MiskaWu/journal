# 決策記錄

每一條都附理由。改變任何一條前,先讀懂它為什麼在這裡。

| # | 決策 | 選了什麼 | 為什麼 |
|---|---|---|---|
| **D1** | 素材深度 | Transcript + git | 只看 git commit 會漏掉「討論／決定／調查」這種沒 commit 的工作。代價是要做機密洗滌。 |
| **D2** | 落腳處 | 獨立 repo,與 infra 脫鉤 | 不違反 infra 憲法、不撐大那個逼近 10 GiB 的 origin。純文字。 |
| **D3** | 範圍 | 一次做到目標追蹤 | 使用者要「驗證離目標多遠」,含 `GOALS.md` + SLI 燃盡。 |
| **D4** | 觸發 | 三層 cadence(即時／夜間／聚合) | 單一夜間 rollup 的損失窗口是 24 小時,且在 WSL2 上可能整天不觸發。 |
| **D5** | 骨幹模型 | 可觀測性(log／trace／metric + SLI + staleness) | 只借概念,不搬重機械。人類尺度每天幾十筆,text + git + 一次 LLM 就是整個平台。 |
| **D6** | 中心形態 | git origin + 指定 aggregator + 靜態頁,**不架資料庫** | 中心真正稀缺的是「唯一的聚合權責」,不是一顆 DB。業界對應物是 Prometheus rule evaluator／Alertmanager,不是後端儲存。 |
| **D7** | 防遺失機制 | 縮短蒸餾窗口,**不複寫原始資料** | spool 存的是*指標*;機器死了指標指向的 transcript 也死,同步指標防護力接近零。要真防機器損毀得同步*內容* = 2–4 GB/年。業界對主機損毀一律接受遺失,只以秒級 flush 縮短窗口。 |
| **D8** | `progress.md` 擁有權 | 僅 aggregator 可寫 | 否則多機互相覆寫;更糟的是看不見 infra 服務的機器會把 probe 結果覆蓋成 `na`。 |
| **D9** | spool 是否入庫 | gitignore,不入庫 | 指標含本機絕對路徑,對別台機器毫無意義。 |
| **D10** | runtime 依賴 | **無硬性 runtime 依賴** —— 三層,有就用、沒有就降級 | 使用者明確表示無法保證任何機器裝了什麼。只把 `sh`／`git`／`claude` 當硬依賴,JSON 減量退化為加速器。 |
| **D11** | timer 韌性 | 一律 `Persistent=true` | WSL2 關機期間錯過的排程要能在下次啟動補跑。 |
| **D12** | 執行期憑證 | per-host deploy key | `gh auth` 的 token scope 是整個帳號;deploy key 只有單一 repo、不過期、掉一台只撤一把。 |
| **D13** | agent 散佈方式 | repo 即散佈通道 —— `git push` 就是部署 | 各機 pull 程式碼即完成更新,不需要建置或發佈流程。**見 D18 的修訂**:改為單向(程式碼 repo 對 agent 唯讀)。 |
| **D14** | 主機身分 | host id 與 hostname 解耦 | hostname 會變(WSL 尤其);一變 daily 檔就分岔成另一條線,而且**不會有任何錯誤訊息**。 |
| **D15** | 打包形態 | **不做容器 image**;裸腳本 + `systemctl --user` | ①容器自身依賴 podman/docker,普及率低於 python3,等於把不確定性換成更不確定的;②hook 與 `claude -p` 都把你逼回 host 安裝,循環;③能跑 Claude Code 的機器,依定義就是你能裝東西的機器。 |
| **D16** | 核心語言 | POSIX sh;不編譯二進位 | 本體是在編排 git／ssh-keygen／systemctl／claude,sh 完全勝任且零依賴。編譯會破壞 D13(要 per-arch build + 把二進位 commit 進純文字 repo)。 |
| **D17** | 互動邊界 | 互動只在人在時;timer／hook 路徑一律非互動 | 背景行程若停下來等輸入,會靜默卡死而你永遠看不到 —— 正好是這個工具最該避免的失效模式。用 `[ -t 0 ]` 判斷,非互動就退到 `--check`。 |
| **D18** | **程式碼與資料分兩個 repo** | `journal`(碼,agent 唯讀)／`journal-data`(資料,agent 可寫) | ①歷史乾淨:否則 `git log` 被每日 rollup 灌爆,找程式碼變更極痛苦;②**爆炸半徑**:自動化憑證只能寫資料、寫不了程式碼。若同一個 repo,任一台機器的 deploy key 外洩即等於能改 `bin/journal`,而每台機器都會 pull 並執行它。D13 的「push 即部署」保留,但變成**單向**。 |
| **D19** | **daily 分兩層:摘要(回報層)+ 四段(細節層)** | `## 摘要` 逐條帶結構 `專案 \| 類型 \| 標籤 \| 一句話`,門檻「成果可見」,5–8 行 | 使用者實際使用後的回饋(2026-07-29):四段力度太細,日常要的是組長視角 ——「各 agent 完成了什麼有價值的事、進度在哪」,偶爾才點開細節。**分組軸(專案/標籤/類型)是檢視時的樞紐,不烤進生成的文字** —— 使用者明確要求軸可自訂,烤死就得重新生成。門檻目前固定,列為未來可進 config 的設定。 |

## 尚待拍板

| # | 問題 | 預設 |
|---|---|---|
| **O3** | `GOALS.md` 是否從 `/opt/infra/docs/decisions.md` 待辦段 + `entra-sso-runbook.md` 播草稿? | 是。**只能在 infra 機執行**,dev 機看不到那些檔。 |
| **O5** | aggregator 指定哪台? | infra 機(24/7 常開)。**明確排除 dev 機**(WSL2 不常開)。同時只能有一台。 |
| **O7** | 是否調高 transcript 保留期? | 建議在 `~/.claude/settings.json` 加 `"cleanupPeriodDays": 365`。改的是使用者個人設定檔,不代為決定。 |
| **O8** | 程式碼 repo 要不要公開? | ~~預設私有~~ → **已實質定案為公開**(2026-07-29 推上 GitHub 時使用者建為 public repo)。 |
| **O9** | **中心 web 的可控旋鈕怎麼實作?** | 需求(2026-07-29 使用者明示):今天引入的可控項 —— `standup_lines`(早會力度)、`model_rollup`/`model_capture`(蒸餾模型)、`rollup_time`(整併時間)、摘要分組軸、價值門檻(未來)—— **都要能從中心 web 調整**,之後新增的旋鈕一律比照。分兩類:**檢視類**(分組軸、展開狀態)純前端 localStorage 即可,零張力;**生成類**(`standup_lines`、門檻)要寫回資料 repo 的 `config.yml`,與鐵律 4(不建控制平面)有張力。P5 拍板實作路徑,候選:①中心頁放設定表單,產生一行指令由人貼到任一台執行;②**直接連到 git provider 的 config.yml 網頁編輯**(零新服務,aggregator 本來就會 pull —— 預設傾向);③aggregator 上極小的寫入端點(限內網,最重,最後手段)。 |

## 已關閉

| # | 問題 | 結論 |
|---|---|---|
| O1 | repo 託管於哪個 provider | **GitHub**。`gh` 未安裝於 dev 機 → 走手動路徑建 repo 與上傳金鑰。 |
| O2 | 打包／運行形態 | 由 **D15** 定案:裸腳本 + user timer,不做 image。 |
| O4 | alert 出口 | `progress.md` + 靜態頁;email／推播列為選配。 |
| O6 | SQLite 衍生索引 | 不做。需要常駐 dashboard 時再加,且必須是**可重建的衍生索引**,不是 source of truth。 |
