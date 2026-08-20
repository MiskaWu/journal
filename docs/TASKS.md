# 任務機制（journal task）

2026-08-20 拍板（三個未決題由 Miska 親選：stalled=旋鈕、代理=純執行者、封存=僅手動）。
資料放 journal-data，工具是 `journal task` 子指令家族，Web 視圖在 console 的「任務」分頁。

## 不可違反的合約

1. 任務是唯一真相來源，對話可丟棄 —— 進度、決定、卡住原因都要寫回任務（執行點：`update`）。
2. 代理只碰 `ready` 的任務。ready 由人貼，不由代理判斷。
3. 同一時間只做一件；做完或轉 needs-input 才取下一件。
4. 代理不能標 done —— `update` 收到 done 一律拒絕（工具層強制）。done 唯一入口 `journal task done`。
5. 卡住先把問題寫成留言再轉 needs-input（`--status needs-input` 強制帶 `--comment`）。
6. 爆炸半徑：代理可建分支／commit／推自己分支／開 MR；不可推 main、合併、碰 deploy/AWS/k3s/CI。

## 資料

```
journal-data/
  now.md            # ★ 僅人可寫；一行一編號，行序即優先度，最多三行
  tasks/<id>.md     # 一任務一檔，<id> = <task_prefix>-<四位序號>
  tasks/archive/    # 封存 = git mv 進來，位置即狀態（無 archived 欄位）
```

frontmatter（扁平，awk 可剖析）：
`id / title / status / created_at / external / claimed_by / claimed_at / heartbeat_at / heartbeat_epoch`

- `status`: backlog | ready | doing | needs-input | review | done
- `heartbeat_epoch` 是實作欄位：租約回收用整數秒比較，dash 不必解 ISO 時間。
- `external` 留空 —— 讓「不接公司 GitLab」保持可逆，要投影時填 `gitlab:...#87`。
- 內文段落順序固定：`## 描述`、`## 驗收`、`## 留言`（留言永遠最後 —— 附加式寫入靠這個）。
- worktree 目錄名帶編號（`hy-0412-endpoint-discovery`）；指向單向，任務不存 worktree 路徑。

## 狀態機

| 從 | 到 | 誰 | 觸發 |
|---|---|---|---|
| backlog | ready | 人 | `task ready`（貼標記前補描述與驗收） |
| ready | doing | 代理 | `task next`（取一件 + 認領） |
| doing | needs-input | 代理 | `task update --status needs-input --comment "…"` |
| needs-input | ready | 人 | `task ready --comment "回應"`（或 Web 回覆框） |
| doing | review | 代理 | `task update --status review` |
| review | done | 人 | `task done` |
| doing | ready | 系統 | 心跳超過 `task_lease_minutes`，`next` 時回收 |
| 任何 | archive/ | 人 | `task archive`（唯一封存路徑；系統只標「老」不動手） |

## 旋鈕（journal-data/config.yml）

```
task_stalled: idle        # now 全卡住：idle=閒置等人｜backlog=去池裡撈
task_review_limit: 3      # 待審達上限 → next 煞車不取件
task_lease_minutes: 60    # 心跳租約
task_stale_days: 7        # list 標「老」門檻
task_prefix: hy           # 編號字首
```

## 取件迴圈

每圈一次獨立 agent 呼叫（headless），取一件、做完就死，無常駐程序：

1. 排程器喚起 → `journal task next`（exit 3 = 沒事做，這圈結束）
2. 有任務 → 開 worktree（目錄名帶編號）→ 做，期間 `task heartbeat <id>`
3. 完成 `update --status review`；卡住 `update --status needs-input --comment`
4. 插隊 = 人改 now.md，下一圈生效；取件間隔就是插隊延遲上限（先 15 分鐘）

併發控制：同機靠 `.spool` 的 mkdir 鎖；跨機靠 push 衝突（`jr_git_commit_data`
push 失敗會留在本地重試）。race window 存在但窄，且撞到的代價只是重做一件。

## 驗收

- 結構性判準：關掉所有對話視窗，能不能從 tasks/ 接著做 —— 定期實際做一次。
- 第一週拿機械性工作校準；直接合併率 < 1/2 時先調任務描述，不是換模型。
- 上一版死因是只進不出 —— 這版出口是「Web/list 把老東西擺在眼前 + 人手動封存」，
  跑一個月若封存從未發生，再回來談自動化。

測試：`sh tests/task.sh`（狀態機全路徑、煞車、租約回收、冪等留言）。
