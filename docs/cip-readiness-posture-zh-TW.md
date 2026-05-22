# cip-readiness-posture.md — OptiVaults V1 對 Cardano Improvement Proposals 的立場

**範圍**：OptiVaults V1 與 Cardano Improvement Proposal 流程之間的關係 — V1 目前直接使用了哪些 CIP、V1 自己實作的哪些東西未來有可能成為 CIP、以及在什麼條件下 V1 才會真的去撰寫或共同撰寫提案。

本文件為**資訊性質**。它不是一份 CIP、也不是 CIP 草案，更不是任何模式日後一定會被標準化的承諾。它是專案對社群的一份公開立場宣告：當 V1 內部文件在合約程式碼旁邊談到「模式背景說明（pattern rationale）」時，社群可以據此判斷該如何看待這些討論的份量。

---

## 1. 立場

OptiVaults V1 **直接採用既有的 CIP**，並**準備 — 但不提交 — 未來有可能成為 CIP 提案基礎的模式說明文件**。V1 在 V1 階段不會撰寫任何 CIP 提案。

理由很直接。一位 CIP 作者理應具備：

1. 一份已在主網實際負載下運行過的可用實作。
2. 來自獨立第三方的設計健全性確認 — 至少要有一份完成的外部安全審計。
3. 該模式足夠通用、在原始專案之外仍然有用的證據 — 最理想的情況是有不相關團隊做出第二份實作。
4. 一段社群討論期，在進入規格之前先暴露粗糙的角落。

V1 目前 (1)–(4) 都尚未完成。主網上線仍在準備中，外部審計排在 2027 Q2–Q3，沒有第二份實作，而對這些模式進行更廣泛的社群討論也為時過早。在這個基礎工作完成前就提交 CIP，要嘛產出一份事後必須撤回的規格、要嘛更糟 — 在生態系尚未看清弱點之前，就把一個不夠理想的模式錨定下來。

V1 的文件因此採取另一種形式：與 V1 規格放在一起的**模式背景說明筆記**（`spec/pattern-rationale-*.md`）。這些筆記用通用語言描述每個模式、把具體的 V1 實作當作範例引用、並明確把「標準化」的措辭留給未來 Phase 3+ 的工作。

---

## 2. OptiVaults V1 為未來 CIP 可能性所撰寫的模式文件

| # | 模式（公開名稱） | V1 實作 | 背景說明文件 |
|---|---|---|---|
| 1 | Validator Identity NFT | Vault NFT、Governance NFT、Registry Auth NFT（one-shot mint、以 UTXO ref 錨定） | `spec/pattern-rationale-validator-identity-nft.md` |
| 2 | MultiSig Governance + Timelock | `multisig_gov.ak` — m-of-n approve、每個動作各自 timelock、1-of-n cancel、nonce 綁定 action_id | `spec/pattern-rationale-multisig-gov-timelock.md` |
| 3 | Withdraw-Zero Forwarding | `vault_proxy` + 十個被路由出去的 staking validator；16 KB 腳本大小預算切散到多個 validator，而使用者 TX 並不會因此變大 | `spec/pattern-rationale-withdraw-zero-forwarding.md` |
| 4 | Registry + Auth NFT Whitelist | `registry.ak` 持有一份可被 governance 修改的 whitelist datum，並由一顆 one-shot Registry Auth NFT 錨定 | `spec/pattern-rationale-registry-auth-nft.md` |
| 5 | VaultDatum Tiered Immutability | 29 個欄位的 VaultDatum，依四個 tier（身份不可變 / governance 可變 / accounting / 操作）切開，並透過 `check_immutable_fields` helper 強制執行 | `spec/pattern-rationale-vault-datum-tiered.md` |

這五個模式沒有一個是根本性的全新發明 — 在其他 Cardano DeFi 協議中都可以看到每一個模式的變體。V1 真正貢獻的是：**一份有文件、有審計軌跡、且鏈上可驗證的具體實作**，在這些模式之中未來真的被提案時，可以拿來當作參考實作。

---

## 3. V1 已經直接採用的 Cardano CIP

下列 CIP 是**依賴**而非候選 — V1 直接拿來用，不會提案修改。

| CIP | V1 使用方式 | 備註 |
|---|---|---|
| CIP-30 | V1 前端的 wallet ↔ dApp 連線；所有 deposit / withdraw 交易都是由使用者錢包簽名的 CIP-30 TX | 上線時實際測試過的錢包包含 Eternl、Lace、Vespr、Typhon、Yoroi；任何符合 CIP-30 的錢包理論上都能使用 |
| CIP-25 | 僅作為 NFT metadata 的形狀參考；V1 的 Validator Identity NFT（Vault NFT、Governance NFT、Registry Auth NFT）**刻意不**攜帶 CIP-25 metadata，因為它們在鏈上的角色是錨點識別，不是顯示用途 | Validator Identity NFT 的背景說明文件會解釋為什麼在這裡採用「不帶 metadata」的變體比較合適 |
| CIP-68 | V1 的身份 NFT 並未採用 CIP-68（沒有「NFT 攜帶 datum」這種設計）；V1 把狀態放在 validator datum 裡，而不是 reference NFT datum | 未來工作（Phase 3+）可能會重新評估 CIP-68 reference-NFT 變體是否能簡化跨協議的 indexing |
| CIP-69 | Plutus V3 mint-policy redeemer 形狀 — V1 的 minting policy（`vault_nft`、`governance_nft`、`registry_auth_nft`、`vusdcx`）因為都針對 Plutus V3 編譯，自然遵循 CIP-69 的 spending-and-minting 語意 | 沒有專案層面的擴充 |

下列 CIP 與 V1 文件化的某些模式**相鄰**，但 V1 的模式在 V1 階段**並未被定位為這些 CIP 的延伸**。任何未來的關係都會在假想中的提案社群討論期間再去發展。

| CIP | V1 中可能重疊的模式 | V1 立場 |
|---|---|---|
| CIP-72（DApp Registration & Discovery） | CIP-72 是一個 dApp 對外的**身份宣告**（關於 dApp 的 metadata、由 owner key 簽名、供錢包與瀏覽器在 discovery 時消費）。V1 Registry 則是一份對內的**授權 datum**（keeper 可以路由到的目的地，只給 V1 自己的 validator 消費） | 兩者位在正交軸上 — V1 可以同時發布一份 CIP-72 claim 與維護 Registry datum，兩者之間沒有任何互動。它們只是剛好共用了「registry」這個英文字 |
| CIP-95（Web-Wallet Bridge for Conway） | OptiVaults V1 目前不是一個會處理 delegation 的 dApp；存款人是獨立於 vault 之外去質押自己的 ADA | 如果 V1 的未來版本提供 delegation 相關功能，CIP-95 會是自然的整合點 |

---

## 4. V1 撰寫 CIP 的條件

專案的承諾如下：當 (a)–(d) **全部**成立時，OptiVaults 團隊會公開發布一份正式的 CIP 撰寫意向供社群討論。在那之前，模式背景說明文件單獨存在。

(a) 外部審計（2027 Q2–Q3）已完成、findings 已公開。

(b) V1 在主網上已運行至少滿一年、TVL 已突破 §6.3 的 pre-audit 上限、並且至少實際撐過一次「真的發生過」的 depeg 或外部協議壓力事件而沒有本金損失。

(c) 至少有一個獨立團隊已經 (i) 用其中一個已文件化的模式部署了衍生作品，或 (ii) 在公開場合（Cardano forum、本 repo 的 GitHub issue thread、生態系工作小組）對某個模式提出具體疑問，證明該模式在 OptiVaults 之外仍然重要。

(d) 社群治理轉移（whitepaper §10）已經跨過 founder-controlled 階段，使 CIP 的作者身份不再實質上由單一行動者壟斷。

如果 (a)–(d) 沒有全部成立，文件就以資訊性質的模式背景說明留在原處。模式本身對任何讀 V1 程式碼的人仍然有用 — 只是還沒被標準化而已。

---

## 5. 社群現在可以怎麼參與

V1 進入主網之前，最有用的社群貢獻是：

- **讀模式背景說明文件**並在 GitHub 開 issue，如果某個設計選擇看起來不清楚、與既有 CIP 不一致、或是有明顯更好的已知變體。
- **拿你自己的協議設計來對照**，如果你也在做類似的 primitive。第二份實作正是把一個模式從「這只是 OptiVaults 自己的怪癖」升格為「這是一個可辨認的 Cardano DeFi 模式」的關鍵。
- **指出相鄰的 CIP 工作** — 如果 pipeline 中已經有一份 CIP 草案與五個模式之一重疊，請把連結貼在對應 pattern-rationale 文件的 GitHub thread，讓 V1 可以及早對齊或公開討論分歧。

直接針對 CIP 議題的討論，現階段歡迎在 OptiVaults repo 上進行；專案在 §4 的 gate 滿足之前不會去 CIP repo 開 PR。

---

## 6. 明確不會被當作 CIP 候選的部分

為了避免誤會，下列 V1 元件是專案特定的，現在不會、未來也沒有被當作 CIP 候選的計畫：

- 29 個欄位的 VaultDatum schema（特定於 V1 的策略 + accounting；不具備一般性）。
- Liqwid 整合的形狀（特定於 Liqwid V2 的 per-market action-validator 設計）。
- Minswap V2 adapter 的 `hop_chain` decoder（特定於 Minswap V2 的 order datum 編碼）。
- SundaeSwap adapter 的 cancel-guard（特定於 SundaeSwap V3 + Stableswaps 的 order 形狀）。
- Keeper 授權的 stake-script 模式。它底層的*基本原語* — 一個被當作可演進授權閘道的 stake-script — 已經由 Withdraw-Zero Forwarding 模式 (#3) 涵蓋。V1 在這之上多疊的部分（從「governance-only allowlist」到「bonded permissionless」的三模式光譜、每週輪替的算術、可被沒收的 bond 經濟學、anti-replay nonce、以及 per-PKH 的 anti-spam cooldown），都是 OptiVaults 自己 keeper 模型的操作性政策 — 作為參考實作有用，但不是協議層次的 primitive。

這些都是為了可重現性與審計可追蹤性而被文件化，而不是為了標準化。

---

**文件狀態**：資訊性質。反映專案在 V1 launch readiness 階段的意向。當 §4 的條件成立、或生態系脈絡發生實質變化時會被改寫。
