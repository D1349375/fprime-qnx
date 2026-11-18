# F Prime on QNX:AI 深化方向

> 調研日期:2026-11-12
> 前提:移植 NASA F Prime 到 QNX 8.0(D2);AI 要當核心,不是在現成元件上外掛(依你的原則「AI 要當核心不後補」、「先分析痛點再長出架構」)

---

## 1. 痛點:機上 AI 為什麼還很少真的上太空

| 痛點 | 證據 |
|---|---|
| **任務需要機上自主判斷** | 地面監控受下行排程限制。JPL 的 Telemanom 論文就是配合 SMAP 衛星每 70 分鐘一次的下行,批次評估遙測 |
| **傳統故障偵測只認得已知故障** | 傳統 FDIR(故障偵測、隔離、恢復)靠預設門檻、確認時間和人工監督,對**緩慢劣化和未知故障**無能為力(arXiv 2604.08424,2026-04) |
| **機上 ML 卡在「信任、認證、可解釋性」** | 同一篇論文把可解釋性列為部署的前提條件;目前沒有查到任何機構發布接受 ML 型 FDIR 的正式認證標準 |
| **太空計算資源有限,主流 ML 工具太重** | SmallSat 2026 論文:Python 生態要直譯器和大量依賴,機上 ML 「幾乎必須」用輕量工具(Curtin 等,mlpack + F Prime) |
| **ML 元件本身可能出事** | ML 推論可能卡住、吃光 CPU、記憶體爆掉或當掉。飛行軟體不能因為 ML 出錯就跟著掛 |

**關鍵連結**:前四點說明機上 AI「有需求但不敢放」,第五點正是 QNX 的強項(微核心隔離、即時排程、process 掛掉可以重啟)。**AI 是這個專案存在的理由,QNX 讓它變得可以部署**,而不是移植完再補一個 AI 功能。

---

## 2. 已經存在、可以直接站上去的東西(查證結果)

| 東西 | 狀態 | 意義 |
|---|---|---|
| **fprime-mlpack-reference** | F Prime 社群官方參考實作(2026-11-09 建立),元件 `KDEAnomalyDetector` 用 mlpack 的核密度估計偵測遙測異常 | F Prime 官方正在推機上 ML |
| **SmallSat 2026 論文** | 「Lightweight Open Source On-Spacecraft ML With mlpack and F Prime」,宣稱是 F Prime 內第一個可運作的機上 ML 異常偵測,已在實機驗證 | 學術背書 |
| **mlpack、armadillo、ensmallen、cereal、OpenBLAS** | **qnx-ports 都已移植** | F Prime 移植完成後,官方的 ML 元件有機會直接在 QNX 上跑 |
| **onnxruntime** | qnx-ports 已移植 | 可以跑神經網路模型 |
| **F Prime Hub pattern(GenericHub)** | 官方設計模式,把 port 呼叫跨 process / 跨處理器傳送。官方多核心指南建議在 Linux 上用 named message queue 或 pipe 當傳輸層 | **可以把 ML 拆到獨立 process**,傳輸層改用 QNX message passing |
| **NASA SMAP / MSL 遙測異常資料集** | 真實衛星與好奇號火星車的遙測,105 段專家標註異常(Telemanom,KDD 2018);Kaggle 可下載,**授權未標明** | 用真實太空資料 demo |
| **ESA OPSSAT-AD 資料集** | OPS-SAT 立方衛星機上遙測,2,123 段、20% 異常、附 30 種演算法基準;**Zenodo,CC BY 4.0**,約 18 MB | 授權清楚,而且原本就是為機上異常偵測設計的 |

### 一個要修正的前提
- **QNX 8.0 不支援 adaptive partitioning(APS)**。QNX 8.0 IDE 官方文件明寫不支援,QNX 員工在論壇說它不符合新排程器的設計,建議改用 **sporadic scheduling 和 per-thread runtime clock**
- 本屆 VitalPulse 那件作品的標語宣稱在 QNX 8.0 上用了 APS,跟官方文件矛盾
- 我們限制 ML 用多少 CPU,要靠 SCHED_SPORADIC、runtime clock 和資源上限(rlimit)

---

## 3. 三個 AI 深化方向

### 方向 A(核心):可以被關住的機上 AI —— Containable Onboard ML

**一句話**:讓 NASA 飛行軟體在 QNX 上跑機上 AI 異常偵測;AI 出任何事(卡住、吃光 CPU、當掉),飛行軟體照常準時運作,AI 自動重啟。

**架構**
```
┌─ Process 1:飛行軟體(F Prime 主 deployment)─────────┐
│  Rate groups(SCHED_FIFO 高優先權)、指令、遙測、事件   │
│  TlmSplitter ──→ GenericHub ═══╗                       │
└────────────────────────────────╫───────────────────────┘
                QNX message passing(新寫的 Hub 傳輸層)
┌─ Process 2:ML deployment ──────╫───────────────────────┐
│  GenericHub ──→ 異常偵測元件                            │
│   ├ KDE(官方 mlpack 參考實作)                          │
│   └ 神經網路偵測器(LSTM / autoencoder)                 │
│  SCHED_SPORADIC 預算 + rlimit 記憶體上限                │
└────────────────────────────────────────────────────────┘
        ↑ 掛掉 / 卡住 → 由監看機制偵測並重啟,Process 1 不受影響
```

**AI 的部分(核心,不是外掛)**
1. 移植官方 `KDEAnomalyDetector`(mlpack)到 QNX,當 baseline
2. 加一個神經網路偵測器,用 **SMAP/MSL 與 OPSSAT-AD 的真實太空遙測**訓練,模型在主機上訓練,推論在 QNX 上跑(mlpack ANN 或 onnxruntime)
3. **可解釋輸出**:不只說「異常」,還指出是哪個遙測通道、偏離多少(回應「可解釋性是部署前提」這個痛點)
4. 用真實資料集回放遙測,量化偵測準確度

**QNX 原生機制(對應 Best Use 加碼獎)**
- 為 GenericHub 寫 **QNX message passing 傳輸層**(取代 Linux named message queue)
- ML process 用 **SCHED_SPORADIC** 限制 CPU 預算、rlimit 限制記憶體
- 微核心隔離 + 自動重啟
- F Prime 的 `Os::Queue`、`Os::Task` 用 QNX 原生機制實作(移植本體)

**demo 影片能量化的東西**
- 在真實太空遙測上的偵測成績(precision / recall)
- 故障注入:故意讓 ML 無窮迴圈、記憶體爆量、直接 kill → 飛行軟體 rate group 的時序不受影響,ML 自動恢復
- 對照組:同一份程式在 Linux 上,ML 失控時飛行軟體 jitter 的變化

**評分對應**

| 評分項 | 怎麼對上 |
|---|---|
| Technological Implementation | F Prime OS 層 + QNX Hub 傳輸層 + ML 元件,三層都是真實工程 |
| Design | GDS 地面站畫面能看到遙測、異常事件、ML 重啟過程,是完整的操作體驗 |
| Potential Impact | 直接回應「機上 ML 不敢放」的產業痛點,說明為什麼必須用 RTOS |
| Innovation & AI | AI 是核心;「用作業系統架構讓 AI 可以被信任」是非顯而易見的 QNX 用法 |
| Best Use of QNX(加碼) | message passing Hub、sporadic 排程、微核心隔離 |
| Best Codelab(加碼) | 「在 QNX 上部署 NASA F Prime + 機上 ML」 |

**風險**
- 本屆已有好幾件作品用「AI + 確定性守門員」的模式:Tether(呼吸器)、Split Loop(機械手臂)、QNX-CortexCage、NeuroGuard-RT、qsentry(抓說謊的感測器)。不過它們都在其他類別,而且都是自製應用;我們的差異是「NASA 飛行框架 + 官方 ML 參考實作 + 真實太空遙測」
- SMAP/MSL 資料集授權沒標明;OPSSAT-AD 是 CC BY 4.0,比較保險
- 工作量最大的是 F Prime OS 層和 Hub 傳輸層,ML 本身相對輕

### 方向 B(A 的延伸):從「偵測」走到「建議恢復」

**一句話**:AI 不只發現異常,還**建議恢復動作**(例如切換到備援、進入安全模式);但動作要通過一組確定性的安全規則才會執行。

- 這就是 FDIR 的 I(隔離)和 R(恢復),回應「傳統 FDIR 對未知故障無能為力」
- 安全規則跑在高優先權的飛行軟體 process,AI 只能提建議、不能直接下指令(simplex / runtime assurance 架構;搜尋結果顯示這是學界提出的主要做法)
- 風險:跟方向 A 那幾件「AI + 守門員」作品的相似度更高;恢復動作的設計需要對太空任務有更多理解

### 方向 C(可選,呈現層):地面端 LLM 操作助理

**一句話**:在 GDS 地面站旁接一個 LLM,把機上 AI 發出的異常事件翻成白話給操作員,並把操作員的自然語言意圖轉成 F Prime 指令序列,先對照指令字典驗證才上傳。

- 先例:JPL 工程師用 Claude 規劃毅力號約 400 公尺的行駛路線(Anthropic 官方文章,屬廠商自述)
- 優點:LLM 用雲端 API,對你的電腦沒負擔
- **缺點**:LLM 跑在地面端、不在 QNX 上,對「用 QNX」沒加分;而且容易變成你說過要避免的「在既有元件外掛 LLM」
- 建議只當 demo 的呈現層,不當主打

---

## 4. 建議

**以方向 A 為核心,B 當深化選項,C 視時間決定要不要加在呈現層。**

理由:
1. A 是從痛點長出來的:「機上 AI 不敢放」→「需要隔離、限額、可重啟」→ QNX 微核心正好解這個問題。AI 跟 QNX 互為存在理由
2. 站在 F Prime 官方剛發布的 mlpack 參考實作和 SmallSat 2026 論文上,敘事有權威背書
3. 所有 ML 依賴在 QNX 上都已移植,技術風險集中在 F Prime 移植本體(本來就要做的)
4. 模型很小(KDE、小型 LSTM / autoencoder),訓練在主機 CPU 就跑得動,推論在 QEMU 上負擔很輕

### 工作量(依證據列出,不先砍)
| 工作項 | 依據 |
|---|---|
| F Prime OS 層 + 平台 cmake / toolchain | 參考 fprime-vxworks,約 5.6 萬字元 C++ |
| GenericHub 的 QNX message passing 傳輸層 | 新寫;官方有 fprime-generic-hub-reference 兩 deployment 範例可參考 |
| 移植 fprime-mlpack-reference | 依賴都已在 qnx-ports |
| 神經網路偵測器 + 訓練 + 可解釋輸出 | 主機端訓練;資料集現成 |
| 故障注入與 Linux 對照量測 | 量測腳本 |
| GDS demo、影片、Codelab、英文文件 | 交件必備 |

距截止(台灣 12/16 03:00)約 33 天。

---

## 5. 參考來源

- [SmallSat 2026:Lightweight Open Source On-Spacecraft ML With mlpack and F Prime](https://digitalcommons.usu.edu/smallsat/2026/all2026/66/)
- [fprime-mlpack-reference](https://github.com/fprime-community/fprime-mlpack-reference)
- [arXiv 2604.08424:On-board Telemetry Monitoring in Autonomous Satellites](https://arxiv.org/abs/2604.08424)
- [Telemanom(JPL,KDD 2018)](https://github.com/khundman/telemanom)、[論文](https://arxiv.org/abs/1802.04431)
- [OPSSAT-AD 論文](https://arxiv.org/abs/2407.04730)、[Zenodo 資料集(CC BY 4.0)](https://doi.org/10.5281/zenodo.12588359)
- [F Prime Hub pattern](https://fprime.jpl.nasa.gov/latest/docs/user-manual/design-patterns/hub-pattern/)、[多核心指南](https://fprime.jpl.nasa.gov/latest/docs/user-manual/framework/run-multi-core/)
- [QNX 8.0 IDE:APS view(8.0 不支援 adaptive partitioning)](https://qnx.com/developers/docs/8.0/com.qnx.doc.ide.userguide/topic/APS_view.html)、[QNX 論壇討論](https://community.qnx.com/sf/go/projects.core_os/discussion.newcode.topc28434)
- [Claude 規劃毅力號行駛路線(Anthropic)](https://anthropic.com/features/claude-on-mars)
- [ESA:ML-based on-board autonomy](https://nebula.esa.int/content/machine-learning-based-board-autonomy-failure-prognostics-and-detection)
