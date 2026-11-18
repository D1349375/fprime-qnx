# Ports 賽道候選專案

> 調研日期:2026-11-12
> 條件:Open-Source Contribution & Ports 類別、走 QEMU 不用實機、不在本機跑大型模型、目標是得名,並同時報名兩個加碼獎(Best Use of QNX-specific Technologies、Best Codelab)

---

## 0. 篩選方法

1. **排除官方已經移植的**:qnx-ports GitHub 組織的 repo 加上 aports 配方,共 **868 個專案**(清單在 scratchpad,來源 https://github.com/qnx-ports 、https://oss.qnx.com )
2. **排除原專案本身就支援 QNX 的**:逐一搜尋原專案 repo 裡跟 QNX 有關的程式碼
3. **排除本屆已經有人做的**:Devpost 上 225 件跟 QNX 有關的作品全部比對過
4. **對照評分標準**:QNX 市場關聯性(Impact)、能不能用到 QNX 原生機制(Technological Implementation + Best Use 加碼獎)、做不做得出完整產品體驗(Design)、創意與對問題領域的理解(Innovation)

### 先釐清第四項評分標準
標題叫「Innovation & **AI** Creativity」,但官方內文是:
> Is this a creative, non-obvious use of QNX and does the team show genuine understanding of the problem space they're working in?

**內文沒有要求一定要用 AI**,實際看的是「對 QNX 的用法有沒有創意、非顯而易見」和「對問題領域的理解」。

---

## 1. 被排除的熱門選項(附原因)

| 專案 | 排除原因 |
|---|---|
| onnxruntime、llama.cpp、whisper.cpp、PyTorch、TensorFlow Lite、ExecuTorch、OpenVINO、MediaPipe、ncnn | qnx-ports 已移植 |
| ROS 2、MoveIt2、Nav2、Fast-DDS、vsomeip、zenoh、gz-sim、ruckig、osqp | qnx-ports 已移植 |
| **iceoryx2**(零拷貝 IPC) | 原專案 README 寫 QNX 8.0 已經「done」 |
| **LVGL**(嵌入式 GUI) | 原專案已有 QNX Screen 驅動與官方 QNX 文件 |
| **Cyclone DDS** | 原專案已有 `ports/qnx`(QNX 7.1) |
| **open62541**(OPC UA) | 原專案列 QNX 為 Tier 3 支援平台 |
| **SOEM**(EtherCAT master) | 原專案沒有 QNX 支援、工業價值很高,但 EtherCAT 需要實體從站,QEMU 上 demo 不出來 |
| PX4、zenoh-pico、WAMR、Elixir/Erlang | 本屆已有參賽者在做 |
| ArduPilot | 跟 PX4 那件同題材,而且規模太大 |
| KUKSA databroker(車用訊號) | 社群小(84★),本屆已有 VSS 相關作品 |

---

## 2. 候選專案

### 🥇 候選 1:NASA F Prime — 太空飛行軟體框架

| 項目 | 內容 |
|---|---|
| 是什麼 | NASA JPL 開源的飛行軟體框架,曾用於火星直升機 Ingenuity 等任務 |
| 規模 | 11,865★、Apache-2.0、今天(11/12)還有 commit |
| QNX 現況 | 原專案**沒有 QNX 支援**(搜尋只有一份文件順帶提到)、qnx-ports 沒有、本屆沒人做 |
| 原專案支援的平台 | Linux、macOS(Os/Posix);社群另有 **fprime-vxworks、fprime-zephyr、fprime-freertos、fprime-baremetal** 等獨立平台 repo |

**為什麼適合 Ports 規則**
- 社群慣例本來就是「平台移植放在獨立 repo」(例如 fprime-vxworks),**跟比賽要求的「新開 repo、用 URL 引用上游、不能交 fork」完全一致**
- fprime-vxworks 的結構可以直接當工作清單:平台 cmake、toolchain、Os 層(Task / Mutex / Queue / Console / ConditionVariable)、UART 驅動、Watchdog。規模約 5.6 萬字元 C++,一個月做得完

**對評分標準**

| 評分項 | 對應 |
|---|---|
| Technological Implementation | 要寫完整的 OS 抽象層,不是改幾個編譯參數 |
| Design | F Prime 有 GDS 網頁地面站(指令、遙測、事件),demo 影片可以呈現完整的「地面站 ↔ 飛行軟體」操作體驗 |
| Potential Impact | 航太、國防、機器人是 QNX 想服務的市場。**VxWorks 是 QNX 在這個領域的直接競爭對手**,F Prime 已經支援 VxWorks,補上 QNX 這個缺口在敘事上很直接 |
| Innovation | 把 NASA 框架的抽象層對應到 QNX 原生機制,屬於非顯而易見的用法 |

**Best Use of QNX-specific Technologies(加碼獎)的切入點**
- `Os::Queue` 用 **QNX native message passing** 實作,而不是單純套用 POSIX
- `Os::Task` 對應 QNX 優先權、SCHED_FIFO、CPU affinity(runmask)
- Watchdog 用 QNX pulse / timer 實作
- 驅動元件寫成 **resource manager**
- 用 QNX 微核心的故障隔離展示「單一元件掛掉、系統繼續跑」

**Codelab(加碼獎)**:「把 NASA F Prime 部署到 QNX 8.0」流程完整、步驟清楚,很適合寫成教學。

**AI 怎麼補**(可選):F Prime 是元件化架構,可以加一個「機上自主」元件,用已移植的 onnxruntime 跑小型異常偵測模型(小模型在 QEMU 上負擔很輕)。太空任務有通訊延遲,機上自主判斷本來就是真實需求。

**風險**
- F Prime 建置系統(fprime-util、FPP 程式碼產生器)要在 Ubuntu / WSL2 上跟 QNX 工具鏈接起來,前幾天可能卡在環境
- AI 不是本體,第四項要靠「QNX 用法的創意」拿分

---

### 🥈 候選 2:sherpa-onnx — 離線語音辨識 / 語音合成 / 喚醒詞

| 項目 | 內容 |
|---|---|
| 是什麼 | 新一代 Kaldi(k2-fsa)的離線語音工具組:串流語音辨識、TTS、喚醒詞、VAD、說話者辨識 |
| 規模 | 15,896★、Apache-2.0、C++、今天還有 commit |
| QNX 現況 | 原專案**完全沒有 QNX**(0 筆)、qnx-ports 沒有、本屆沒人做 |
| 關鍵前提 | 底層的 **onnxruntime 已經在 qnx-ports**;sherpa-onnx 的 CMake 有「使用已安裝 onnxruntime」選項 |

**對評分標準**

| 評分項 | 對應 |
|---|---|
| Technological Implementation | 要接 QNX 版 onnxruntime,並為 QNX 寫音訊擷取後端(原專案用 PortAudio,PortAudio 沒有 QNX 後端) |
| Design | 車內語音助理的 demo 很直觀:喚醒 → 辨識 → 執行 → 語音回覆 |
| Potential Impact | **車用座艙是 QNX 最核心的市場**(官方宣稱 2.75 億輛車)。完全離線的語音在隧道、山區、隱私上都有實際需求 |
| Innovation & AI | **四個候選裡 AI 最強**,AI 就是專案本體 |

**Best Use of QNX-specific Technologies 的切入點**
- 用 QNX Sound Architecture(QSA)寫原生音訊後端
- 語音服務寫成 resource manager(例如 `/dev/asr`),車上其他程式用 `read()` 就能拿到辨識結果
- 喚醒詞偵測用高優先權執行緒,在 CPU 滿載時依然準時反應

**風險**
- **qnx-ports 已經有 whisper.cpp(語音辨識)和 piper(語音合成)**,評審可能覺得「又一個語音引擎」。差異化要靠串流、喚醒詞、低延遲這些座艙需求
- QEMU 的音訊輸入不一定好用,demo 可能要改用音檔輸入
- 模型雖小(幾十 MB),但 QEMU 若沒有硬體加速(KVM)會很慢。**你的電腦在 WSL2 裡能不能用 KVM,動工前要先確認**
- 你說電腦跑不太動本地模型,這是四個候選裡最吃運算的一個

---

### 🥉 候選 3:acados — 即時模型預測控制(MPC)求解器

| 項目 | 內容 |
|---|---|
| 是什麼 | 嵌入式非線性模型預測控制(NMPC)求解器,用於自駕車、機器人、無人機的即時控制 |
| 規模 | 1,523★、BSD-2、C 語言 |
| QNX 現況 | 原專案沒有 QNX(只有 dSPACE 工具鏈)、qnx-ports 沒有(osqp 有,acados 沒有)、本屆沒人做 |
| 依賴 | BLASFEO、HPIPM、qpOASES、osqp 等,大多是純 C;BLASFEO 有 GENERIC 目標可以當備案 |

**對評分標準**

| 評分項 | 對應 |
|---|---|
| Technological Implementation | 移植本身可能不難(純 C),**深度要靠即時控制 demo**:量測控制週期、jitter、CPU 滿載下會不會錯過截止時間 |
| Design | 模擬車輛或倒單擺,畫面能看出控制效果 |
| Potential Impact | MPC 是自駕車與機器人控制的主流方法,「控制器一定要準時」正好是 RTOS 的賣點 |
| Innovation & AI | acados 支援把神經網路當動態模型(learning-based MPC),可以講「AI 學出的模型 + RTOS 保證時序 + 安全備援」 |

**Best Use 的切入點**:SCHED_FIFO 控制迴圈、QNX timer / pulse 驅動週期、控制器寫成 resource manager、跟 Linux 比較 jitter(本屆 PX4 那件就是這樣比較的)。

**風險**
- 專案知名度最低
- 移植若太順利,Technological Implementation 會被認為不夠 non-trivial,一定要做深度 demo
- 要會控制理論才講得好「對問題領域的理解」

---

## 3. 三個候選比較

| | F Prime | sherpa-onnx | acados |
|---|---|---|---|
| 知名度 | ★★★(NASA、11.9k★) | ★★★(15.9k★) | ★(1.5k★) |
| QNX 市場關聯 | 航太 / 國防 / 機器人 | **車用座艙(核心)** | 車用 / 機器人 |
| 移植工作量 | 中高(要寫完整 OS 層) | 中高(要接 onnxruntime + 音訊後端) | 低到中 |
| QNX 原生機制發揮空間 | **最大**(Queue、Task、Watchdog 天生對應) | 中(音訊、resource manager) | 中(即時迴圈) |
| AI 強度 | 弱(可加元件) | **最強** | 中 |
| 對你電腦的負擔 | 低 | **最高** | 低 |
| Codelab 題材 | 很好 | 好 | 好 |
| 主要風險 | 建置環境 | 跟 whisper/piper 重疊、運算、音訊 | 深度不足 |

## 4. 我的建議

**首選 F Prime**,理由:
1. 移植形式跟比賽規則最吻合(社群已經有獨立平台 repo 的慣例)
2. 最容易拿 **Best Use of QNX-specific Technologies**:它的 OS 抽象層剛好能一對一換成 QNX 原生機制
3. 對你的電腦負擔最低,QEMU 就能完整 demo(GDS 地面站畫面)
4. 「VxWorks 有、QNX 沒有」的缺口敘事,QNX 評審會有感

**如果你更看重 AI**,選 sherpa-onnx,但要先確認 WSL2 + QEMU 的運算速度夠用。

---

## 5. 參考來源

- QNX 已移植清單:https://github.com/qnx-ports 、https://github.com/qnx-ports/aports 、https://oss.qnx.com
- F Prime:https://github.com/nasa/fprime 、平台移植前例 https://github.com/fprime-community/fprime-vxworks
- sherpa-onnx:https://github.com/k2-fsa/sherpa-onnx
- acados:https://github.com/acados/acados 、BLASFEO https://github.com/giaf/blasfeo
- 排除依據:iceoryx2 README(QNX 8.0 done)、LVGL `docs/src/integration/rtos/qnx.mdx`、Cyclone DDS `ports/qnx/`、open62541 `arch/README.md`(QNX Tier 3)
- 本屆投稿比對:https://devpost.com/software/search?query=QNX (225 件)
