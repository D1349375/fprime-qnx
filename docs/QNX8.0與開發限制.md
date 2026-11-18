# QNX 8.0 是什麼 & 對開發的限制

> 調研日期:2026-11-12
> 來源:QNX Everywhere release notes(2026-09-24 版)、QSTI for Raspberry Pi 指南、SDP 8.0 release notes、QNX 官方部落格、Rust 官方平台文件、過往得獎作品的開發心得

---

## 1. QNX 是什麼

**QNX 是一套即時作業系統(RTOS)**,BlackBerry 旗下。跟 Linux、Windows 一樣是作業系統,但設計目標不同:

| | 一般 OS(Linux / Windows) | QNX |
|---|---|---|
| 目標 | 平均效能高、功能多 | **保證時間**:這件事一定在 X 微秒內做完 |
| 核心架構 | 單體核心(驅動程式、檔案系統都在核心裡) | **微核心**(核心只管排程、IPC、中斷;驅動程式、檔案系統、網路都是一般 process) |
| 驅動程式掛了 | 可能整台當機 | 只是一個 process 掛掉,可以重啟它,系統繼續跑 |
| 用在哪 | 伺服器、桌機、手機 | 汽車(官方宣稱 2.75 億輛車)、醫療設備、工廠、火車、機器人 |

官方主頁那句話講得最直白:它保證的不只是程式會跑,還保證**什麼時候**跑。

### QNX 的幾個招牌機制(本屆「Best Use of QNX-specific Technologies」加碼獎點名的就是這些)

| 機制 | 白話說明 |
|---|---|
| **Native message passing** | process 之間用 `MsgSend` / `MsgReceive` 同步傳訊息,這是整個 OS 的骨幹。連你 `write()` 一個裝置檔,底層也是送訊息給負責的 process |
| **Resource manager** | 你寫一支普通程式,把自己註冊成 `/dev/xxx`,別人用 `open/read/write` 就能跟你溝通。驅動程式就是這樣寫的 |
| **微核心架構** | 每個服務獨立、互相隔離,單一服務掛掉不會拖垮系統 |
| **即時排程** | 優先權 0–255,支援 SCHED_FIFO、SCHED_RR、SCHED_SPORADIC(給一段 CPU 預算,用完就降級);mutex 支援 priority inheritance 防止優先權反轉 |
| **Startup / boot 客製化** | 用 buildfile 定義開機映像要包含哪些程式、用什麼順序啟動 |
| **Security policies(secpol)** | 規範每個 process 能做什麼 |

### QNX 8.0 是哪一版
- QNX Software Development Platform(SDP)8.0 是目前主線,底層 OS 叫 QNX Neutrino。目前最新的小版號是 **8.0.5**(2026-09 QNX Everywhere 更新)
- 8.0 的工具鏈以 **GCC 12** 為基礎(SDP 8.0 產品簡介)
- **QNX Everywhere**:從 2024 年底起非商業用途免費,內容包含 SDP 8.0、Developer Desktop、Hypervisor。官方強調這是「跟商用出貨同一套」,不是教學版

---

## 2. 對你開發的限制

### 2.1 開發主機(你的電腦)

| 項目 | 事實 | 對你的影響 |
|---|---|---|
| 支援的主機 OS | **Windows 10/11 64 位元**、**Ubuntu 22.04 / 24.04**(另有 RHEL 9) | 你的 Windows 11 可以裝 SDP |
| 不支援 | **macOS、ARM 主機**(8.0.4 release notes 明寫) | 組員如果用 Mac 會卡住 |
| **QEMU 快速映像(QSTI for QEMU)** | release notes 明寫:**只能在 Ubuntu 22.04 / 24.04 上用** | 在 Windows 上走 QEMU 要另外準備 Ubuntu(WSL2、VM 或雙系統)。release notes 列了幾個 **WSL 下的已知問題**(CTI 建置語法錯誤、Pi 5 BSP 在 WSL 編不過,都附了 workaround) |
| 已知問題 | 主機記憶體 **>32 GB 時 QEMU 的 Screen 圖形服務起不來**(有 workaround) | 要看你的電腦規格 |

### 2.2 目標平台(程式跑在哪)

兩條路:

**A. Raspberry Pi 4 / 5(實機)**
- 官方要求:**8 GB RAM 以上**、**32 GB 以上** micro SD
- 用 Raspberry Pi Imager 把 `.img` 燒進 SD 卡就能開機;Windows 主機可以做這件事
- 鍵盤要 **USB**,**藍牙鍵盤不支援**
- **所有查到的過往得獎作品都用 Pi 4B 或 Pi 5**

**B. QEMU(模擬器)**
- 規則明寫可以參賽、官方說不需要硬體
- 限制:沒有真的 GPIO / I2C / 相機可以接,demo 影片只能拍螢幕
- 規則要求影片「拍到專案在它被設計的裝置上運作」,QEMU 作品的裝置就是 QEMU
- 本屆已有公開作品走這條路(例如床邊監測器、CAN FD 驅動、各種工具)

### 2.3 程式語言與套件

| 語言 / 工具 | 狀態 |
|---|---|
| **C / C++** | 主力,用 `qcc` 交叉編譯(GCC 12 基礎) |
| **Rust** | SDP 8.0.3 起官方支援(Rust 1.85,支援 core / alloc / backtrace / std);Rust 官方 target 叫 `aarch64-unknown-qnx`,**不提供預編譯的標準函式庫**,要自己建 |
| **Python** | target 上有 Python 3.11 和 pip;**已知問題:用 pip 裝 OpenCV 會失敗**(有手動搬移的 workaround);官方 Hardware Interfacing Guide 有 Python 的 GPIO / SPI API |
| **套件管理** | Developer Desktop 上可以用 `apk`(Alpine 那套)裝套件,也能**直接在 QNX 上原生編譯**,不用交叉編譯 |
| **ROS 2** | 2026-06 起有 ROS 2 APK |
| **GUI** | QNX Screen API(原生)、Qt、GTK;Godot 遊戲能跑 |
| **開發 IDE** | QNX Toolkit for VS Code(建置、執行、除錯)、QNX Momentics IDE |

### 2.4 圖形與 AI 運算

| 項目 | 事實 |
|---|---|
| GPU(Pi 5) | OpenGL ES 3.1(Mesa 25.1.8)、Vulkan 1.3(V3DV 驅動) |
| AI 加速 | **沒有 CUDA**,Pi 上的 AI 推論基本上**靠 CPU** |
| 過往得獎作品實際跑過的 AI | llama.cpp + Qwen2.5-0.5B 量化版(Praxis)、Whisper + TFLite MobileNetV2(Rocko)、OpenCV、MediaPipe(官方有 Python MediaPipe 相機 codelab) |
| 常見架構 | 「QNX 管即時與感測,重的 AI 放雲端或另一台 Linux」:SpideyIRL、Sixth-Sense、Combadge 都這樣做 |

### 2.5 周邊硬體

| 類型 | 官方支援清單 |
|---|---|
| 相機 | **Raspberry Pi Camera Module 3**、Zed 2 雙目相機、LI-USB30-OV10635、**Logitech C920**、**Intel RealSense D435**(2026-09 新增);也有相機模擬 / 影片播放模式 |
| 相機已知問題 | Camera Module 3 **Wide 版畫面偏暗**(會影響 MediaPipe),要手動調曝光 |
| 音訊 | WAV / AAC 播放、錄音;Pi 4 可以用 3.5 mm 耳機,**Pi 5 要用 USB 耳機** |
| 觸控螢幕 | 只列了幾款 Lilliput、Gechic、ASUS ProArt |
| GPIO / I2C / SPI | 有;官方 GitLab 有很多元件的範例程式(伺服馬達、LED、溫濕度、旋轉編碼器、SPI/I2C) |
| 已知問題 | **超頻 Pi 會讓 GPIO 序列埠失效**;多台 Pi 5 在同一網路會撞同一個 Wi-Fi MAC |

過往場次的 QNX 官方也提醒過:「相機只支援非常特定的型號」。

### 2.6 從 Linux 移植過來會遇到的坑

**QNX 不是 Linux**:Linux 的執行檔不能直接跑,程式要重新編譯成 QNX 版本。QNX 有 POSIX 相容層,所以大部分 C/C++ 程式改一點就能編,但有已知差異。QNX 官方部落格(2026-10)列出的常見問題:
- socket 函式在 `libsocket`,不在 libc(要加連結參數)
- **預設 thread stack 很小**
- `uname -m` 回傳 `x86pc`
- 系統標頭檔用了 `static inline`,**需要 C99 以上**,強制 `-std=c89` 的專案會編不過
- Linux 專屬的標頭與 API 要換成 QNX 對應的版本(官方有 Linux Porting Guide)

過往參賽者的回饋(G.U.R.T 團隊):初始設定、函式庫不齊、Pi 5 上 OpenCV 要自己編、交叉編譯流程、在 Windows 上用 qcc,都花了很多時間。官方部落格也承認大多數黑客松參賽者「週末才第一次接觸 QNX」。

### 2.7 AI coding agent 的支援
- QNX 官方 2026-10-29 發文:**移植開源套件很適合交給 AI coding agent 做**。他們把 QNX 移植知識寫成 Markdown skill 檔放在 GitHub 上,讓 agent 透過 SSH 連到 Developer Desktop,直接在 QNX 上原生編譯、測試
- 本屆已經有參賽者做了 QNX 的 MCP server(qnx-mcp、QNX Host MCP)

### 2.8 授權限制
- QNX Everywhere 是**非商業授權**
- 規則:作品不能曾經從 QNX 拿過**商業授權**、資金或委託開發

---

## 3. 比賽規則加上去的限制(連到技術面)

| 規則 | 技術上代表什麼 |
|---|---|
| repo 要證明「**真的在 QNX 8.0 上建置或執行**」,README 寫有 QNX 不算 | repo 裡要有 QNX 的 buildfile、Makefile(qcc)、QNX API 呼叫等看得到的證據 |
| 建置說明要寫 **QNX 版本、target(實機或 QEMU)、toolchain** | 例如:SDP 8.0.5 / Raspberry Pi 5 / qcc aarch64le |
| 說明裡要**指出哪些檔案、函式能證明有用 QNX** | Stage One 是 pass/fail,沒寫清楚就可能直接出局 |
| 評審**可能不實際編譯**,只看影片和說明 | 影片要能讓人看出「QNX 在做什麼、為什麼一定要用 RTOS」 |
| 評分標準「Potential Impact」要求說明**為什麼一定要用即時作業系統** | 作品的時序、可靠性需求要能被講清楚(例如量測到的延遲、jitter、故障復原) |

---

## 4. 參考連結

- [QNX Everywhere release notes](https://www.qnx.com/developers/docs/qnxeverywhere/rel_notes.html)
- [QSTI for Raspberry Pi 指南](https://www.qnx.com/developers/docs/qnxeverywhere/com.qnx.doc.target_images/topic/qsti/intro.html)
- [QNX SDP 8.0 GA release notes(主機 OS)](https://www.qnx.com/developers/docs/relnotes8.0/com.qnx.doc.release_notes/topic/sdp8_rn.html)
- [QNX SDP 8.0.3 release notes(Rust)](https://www.qnx.com/developers/docs/relnotes8.0/com.qnx.doc.release_notes/topic/8.0.3_prod_release_notes/8.0.3_rn.html)
- [QNX SDP 8.0.4 release notes(不支援 macOS / ARM 主機)](https://www.qnx.com/developers/docs/relnotes8.0/com.qnx.doc.release_notes/topic/8.0.4_prod_release_notes/8.0.4_rn.html)
- [Pi 5 圖形 BSP release notes](https://www.qnx.com/developers/docs/BSP8.0/com.qnx.doc.bsp.releasenotes/topic/rel_gfx.sdp80.PUA2025-010.bsp.broadcom.rpi5.bcm2712.html)
- [Rust 官方:nto-qnx 平台支援](https://doc.rust-lang.org/rustc/platform-support/nto-qnx.html)
- [QNX 部落格:用 AI coding agent 移植到 QNX](https://qnx.software/en/blog/2026/porting-to-qnx-with-ai-coding-agents)
- [QNX @ Hack The North 活動頁(硬體清單、相機限制)](https://devblog.qnx.com/htn/)
