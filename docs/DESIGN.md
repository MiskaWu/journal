# 設計與交接規格

完整規格目前仍在 artifact,**尚未移植進本 repo**。本檔暫作索引。

- 決策記錄:[DECISIONS.md](DECISIONS.md) —— D1–D18 與待拍板項目
- 完整規格 v4(架構、三層 cadence、中心與權責、安裝與納管、依賴策略、韌性設計、建置階段):
  <https://claude.ai/code/artifact/fc63c628-49ff-4413-9f57-b05a978625b6>

## TODO

把 artifact 完整移植成 markdown,讓本 repo **自足** —— 接手的 agent 可能沒有 claude.ai 存取權,而規格是交接的唯一 source of truth。

移植時需一併更新的地方(artifact 目前仍是 v4,寫的是單一 repo):

- §2 佈局:拆成兩個 repo(D18),`daily/` `status/` `hosts/` `progress.md` 移到 `journal-data`
- §8 納管:`journal init` 要處理**兩個 remote** —— 程式碼 repo 唯讀 clone、資料 repo 可寫
- D12 憑證:per-host deploy key 只掛在**資料 repo**;程式碼 repo 用唯讀 key 或公開 clone
- D13:「push 即部署」改述為**單向**
