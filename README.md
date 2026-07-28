# journal

把散在各機、各 Claude session 的活動,收斂成一份能回憶、能量測「離目標多遠」的日誌工具。

**這個 repo 是專案原始碼。** 產生出來的日誌資料放在另一個 repo(見下)。

## 現況

| 項目 | 狀態 |
|---|---|
| 設計 | 已定案(v4),見 [`docs/DESIGN.md`](docs/DESIGN.md) |
| 實作 | **尚未動工** |
| 待拍板 | O3(GOALS 播種)· O5(aggregator 指定)· O7(transcript 保留期) |

## 它解決什麼

1. **回憶** —— 跨機、跨 session,把「今天做了什麼」收斂到一處
2. **目標進度** —— 對照 `GOALS.md` 的可執行 SLI,看「離終點多遠」
3. **中心** —— 多台機器各自產出,由一台聚合者合成總表

心智模型是「個人工作的可觀測性」:transcript 是熱的原始層,journal 是冷的降採樣長存層。實測壓縮比約 **1900:1**(5.8 MB/日 → 3 KB/日)。

## 兩個 repo 的分工

| repo | 內容 | 誰能寫 | agent 的憑證 |
|---|---|---|---|
| **`journal`**(本 repo) | `bin/` `lib/` `hooks/` `docs/` —— 工具本身 | 只有你,手動 push | **唯讀** |
| **`journal-data`**(尚未建立) | `daily/` `status/` `hosts/` `progress.md` —— 產出的日誌 | 每台機器自動 push | 可寫,但只限資料 |

分開的理由不只是歷史乾淨(否則 `git log` 會被每日 rollup 灌爆),更重要的是**爆炸半徑**:自動化流程的憑證只能寫資料,寫不了程式碼。若兩者同一個 repo,任何一台機器的 deploy key 外洩就等於能改 `bin/journal`,而每台機器都會 pull 並執行它。

「`git push` 就是部署」的性質仍然保留 —— 只是變成單向:你 push 程式碼,各機唯讀 pull。

## 執行形態

- `bin/journal` 是 **POSIX sh** 腳本(本機 `/bin/sh` → dash,會真的強制 POSIX)
- 硬依賴只有 `sh`、`git`、`claude`;`node`/`python3` 是**加速器**,缺了退到 `awk` 保底路徑
- 不做容器 image、不編譯二進位 —— 理由見 DESIGN.md §9

## 文件

- [`docs/DESIGN.md`](docs/DESIGN.md) —— 完整設計與交接規格(唯一 source of truth)
- [`docs/DECISIONS.md`](docs/DECISIONS.md) —— 決策記錄 D1–D18
