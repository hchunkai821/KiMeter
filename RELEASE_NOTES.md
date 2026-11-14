## 安裝

1. 下載下方的 **KiMeter-macOS.zip**，解壓縮後把 `KiMeter.app` 拖進「應用程式」。
2. 第一次開啟：到「系統設定 → 隱私權與安全性」按 **強制打開**，或在終端機執行
   `xattr -dr com.apple.quarantine /Applications/KiMeter.app`
3. 點選單列的能量條，依 README 的「登入」段落完成登入。


## 這個版本

第一個正式版本：像素風用量追蹤、能量波三階段、自訂用量門檻與通知、三種登入方式、喚醒與離線處理、登入到期提醒，以及多項安全性保護（詳見 README 的「安全性」）。需要 macOS 13 以上，同時支援 Apple 晶片與 Intel。

本檔案由 GitHub Actions 從原始碼自動編譯並發佈，作者不會手動上傳，已發佈的版本也不會被覆蓋。

## 安全提醒

KiMeter 只在 https://github.com/hchunkai821/KiMeter 發布，完全免費，沒有任何代幣，也絕不會向你索取登入資訊。請用下方的 SHA-256 核對下載檔：

```
shasum -a 256 ~/Downloads/KiMeter-macOS.zip
```
