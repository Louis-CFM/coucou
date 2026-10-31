# Codex 分支與正式版功能比對

比對日期：2026-10-31。結論：這個分支仍有實質合併價值，主要新增 Codex 原生專案對話、受控問答與手機接續，以及讓 Codex 帳號供 Flow、筆記與語音功能使用。

## 比對基準

- **正式發行版**：[Coucou 0.5.8](https://github.com/Louis-CFM/coucou/releases/tag/v0.5.8)，tag 對應 `fa72429e22daad87f1a288cb9cdb8535e27bac6b`。以下正式版欄位指 GitHub 的 Mac 版本。
- **本輪同步的上游**：`71814ab0dc33eee0193785dd339cf31d97cc8b53`，包含 App Store 2.0 的準備修改。原始碼中的 2.0 版本號不代表已確認 App Store 上架。
- **功能範圍**：下列 Codex 原生功能屬於本分支的 GitHub Mac build。App Store build 保留上游的沙盒限制；不包含原生 Codex 子程序、憑證橋接與桌面插件。

## 仍有合併價值的差異

| 功能 | 正式版 0.5.8 | 這個分支新增的部分 | 程式證據 |
|---|---|---|---|
| ChatGPT 帳號與 Codex 聊天 | 已有 OpenAI → Use my subscription，透過已登入的 Codex CLI 回答 | 獨立的 Codex 選項、程式內 OAuth、明確登入狀態與本機中斷連線、原生串流／模型／附件 | [正式版 ChatSubscription](https://github.com/Louis-CFM/coucou/blob/v0.5.8/NotchBuddy/Sources/App/ChatSubscription.swift)、[CodexChatService](../NotchBuddy/Sources/App/CodexChatService.swift)、[CodexConnection](../NotchBuddy/Sources/App/CodexConnection.swift) |
| 專案目錄與原生工作階段 | 通用 CLI 文字聊天；沒有本分支的原生 thread 管理服務 | 選擇／沿用專案目錄、跨回合保留自有 thread，預設唯讀並提供明確寫入選項；保留多工作階段身分 | [CodexChatService](../NotchBuddy/Sources/App/CodexChatService.swift)、[AppState](../NotchBuddy/Sources/App/AppState.swift)、[HookServer](../NotchBuddy/Sources/App/HookServer.swift) |
| Codex 提問、權限與回答 | 已有通用提問佇列和 Codex 權限 hooks | 自有原生對話的選項／文字提問、原生權限決策，以及桌面插件的提問回傳；回答核對原始 request／thread／turn／socket | [CodexEventAdapter](../NotchBuddy/Sources/App/CodexEventAdapter.swift)、[AskQuestion](../NotchBuddy/Sources/App/AskQuestion.swift)、[桌面插件說明](../NotchBuddy/Resources/CodexDesktopPlugin/README.md) |
| iPhone 接續 Codex | 已有 iCloud 連線、通用卡片及 Claude/Cursor 指令路徑 | Codex 自有閒置對話的指令／Siri 接續、受限回合紀錄與差異、具身分檢查的問答／權限回覆；拒絕舊目標與敏感答案外送 | [正式版 InstructionRunner](https://github.com/Louis-CFM/coucou/blob/v0.5.8/NotchBuddy/Sources/App/PhoneLink/InstructionRunner.swift)、[InstructionRunner](../NotchBuddy/Sources/App/PhoneLink/InstructionRunner.swift)、[QuestionRelay](../NotchBuddy/Sources/App/PhoneLink/QuestionRelay.swift)、[TurnRecorder](../NotchBuddy/Sources/App/PhoneLink/TurnRecorder.swift) |
| 使用額度與 token | 已有 Codex 五小時／每週額度儀表 | Agents 詳細狀態、額度剩餘／重設時間、自訂用量視窗，以及可取得時的帳號／日別／特定 thread token；資料不足時明示無法取得 | [正式版 CodexPlanGauge](https://github.com/Louis-CFM/coucou/blob/v0.5.8/NotchBuddy/Sources/App/CodexPlanGauge.swift)、[CodexAgentsInfo](../NotchBuddy/Sources/App/CodexAgentsInfo.swift)、[CodexUsageViews](../NotchBuddy/Sources/App/CodexUsageViews.swift) |
| Flow、Notetaker 與語音的 Codex 引擎 | Flow 使用 Anthropic API；筆記提供 Claude／Apple／Off；自然語言語音工具由 Claude 驅動 | 可使用 Codex 帳號進行口述整理、提示詞轉換／翻譯、筆記摘要／校正、語音動作與網頁回答；失敗保留原文，背景功能需另行明確啟用 | [正式版 FlowCleanup](https://github.com/Louis-CFM/coucou/blob/v0.5.8/NotchBuddy/Sources/App/FlowCleanup.swift)、[FlowCleanup](../NotchBuddy/Sources/App/FlowCleanup.swift)、[NoteTaker](../NotchBuddy/Sources/App/NoteTaker.swift)、[ClaudeVoiceBrain](../NotchBuddy/Sources/App/Voice/ClaudeVoiceBrain.swift)、[CodexTextService](../NotchBuddy/Sources/App/CodexTextService.swift) |
| 原生計畫與重要修改 | 已有一般差異卡；通用 Codex CLI 聊天沒有本分支的原生事件橋接 | 原生計畫步驟、完成檔案變更與累積 diff 校正、重新命名／空檔案、工作階段間的差異搬移與手機快照 | [CodexEventAdapter](../NotchBuddy/Sources/App/CodexEventAdapter.swift)、[CodexTurnState](../NotchBuddy/Sources/App/CodexTurnState.swift)、[DiffEngine](../NotchBuddy/Sources/CoucouKit/DiffEngine.swift) |
| Codex 安裝／來源診斷 | 已有 Codex hooks 安裝入口，偵測到任一 Coucou hook 即視為已安裝 | 完整／停用／未信任／被修改／不完整／未知狀態、CLI 與本機 VS Code 擴充版本資訊；Codex Desktop／ChatGPT host／編輯器來源與返回動作 | [正式版 HookServer](https://github.com/Louis-CFM/coucou/blob/v0.5.8/NotchBuddy/Sources/App/HookServer.swift)、[CodexAgentsInfo](../NotchBuddy/Sources/App/CodexAgentsInfo.swift)、[SessionTarget](../NotchBuddy/Sources/App/SessionTarget.swift) |

背景文字請求使用獨立程序、thread、工作目錄及專用鑰匙圈項目，不重用專案對話，也不匯入原生 refresh token。Mail 本身已在上游；本分支補的是原生 Codex 的郵件摘要／計畫格式路由，執行郵件動作仍需使用者確認。

## 已重疊的功能

這些不應再列為分支獨有的主要賣點：

- macOS 支援、Mac 繁體中文介面、基本 Codex 訂閱聊天。
- Codex hooks 安裝、基本額度儀表、通用多工作階段、提問佇列與權限卡。
- Mail、設定搜尋、角落顯示、關閉畫面後保留提問及回答後恢復權限卡。
- Dock 顯示開關。分支差異是預設不顯示於 Dock、保留既有偏好，以及明確保證關閉最後視窗不結束服務；正式版本來就有 Dock 開關。

本輪也保留上游 App Store 2.0 的聊天口述、角落選擇、返回來源應用程式、hooks 寫入預覽、版本／隱私資訊。這些屬於上游功能，不計入分支新增功能。

## 合併判斷與限制

建議保留 PR，主題聚焦在「Codex 原生互動及助手功能擴充」。一般訂閱聊天仍保留上游路徑；原生 Codex 擁有自己的對話生命週期。兩者並存時，切換或重設後的舊回覆不能混入新對話。

- **外部 Codex Desktop 內建提問仍無法任意攔截。** 本分支可回覆的是 Coucou 建立的原生對話，或安裝並啟用後明確呼叫 `$coucou-question` 的桌面插件提問。來源辨識不會取得另一個程序的對話控制權。
- iPhone 接續要求 GitHub Mac build 正在執行、已連結 iCloud，且目標仍是 Coucou 擁有的同一個閒置對話。外部 Desktop／IDE 對話不會因此取得手機接續能力。
- 額度／token 資料取決於原生服務可提供的資訊；這不是帳單金額估算器。
- 本分支沒有新增 Windows／Linux 的上述原生整合，也不能宣稱與 Claude Code 所有功能完全等同。
- 功能判定來自正式 tag、上游與分支的原始碼比對。自動 fixtures 與未簽署建置不等於真實帳號、鑰匙圈、插件信任、Mail、語音或 iPhone／CloudKit 的實機驗收；最新檢查結果記錄於 [PR #315](https://github.com/Louis-CFM/coucou/pull/315)。
