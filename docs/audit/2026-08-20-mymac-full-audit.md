# MyMac — Rà soát tổng thể

**Ngày:** 2026-08-20 · **Phạm vi:** toàn bộ repo (`Sources/`, `Tests/`, `Scripts/`, `Resources/`, `README.md`)
**Máy kiểm chứng:** macOS 26.6.1 (25G76), Apple Silicon (arm64, 8 lõi) · Swift 6, swift-tools 6.0
**Ngôn ngữ báo cáo:** tiếng Việt, giữ nguyên tên định danh/đường dẫn/chuỗi giao diện bằng tiếng Anh.

> Báo cáo này **không sửa code**. Nhiều mục cần bạn quyết định *bên nào sai* — code hay tài liệu —
> và sửa trước khi quyết định là cách nhanh nhất để biến một bug thành chính sách.

---

## Trạng thái thực hiện

| Vòng | Ngày | Nội dung | Kết quả |
|---|---|---|---|
| **1** | 2026-08-20 | P1-1 · P1-3 (git + LICENSE) · P2-3 · P2-4 · P2-7 · P3-2 | 120 test |
| **2** | 2026-08-20 | P2-1 · P2-2 · P2-5 · P2-6 | 130 test |
| **3** | 2026-08-21 | P2-9 (tách target + test tầng app) · P1-3 (CI) · P3-8 · đồng bộ README | 151 test |

**Còn lại:** toàn bộ P3 trừ P3-2 và P3-8 (vòng 4), app icon, và 6 quyết định ở mục
"Cần bạn quyết". Mâu thuẫn README #1 (Location/SSID) vẫn mở — nay đã được ghi rõ
trong README như một quyết định chưa chốt thay vì để hai đoạn nói ngược nhau.

**Sai lệch so với báo cáo gốc:**
- **P2-6** không sửa được theo cách đã đề xuất. `SceneBuilder` không có `buildEither`,
  nên không thể gắn `defaultLaunchBehavior` / `restorationBehavior` sau một
  `if #available` khi deployment target là macOS 14. Đã chuyển sang bỏ version gate ở
  `AppDelegate` để cơ chế AppKit chạy trên mọi phiên bản. Muốn dùng đúng API SwiftUI
  thì phải nâng deployment target lên macOS 15 — đó là một quyết định mới, chưa có
  trong danh sách (C).
- **P1-1** mô tả triệu chứng sai trong bản đầu; đã đính chính tại chỗ.

---

## 0. Chuẩn đối chiếu (standard of comparison)

Repo không có `docs/`, ADR hay spec riêng. Chuẩn được xếp theo thẩm quyền:

| # | Nguồn | Vai trò |
|---|---|---|
| 1 | `README.md` (27 KB) | **Nguồn chuẩn chính.** Không phải file hướng dẫn cài đặt — nó là một design doc đầy đủ: nêu rõ ý đồ kiến trúc, chính sách lấy mẫu, mô hình an toàn của cleaner, và cả những giới hạn tự nhận. |
| 2 | 109 test trong `Tests/MyMacCoreTests` (28 suite) | Ý định dạng thực thi được. Rất mạnh cho `MyMacCore`. |
| 3 | Doc comment trong source | Repo này viết doc comment ở mức hiếm thấy — nhiều comment ghi lại *lý do* của một quyết định. Được dùng như chuẩn hạng ba. |
| 4 | `Resources/Info.plist` | Khai báo quyền và hành vi bundle. |

**Không có chuẩn nào cho:** localization, chiến lược phát hành, chính sách accessibility, hỗ trợ Intel.
Những mục đó nằm ở nhóm **(C) — chưa có quy tắc**, không phải bug.

**Ranh giới:** repo **chưa được khởi tạo git** (`fatal: not a git repository`), nên không thể phân biệt
nợ kỹ thuật cũ với thay đổi mới. Mọi phát hiện dưới đây được nêu như hiện trạng, không phải lời buộc tội
về một thay đổi cụ thể nào.

**Bối cảnh phát hành bạn đã xác nhận:** dùng cá nhân/nội bộ + công khai repo GitHub để người khác clone
và tự build trên máy Mac của họ. Vì vậy **trải nghiệm clone-and-build được tính là một tính năng**, còn
notarization thì không.

---

## 1. Đánh giá chung

Đây là code chất lượng cao hơn đáng kể so với mặt bằng chung của loại app này.

- Không phụ thuộc bên thứ ba. Không Electron, không web view.
- Ranh giới `MyMacCore` (không AppKit/SwiftUI) ↔ `MyMac` được **giữ đúng tuyệt đối** — kiểm chứng bằng grep.
- Swift 6 language mode, strict concurrency, **0 warning** khi build cả debug lẫn release.
- **109/109 test pass** trong 14 giây. **0 TODO/FIXME/HACK** trong toàn bộ source.
- Đúng **một** chỗ gọi `Process()` trong cả codebase, không shell, không `sudo`, không `osascript`.
- `PathSafety` là một mô hình an toàn thật sự chắc, không phải trang trí (xem §5).

Vấn đề không nằm ở chỗ code viết ẩu. Vấn đề nằm ở **ba điểm gãy có tính cấu trúc** ở §2 — và ở chỗ
tầng app (`Sources/MyMac`) **hoàn toàn không có test**, nên các nhánh lỗi ở đó chưa bao giờ được chạy thử.

---

## 2. Ba gốc rễ chung

Phần lớn phát hiện trong báo cáo này quy về ba nguyên nhân. Sửa theo gốc rẻ hơn nhiều so với sửa 24 mục rời rạc.

### Gốc A — Vòng đời "scope" giả định không bao giờ bị dựng lại

`MetricsStore` đếm scope và **dừng hẳn** khi về 0, rồi **khởi động lại** khi có scope mới. Nhưng
đối tượng mà nó điều khiển lại là loại **dùng một lần**: `NWPathMonitor` sau `cancel()` không bao giờ
phát sự kiện nữa (đã kiểm chứng bằng thực nghiệm). Sinh ra **P1-1**. Cùng gốc này còn giải thích việc
collector giữ bộ đếm `previous` cũ và `ProcessWatcher` giữ history cũ qua một chu kỳ dừng/chạy.

### Gốc B — Văn bản mô tả một thiết kế mà code đã đi chệch

README, comment và cả **chữ hiển thị trong app** mô tả ý đồ ban đầu; code đổi sau, văn bản không đổi theo.
Giải thích: **P1-2** (Location/SSID), **P2-3** (lệnh hiển thị ≠ lệnh chạy), **P2-6**
(`defaultLaunchBehavior`), **P3-8** ("power reads zero"), và các mâu thuẫn nội bộ trong README (§6).
Đây là dạng lỗi nguy hiểm nhất với một app mà toàn bộ giá trị nằm ở chữ "trung thực".

### Gốc C — Nhánh thất bại của các hành động một lần chưa từng được chạy

`Sources/MyMac` có **0 test**. Mọi lỗi trong nhóm này đều nằm ở đường thất bại của một hành động
người dùng bấm một lần: **P2-1** (thông báo lỗi login item bị xoá), **P2-2** (timeout không bao giờ nổ),
**P3-11** (`terminate()` bỏ qua giá trị trả về), **P2-5** (chỉ quét một brew prefix).

---

## 3. Danh sách phát hiện

Ký hiệu xác thực: **✅** = tôi tự mở lại code/chạy lại kiểm chứng · **○** = suy luận từ đọc code, chưa chạy thực nghiệm độc lập.
Phân loại: **(A)** code sai chuẩn · **(B)** tài liệu sai so với code · **(C)** chưa có quy tắc, cần bạn quyết.

### P1 — Cần sửa trước khi công khai repo

---

#### P1-1 · Giám sát mạng chết vĩnh viễn sau một chu kỳ dừng/chạy · (A) ✅

**Code:** `Sources/MyMac/App/MetricsStore.swift:91-111` · `Sources/MyMacCore/Services/NetworkCollector.swift:68-97`
**Chuẩn bị vi phạm:** `README.md` §Sampling — "Sampling is demand-driven and stops entirely when nothing is displaying metrics" hàm ý *chạy lại được*.

`stop()` gọi `monitor.stop()` → `NWPathMonitor.cancel()`. Lần `start()` sau đó gọi `monitor.start(queue:)`
trên chính đối tượng đã bị huỷ.

**Kiểm chứng thực nghiệm** (chạy trên máy này, không phải suy đoán):

```
phase 1 update: satisfied
--- cancel ---
--- restart same monitor ---
RESULT: updates before cancel = 1, updates after restart = 0
```

**Đường đi của người dùng thật:** Settings → Menu Bar → tắt cả *Show CPU* và *Show memory*
(đây là hành vi **được README quảng cáo**: "with both off … sampling stops entirely") → đóng cửa sổ →
mở lại Dashboard.

**Hậu quả** *(đã sửa lại sau khi viết test — mô tả đầu tiên của tôi sai, xem ghi chú bên dưới)*:
collector giữ nguyên giá trị path cuối cùng nó nghe được và **không bao giờ nhận cập nhật nữa**. App
ngừng nhận biết mọi thay đổi đường mạng: chuyển Wi-Fi sang Ethernet, rút cáp, bật/tắt VPN, chuyển sang
mạng metered. Interface, `interfaceKind`, `isConnected`, cờ VPN/Metered/Low-Data và mọi số liệu suy ra
từ interface primary (`linkSpeed`, `mtu`, `errorsIn/Out`, `drops`, "Since boot") đều đóng băng ở giá
trị cũ — trông vẫn hợp lý, nên không ai nhận ra. Chỉ hết khi khởi động lại app.

> **Đính chính:** bản đầu tiên của mục này viết rằng card Network sẽ hiển thị "Offline" và MTU `0`.
> Sai. Khi viết test hồi quy tôi phát hiện `primaryInterface`/`isConnected` là biến instance
> **không bị xoá khi `stop()`**, nên sau chu kỳ dừng/chạy chúng giữ giá trị cũ chứ không về `nil`.
> Triệu chứng thật là **đóng băng im lặng**, không phải mất dữ liệu — khó phát hiện hơn, nhưng mức
> nghiêm trọng không đổi. Chính đặc điểm này là lý do một test hộp đen không bắt được lỗi, nên test
> đầu tiên phải kiểm tra thẳng vào `isMonitoring`.

**Thêm một race:** `stop()` đặt `loop = nil` ngay, nhưng `await monitor.stop()` chạy bất đồng bộ *sau đó*.
Nếu `start()` xảy ra trước khi task cũ kịp chạy xong, monitor mới bị task cũ huỷ ngay sau khi vừa start.

**Hướng sửa:** `NetworkCollector.start()` tạo `NWPathMonitor` mới thay vì tái dùng; hoặc bỏ hẳn
`stop()` cho path monitor (nó gần như miễn phí giữa các sự kiện — chính README đã ghi vậy).

---

#### P1-2 · App xin quyền Location nhưng không trả lại gì · (A) ✅

**Code:** `Sources/MyMacCore/Services/NetworkCollector.swift:268` (đọc `interface.ssid()`) ·
`Sources/MyMacCore/Models/Metrics.swift:293` (`networkName`) ·
`Sources/MyMacCore/Core/Permissions/Permissions.swift:46-53` · `Resources/Info.plist` (`NSLocationWhenInUseUsageDescription`) ·
`Sources/MyMac/Features/Permissions/PermissionsView.swift:38-41`
**Chuẩn bị vi phạm:** `README.md` §"What each page shows" — "The network name is deliberately absent … asking for a location permission to show one label is not a trade this app makes."

Kiểm chứng bằng grep toàn repo: `networkName` được **ghi vào đúng một lần** và **không đọc ra ở bất kỳ đâu** —
không trong `Sources/MyMac`, không trong test.

Trong khi đó app vẫn:
1. gọi `interface.ssid()` mỗi lần đọc radio (macOS ghi log truy cập vị trí cho lời gọi này);
2. khai báo `NSLocationWhenInUseUsageDescription` trong Info.plist;
3. liệt kê Location trong Settings → Permissions kèm mô tả *"Showing the name of the Wi-Fi network you are joined to"*;
4. có nút **"Allow…"** dựng prompt hệ thống thật qua `requestWhenInUseAuthorization()`.

**Hậu quả:** người dùng cấp quyền vị trí → **không có gì thay đổi trên màn hình**. Tệ hơn, ngay bên
dưới, card Wi-Fi vẫn in dòng *"The network name needs Location access, which this app does not ask for."*
(`DetailViews.swift:365`) — app tự mâu thuẫn với chính nó trong cùng một cửa sổ. Với một app mà toàn bộ
luận điểm bán hàng là sự trung thực về quyền riêng tư, đây là lỗi đắt nhất trong danh sách.

**Cần bạn quyết (C):** hoặc **(a)** hiển thị SSID khi đã được cấp quyền — biến nó thành tính năng thật;
hoặc **(b)** gỡ sạch: bỏ `networkName`, bỏ `interface.ssid()`, bỏ mục Location khỏi `Permission.all`,
bỏ `NSLocationWhenInUseUsageDescription`, chuyển Location xuống `neverRequested`. Tôi nghiêng về **(b)** —
nó khớp với README và làm luận điểm mạnh hơn.

---

#### P1-3 · Repo chưa sẵn sàng để người khác clone · (A, so với mục tiêu phát hành bạn đã nêu) ✅

| Thiếu | Bằng chứng | Hậu quả |
|---|---|---|
| Git repository | `git status` → `fatal: not a git repository` | Không thể publish. Không có lịch sử để audit lần sau đối chiếu. |
| `LICENSE` | không tồn tại | Không có license = **mặc định là all-rights-reserved**. Người clone không có quyền hợp pháp để dùng hay fork. |
| App icon | `Resources/` chỉ có `Info.plist`; không có key `CFBundleIconFile`/`CFBundleIconName` | Dock, Finder, ⌘Tab, System Settings → Login Items đều hiện icon trắng mặc định. Với mục tiêu "UI/UX chuyên nghiệp" thì đây là thứ đầu tiên người dùng nhìn thấy. |
| CI | không có `.github/` | 109 test hiện chỉ chạy khi bạn nhớ chạy. |
| Universal binary | `Scripts/build-app.sh:16` build đúng kiến trúc máy host | Xem P2-4. |

---

### P2 — Sửa sớm

---

#### P2-1 · Thông báo lỗi "Open at login" bị chính nó xoá mất · (A) ○

**Code:** `Sources/MyMac/Features/Settings/SettingsView.swift:158-159` và `189-202`
**Chuẩn bị vi phạm:** `README.md` §Known limitations — "With the ad-hoc signature from the build script, `SMAppService` will refuse and **the toggle reports why**."

```swift
Toggle("Open at login", isOn: $launchAtLogin)
    .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled: enabled) }
...
} catch {
    launchAtLogin = SMAppService.mainApp.status == .enabled   // ← ghi lại state
    loginItemError = "macOS refused this change: ..."
}
```

Gán lại `launchAtLogin` trong khối `catch` **kích hoạt lại chính `onChange` đó**. Vòng hai gọi
`unregister()`, thường thành công, và chạy vào nhánh `loginItemError = nil` — **xoá đúng thông báo mà
người dùng cần đọc**.

**Trigger:** đây là đường đi *mặc định* cho mọi người clone repo, vì `Scripts/build-app.sh` ký ad-hoc
và `SMAppService` từ chối bundle chưa ký Developer ID. Nghĩa là tính năng duy nhất chắc chắn thất bại
với người dùng mới cũng là tính năng thất bại **trong im lặng**.

**Hướng sửa:** tách hành động khỏi state — dùng `Toggle(isOn: Binding(get:set:))` gọi thẳng
`updateLoginItem`, không dùng `onChange`.

---

#### P2-2 · Timeout của CommandRunner không bao giờ có thể nổ · (A) ✅

**Code:** `Sources/MyMacCore/Uninstaller/CommandRunner.swift:75-86`

```swift
let data = try await Task.detached { try handle.readToEnd() ?? Data() }.value   // ← chặn tới EOF
let deadline = Task { try await Task.sleep(for: timeout); if process.isRunning { process.terminate() } }
process.waitUntilExit()
```

`readToEnd()` chặn cho đến khi tiến trình con đóng stdout — tức là **cho đến khi nó thoát**. Task
`deadline` chỉ được tạo *sau* đó. Với một tiến trình treo (`brew` chờ khoá, `pip` chờ nhập liệu,
`npm` chờ mạng), `readToEnd()` không bao giờ trả về và timeout 180 s **không tồn tại**.

**Hậu quả:** actor `UninstallService` bị chặn vô hạn (`waitUntilExit()` cũng chặn executor của actor).
Nút "Uninstall" quay mãi; không có cách huỷ; đóng cửa sổ không cứu được. Chỉ Force Quit app.

**Hướng sửa:** tạo `deadline` **trước** khi đọc pipe; đọc pipe bằng `readabilityHandler` bất đồng bộ;
thay `waitUntilExit()` bằng `terminationHandler` + continuation để không chặn actor.

---

#### P2-3 · Sheet xác nhận hiển thị một lệnh không phải lệnh sẽ chạy · (A) ✅

**Code:** `Sources/MyMac/Features/Uninstaller/UninstallerView.swift:230-231`
**Chuẩn bị vi phạm:** `README.md` §The uninstaller — "**the exact command is shown in the confirmation sheet before it runs**"

```swift
Text(([ecosystem.rawValue] + ecosystem.uninstallArguments(for: item.name)).joined(separator: " "))
```

`ecosystem.rawValue` là tên case trong enum, **không phải tên chương trình**. Lệnh thật đến từ
`PackageEcosystem.executables(home:)` (`InstalledItem.swift:139-156`).

| Người dùng thấy | Thực tế chạy |
|---|---|
| `homebrew uninstall --formula wget` | `/opt/homebrew/bin/brew uninstall --formula wget` |
| `homebrewCask uninstall --cask docker` | `/opt/homebrew/bin/brew uninstall --cask docker` |
| `python uninstall --yes requests` | `/opt/homebrew/bin/pip3 uninstall --yes requests` |

**Hậu quả:** README hứa minh bạch tuyệt đối ở đúng chỗ nguy hiểm nhất (nơi duy nhất app chạy chương
trình ngoài). Chuỗi hiển thị không copy-paste được, không kiểm chứng được, và với `python` thì
**sai tên chương trình hoàn toàn**. Nên in đường dẫn tuyệt đối của executable đã phân giải.

---

#### P2-4 · Build script chỉ build kiến trúc của máy host · (A) ✅

**Code:** `Scripts/build-app.sh:16-33`

Người có máy Intel clone repo về sẽ nhận app x86_64 (chạy được, do build tại chỗ). Nhưng nếu bạn phát
hành sẵn `.app` build từ máy Apple Silicon, nó **không chạy trên Intel**.

**Tin tốt — tôi đã build thử:** universal chỉ cần thêm cờ, không cần đổi một dòng Swift nào.

```
$ swift build -c release --product MyMac --arch arm64 --arch x86_64
Build complete!
$ lipo -info .../MyMac
Architectures in the fat file: ... are: x86_64 arm64
```

Đồng thời `swift build --arch x86_64` biên dịch sạch, **0 warning**. Xem §4 để trả lời câu hỏi Intel của bạn.

**Ghi chú phụ:** script dùng `codesign --deep`, đã bị Apple deprecate và không đảm bảo ký đúng thứ tự
bundle lồng nhau.

---

#### P2-5 · Chỉ quét prefix package manager đầu tiên tìm thấy · (A) ✅

**Code:** `Sources/MyMacCore/Uninstaller/PackageCatalog.swift:16` — `roots(home:).first(where: directoryExists)`

`PackageEcosystem.roots(home:)` (`InstalledItem.swift:114-136`) trả về `["/opt/homebrew", "/usr/local"]`
cho Homebrew, và tương tự cho npm/python. Chỉ **root đầu tiên** được đọc.

**Trigger:** rất phổ biến trên Apple Silicon — nhiều developer chạy song song `brew` arm64 ở
`/opt/homebrew` **và** `brew` x86_64 qua Rosetta ở `/usr/local`. App im lặng chỉ liệt kê một nửa.

**Hậu quả:** danh sách Uninstaller không đầy đủ, không có bất kỳ dấu hiệu nào báo là chưa đầy đủ.
Người dùng kết luận package đã bị gỡ trong khi nó vẫn còn.

**Hệ quả kèm theo (P3):** `executables(home:)` luôn ưu tiên `/opt/homebrew/bin` bất kể package thuộc
prefix nào — nếu sửa việc quét mà không sửa việc chọn executable, app sẽ chạy `brew` arm64 để gỡ
formula x86_64 và thất bại khó hiểu.

---

#### P2-6 · `defaultLaunchBehavior` chỉ tồn tại trong comment · (A/B) ✅

**Code:** `Sources/MyMac/App/MyMacApp.swift:159-170` (khai báo `Window`, **không** có modifier) ·
`MyMacApp.swift:257-267`:

```swift
guard #unavailable(macOS 15.0) else { return }
// Fallback for macOS 14, which has no `defaultLaunchBehavior`.
```

Grep toàn repo: `defaultLaunchBehavior` xuất hiện **duy nhất trong dòng comment đó**. Vậy trên
macOS 15+ (máy này chạy **macOS 26.6.1**), fallback bị bỏ qua và cũng không có modifier thay thế.

**Chuẩn bị vi phạm:** `MyMacApp.swift:145-146` — "this is a menu bar utility, and launching it must not
put a window on screen."

Hiện tại việc khai báo `MenuBarExtra` trước `Window` có vẻ đủ để che vấn đề trên máy này, nhưng đó là
hành vi ngầm định của SwiftUI, không phải hợp đồng. Cửa sổ cũng không có `.restorationBehavior(.disabled)`,
nên window restoration của macOS vẫn có thể mở lại nó lúc đăng nhập.

**Hướng sửa:** thêm `.defaultLaunchBehavior(.suppressed)` + `.restorationBehavior(.disabled)` với
`if #available(macOS 15, *)`, giữ nguyên fallback cho macOS 14.

---

#### P2-7 · Throughput mạng bị đếm hai lần khi có VPN · (A) ✅

**Code:** `Sources/MyMacCore/Services/NetworkCollector.swift:129-155` và `192-194`

`isMeasurable` chỉ loại `lo*`, `awdl*`, `llw*`. Mọi interface còn lại đều được **cộng dồn** vào
`deltaReceived`/`deltaSent`.

Một gói đi qua VPN được hệ điều hành đếm **hai lần**: một lần trên `utunN`, một lần trên `en0`.
Bridge (`bridge0`) và Internet Sharing (`ap1`) cũng vậy.

**Kiểm chứng trên máy này** — `netstat -ib` cho thấy `utun5` có lưu lượng thật (5 656 B in / 175 532 B out)
song song với `en0`, và log test in `vpn=true`. Cơ chế nhân đôi là có thật; độ lớn phụ thuộc tỷ lệ
lưu lượng đi qua tunnel.

**Hậu quả:** khi bật VPN toàn phần, số Download/Upload trên Dashboard và Network **gần gấp đôi thực tế**,
đồng thời sparkline và "Peak ↓/↑" cũng sai theo. Không có ghi chú nào cảnh báo.

**Hướng sửa:** loại `utun*`, `ipsec*`, `ppp*`, `bridge*`, `gif*`, `stf*` khỏi tổng — hoặc chỉ tính
interface primary cho con số headline, giữ phần còn lại trong bảng per-interface (bảng đó đã có sẵn).

---

#### P2-8 · `~/.m2/repository` bị xếp "safe" và xoá vĩnh viễn · (C → A) ✅

**Code:** `Sources/MyMacCore/Cleaner/CleanupCatalog.swift:124-126`, qua helper `developerCache`
(`:25-36`) — helper này **hard-code** `tier: .safe, removal: .delete`.

`.delete` nghĩa là `FileManager.removeItem` — **không vào Thùng rác**, không phục hồi được
(`CleanupEngine.swift:99`).

Vấn đề: `~/.m2/repository` không thuần là cache tải về. `mvn install` đặt **artifact do chính người
dùng build** vào đó — SNAPSHOT nội bộ, thư viện private không có trên Maven Central. Những file này
**không tải lại được**. `~/.cache` (rule `cache.dir`) có rủi ro tương tự nhưng thấp hơn.

Kết hợp với nút **"Select All Safe"** (`CleanerView.swift:99`): hai cú click + một xác nhận là mất sạch.

**Cần bạn quyết (C):** đổi Maven (và cân nhắc `~/.cache`) sang `tier: .review, removal: .trash`? Điều đó
đòi tách `developerCache` thành hai biến thể. README §The cleaner hiện liệt kê Maven như cache thuần —
nếu bạn cho là đúng, thì mục cần sửa là README chứ không phải code; nhưng tôi khuyến nghị đổi code.

---

#### P2-9 · Tầng app không có test nào · (A, so với "tiêu chuẩn ngành") ✅

109 test đều nằm trong `Tests/MyMacCoreTests`. `Sources/MyMac` (~2 900 dòng) có **0 test**:
`MetricsStore`, `AppState`, `DockPolicy`, `CleanerModel`, `UninstallerModel`, `ProcessActionModel`,
`MenuBarIcon`, `SettingsView`.

Đây chính là **Gốc C**: P1-1, P2-1, P2-3 đều nằm trong vùng không được kiểm thử.

**Trở ngại kỹ thuật:** SwiftPM không cho test trực tiếp một `executableTarget`. **Hướng sửa chuẩn:**
tách logic app thành target thư viện `MyMacApp` (mọi thứ trừ `@main`), để `executableTarget` chỉ còn
vài dòng, rồi thêm `MyMacAppTests`.

---

### P3 — Đáng sửa, không gấp

| # | Phát hiện | Vị trí | Hậu quả | Xác thực |
|---|---|---|---|---|
| P3-1 | Popover menu bar giữ scope `.detail` → mỗi lần mở popover là một lần đọc CoreWLAN, dù popover **không hiển thị dữ liệu radio nào**. README ghi CoreWLAN là thứ đắt nhất trong một sample (1.1 ms → 4.8 ms, idle CPU 0.3 % → 3–6 %). | `MenuBarView.swift:29-30` · `MetricsStore.swift:116` | Lãng phí đúng chi phí mà README dành cả một đoạn để tránh. Nên dùng scope riêng, hoặc chỉ bật `includeRadio` khi trang Network mở. | ✅ |
| P3-2 | `ProcessInfo.processInfo.activeProcessorCount` gọi **bên trong vòng lặp per-process** | `ProcessCollector.swift:92` | ~680 lời gọi (mỗi lời gọi là một `sysctl`) mỗi 2 giây. Hoist ra ngoài vòng lặp là sửa xong. | ✅ |
| P3-3 | `.task { model.load() }` chạy lại mỗi lần vào tab Uninstaller; không cache | `UninstallerView.swift:90` · `UninstallerModel.swift:117-132` | Quét lại `/Applications` + đo lại kích thước **mọi** bundle mỗi lần chuyển tab. Vài giây I/O mỗi lần. | ✅ |
| P3-4 | Duplicate scanner gom nhóm theo `totalFileAllocatedSize` (kích thước cấp phát) thay vì kích thước logic | `DuplicateScanner.swift:73-75` | Hai file **nội dung y hệt** nhưng khác cách cấp phát (APFS compression, clone, resource fork) rơi vào hai nhóm size khác nhau → **không bao giờ được so sánh**. Nên gom theo `.fileSizeKey`. | ✅ |
| P3-5 | Font scale cố định `Font.system(size: 11)` … `size: 15` | `Components.swift:11-22` | Bỏ qua hoàn toàn cài đặt Accessibility → Display → Text Size của macOS. Dùng `.system(size:relativeTo:)` giữ nguyên sàn 11 pt mà vẫn scale. | ✅ |
| P3-6 | `Sparkline` và `CoreBars` đặt `.accessibilityHidden(true)` mà không có phương án thay thế | `Components.swift:150, 411` | Với VoiceOver, dữ liệu per-core biến mất hoàn toàn (không chỉ hình vẽ). Thêm `.accessibilityElement` + `accessibilityValue` tóm tắt. | ✅ |
| P3-7 | `MenuActionRow` hard-code chữ `.white` trên nền `Color.accentColor` | `Components.swift:228-232` | Với accent color sáng (vàng/xanh lá — người dùng chọn được trong System Settings), chữ trắng gần như không đọc được. Dùng `.selectedMenuItemTextColor`. | ✅ |
| P3-8 | "Power … reads zero on mains power" — thực tế hiển thị `—` | `BatteryCollector.swift:81-85` (trả `nil` khi ≤ 0.01 W) · `DetailViews.swift:502-507` · `DetailViews.swift:529` | Chữ ngay trong app mô tả sai hành vi của chính app. Hoặc trả `0` thay vì `nil`, hoặc sửa câu chữ. | ✅ |
| P3-9 | Rule bị từ chối quyền mà **không** có `needsFullDiskAccess` thì `CleanupIssue` không được hiển thị ở đâu | `CleanupScanner.swift:81-95` · `CleanerView.swift:167-171` | Nhóm hiện ra rỗng, người dùng hiểu là "không có gì" thay vì "không đọc được". `CleanupGroup.issues` gần như là dead field. | ✅ |
| P3-10 | `reclaimedBytes` cộng `item.size` từ kết quả scan (có thể đã cũ vài phút) chứ không đo lại | `CleanupEngine.swift:105` | Con số "Reclaimed X" trong SummaryView là ước lượng, được trình bày như sự thật. | ✅ |
| P3-11 | `NSRunningApplication.terminate()` trả `Bool`, bị bỏ qua | `ProcessAttention.swift:40` | Thất bại im lặng; may là vòng kiểm tra 3 giây bắt được. Vẫn nên log. | ✅ |
| P3-12 | `if Task.isCancelled { break }` chỉ thoát vòng lặp trong | `CleanupEngine.swift:61` | Vòng ngoài vẫn duyệt hết các request còn lại (mỗi cái break ngay). Hoạt động đúng nhưng dễ hiểu nhầm. | ✅ |
| P3-13 | Deep scan "Large Files" (root = home) chồng lấn `~/.m2`, `~/.npm` | `CleanupCatalog.swift:235-242` · `LargeFileScanner.swift:16-19` (skip `.gradle`, `.cargo` nhưng không skip `.m2`, `.npm`) | Cùng một gigabyte được báo hai lần ở hai nhóm. Test `noDeletionRuleOverlapsAnother` cố ý loại deep scan nên không bắt được. | ✅ |
| P3-14 | Mỗi callback progress sinh một `Task { @MainActor }` | `CleanerModel.swift:93-99, 167-171` | Vài chục–vài trăm Task/giây khi deep scan hoặc xoá hàng nghìn item. Nên throttle hoặc dùng `AsyncStream` lấy giá trị mới nhất. | ✅ |
| P3-15 | Sidebar là 10 mục phẳng, trộn giám sát (Dashboard…Processes) với công cụ (Cleaner, Uninstaller) và Settings | `MyMacApp.swift:282-286` | Quy ước macOS là dùng `Section` có tiêu đề. 10 mục phẳng đọc như một danh sách chứ không phải một cấu trúc. | ✅ |
| P3-16 | `Table` trong Processes không có `sortOrder` binding — không click được vào header cột để sắp xếp | `ProcessListView.swift:36-97` | Người dùng macOS sẽ click header trước tiên và không có gì xảy ra; phải tìm segmented picker trên toolbar. | ✅ |
| P3-17 | Checkbox nhóm trong Cleaner không có trạng thái mixed | `CleanerModel.swift:127-132` (trả `nil`) · `CleanerView.swift:126-129` (`?? false`) | Nhóm chọn một phần trông y hệt nhóm không chọn gì. | ✅ |
| P3-18 | Toàn bộ chuỗi hard-code tiếng Anh, không có String Catalog | toàn bộ `Sources/MyMac` | Không dịch được. Xem (C-5). | ✅ |

---

## 4. Trả lời trực tiếp câu hỏi Intel của bạn

Bạn nói: *"Nếu hỗ trợ chip Intel thì càng tốt. Còn nếu chi phí, hiệu năng, rủi ro thì chỉ cần cho chip Apple."*

**Khuyến nghị: hỗ trợ Intel. Chi phí gần bằng không, và tôi đã kiểm chứng bằng cách build thật.**

| Hạng mục | Kết quả kiểm chứng |
|---|---|
| Biên dịch x86_64 | `swift build -c release --arch x86_64` → **thành công, 0 warning** |
| Universal binary | `--arch arm64 --arch x86_64` → **thành công**, `lipo -info` xác nhận `x86_64 arm64` |
| Sửa build script | Thêm hai cờ vào `swift build`; `--show-bin-path` trả về `.build/apple/Products/Release` — vẫn hoạt động |
| Code đã tính đến Intel chưa | **Có, và tính rất tốt.** `MachHost.machTicksToNanoseconds` (Intel = 1.0, AS = 41.67) — đây chính là bug 24× mà README kể; `SystemInfo.performanceCores/efficiencyCores` = 0 trên Intel và `coreSummary` xử lý đúng; `BatteryCollector` dùng `NominalChargeCapacity` (AS) fallback `AppleRawMaxCapacity` (Intel); nhiệt độ pin bị bỏ đi **vì** đơn vị SMC khác nhau giữa hai nền tảng |
| Rủi ro còn lại | Chỉ có P2-5: dual brew prefix. Đây vốn là bug trên **cả hai** kiến trúc, không riêng Intel |

**Không có** khối code nào riêng cho Apple Silicon cần gỡ. Chi phí thực tế của việc hỗ trợ Intel là
**một dòng trong `Scripts/build-app.sh`** cộng với việc bạn không thể chạy thử. Nếu sau này thấy phiền,
gỡ ra cũng chỉ là xoá lại hai cờ đó.

---

## 5. Đã kiểm tra và **kết luận là đúng**

Phần này quan trọng ngang phần phát hiện: nó cho biết đâu là vùng đã được soi, để lần audit sau không làm lại.

**`PathSafety` — mô hình an toàn xoá file.** Đọc từng dòng `PathSafety.swift:109-165`, đối chiếu với
12 test đang pass. Chuỗi kiểm tra đúng và đúng **thứ tự**:
- `lstat` (không phải `stat`) để bắt symlink mà không đi theo nó — `:129-131`
- `realpath` trên **thư mục cha**, không phải trên chính item — `:135-138`. Đây là chi tiết mà đa số
  implementation làm sai: resolve chính item sẽ che mất một thành phần đường dẫn bị symlink.
- Containment nghiêm ngặt theo **thành phần đường dẫn** — `isDescendant` từ chối `/a/bc` nằm trong `/a/b`, và
  một path không bao giờ là con của chính nó (nên "dọn `~/Library/Caches`" không thể xoá được `~/Library/Caches`)
- Tập protected **tự sinh từ catalog** (`:83-85`) — thêm rule mới tự động mở rộng bảo vệ
- Engine **validate lại ngay trước khi xoá**, dùng root của rule làm allowlist chứ không dùng kết quả scan (`CleanupEngine.swift:65-93`)
- `requiredSuffix` thu hẹp `~/Library/Containers` về đúng `Data/Library/Caches`

**Dò Full Disk Access — đúng, và tôi đã kiểm chứng thực nghiệm.** Nghi ngờ ban đầu của tôi là
`fileExists` sẽ trả `false` cho path bị TCC chặn, khiến nhánh "assume the best" báo nhầm là `.granted`.
Chạy thử trên máy này:

```
$ test -e ~/Library/Application\ Support/com.apple.TCC/TCC.db  → EXISTS
$ head -c 1 ~/Library/Application\ Support/com.apple.TCC/TCC.db → DENIED
```

`stat` **được phép**, `open` **bị chặn**. Vậy `FullDiskAccess.status()` (`Permissions.swift:69-78`)
đi đúng nhánh `.denied`, và nhánh "assume granted" chỉ chạy khi DB thật sự không tồn tại.
Logic phát hiện từ chối quyền của scanner (`CleanupScanner.swift:126`) đúng vì cùng lý do.

**Độ chính xác của số liệu.**
- Xử lý wraparound bộ đếm tick 32-bit bằng `&-` — đúng, có test riêng (`survivesCounterWraparound`).
- Chuyển đổi mach timebase cho `proc_pid_rusage` — đúng, và test `measuresAFullyBusyThreadAsAboutOneCore`
  in ra `SELF cpu=148%` khi chạy, xác nhận không còn sai số 24×.
- Ngữ nghĩa bộ nhớ: `app = internal_page_count − purgeable`, `used = app + wired + compressed` —
  khớp Activity Monitor. `cached` tách riêng, không tính vào `used`.
- Áp suất bộ nhớ đọc từ `kern.memorystatus_vm_pressure_level` của kernel chứ không tự bịa tỷ lệ.
- `host_processor_info` được `vm_deallocate` đúng (`CPUCollector.swift:114-118`); `mach_host_self()`
  cache một lần nên không rò rỉ port reference.

**An toàn khi chạy chương trình ngoài.** Đúng **một** `Process()` trong toàn repo (kiểm chứng bằng grep).
Argument vector, không shell. `PATH` tối thiểu và cố định. Tên package bị validate; ký tự đầu `-` bị từ chối
nên tên không thể bị hiểu thành flag. Không `sudo`, không privileged helper, không `osascript`.

**Uninstaller.** App của Apple (`com.apple.*`) bị loại hoàn toàn. App bundle và leftover đi vào **Thùng rác**,
không xoá thẳng. Leftover khớp theo bundle identifier ở 12 vị trí chính xác + Group Containers.
Xử lý Yarn v1 (đọc manifest thay vì `node_modules` đã hoisted) là đúng và có test.

**Kỷ luật lấy mẫu.** Demand-driven qua scope counting là kiến trúc đúng. `SamplingCostTests` in ra
chi phí thật: `processes 1.576 ms/call` cho 679 tiến trình. Chú thích `@MetricsActor` được áp dụng
nhất quán; UI không hề gọi Mach API nào.

**Chất lượng build.** 0 warning ở cả debug lẫn release dưới Swift 6 strict concurrency. 109/109 test pass
trong 14 giây. 0 TODO/FIXME/HACK.

---

## 6. Mâu thuẫn nội bộ trong README — nhóm (B)

Không phải bug code, nhưng là chuẩn đối chiếu tự mâu thuẫn, nên phải sửa trước khi audit lần sau dùng lại nó.

1. **SSID.** §"What each page shows": *"The network name is deliberately absent … not a trade this app makes."*
   ↔ §"Settings and permissions" bảng quyền: Location *"Unlocks: The name of the joined Wi-Fi network."*
   Hai đoạn nói ngược nhau. Xem P1-2.
2. **Tổng lưu lượng mạng.** §"What each page shows": *"totals since boot **and** this session"* (đúng — UI hiển thị cả hai,
   `DetailViews.swift:390-393`) ↔ §Known limitations: *"Network totals are per session"*. Mục limitation đã lỗi thời.
3. **"fourteen places"** (§The uninstaller) — `LeftoverScanner` thực tế có 12 đường dẫn theo bundle ID
   + Group Containers + 2 đường dẫn theo tên hiển thị. README cũng nói leftover *"found by bundle identifier"*,
   bỏ qua hai vị trí khớp theo **tên** (`LeftoverScanner.swift:47-50`) — đúng là sự khác biệt mà chính README
   nhấn mạnh ("matching on a vendor name is a guess").
4. **"Power reads zero on mains power"** — xem P3-8.
5. **`defaultLaunchBehavior`** — comment trong `MyMacApp.swift:260` mô tả một cơ chế không tồn tại. Xem P2-6.

---

## 7. Nhóm (C) — cần **bạn** quyết, không phải task

Đây là câu hỏi, không phải việc. Nếu tôi tự quyết thì tôi đang đoán thay bạn.

| # | Câu hỏi | Vì sao quan trọng |
|---|---|---|
| C-1 | **Location/SSID: làm cho ra hồn, hay gỡ sạch?** | Đây là quyết định về định vị sản phẩm, không phải kỹ thuật. Tôi nghiêng về gỡ — nó làm luận điểm "app này không xin gì cả" mạnh hơn. Xem P1-2. |
| C-2 | **`~/.m2/repository` và `~/.cache` nên là `safe/delete` hay `review/trash`?** | `.delete` là vĩnh viễn. Maven chứa artifact tự build không tải lại được. Xem P2-8. |
| C-3 | **"Select All Safe" + xoá vĩnh viễn có phải mức rủi ro bạn muốn?** | Hai click là mất sạch mọi thứ trong tier safe. Cân nhắc: mọi thứ vào Trash trừ những rule mà chính điểm của nó là giải phóng dung lượng ngay (Trash, DerivedData). |
| C-4 | **License nào?** | Không có license = không ai được phép dùng repo của bạn một cách hợp pháp. MIT/Apache-2.0 là mặc định hợp lý cho một utility. |
| C-5 | **Có cần đa ngôn ngữ (tiếng Việt) không?** | Ảnh hưởng lớn tới khối lượng: ~250 chuỗi cần chuyển sang String Catalog. Nếu chỉ nhắm developer quốc tế thì tiếng Anh là đủ. |
| C-6 | **Icon: tự vẽ, hay dùng SF Symbol render thành `.icns`?** | Cần trước khi công khai (P1-3), nhưng hình thức là lựa chọn của bạn. |

---

## 8. Thứ tự đề xuất

Xếp theo **chi phí và độ ràng buộc**, không chỉ theo mức nghiêm trọng.

**Vòng 1 — sửa nhanh, ảnh hưởng lớn (ước tính nửa ngày)**
1. `git init` + `.gitignore` (đã có) + `LICENSE` — mở khoá mọi thứ còn lại, và cho lần audit sau một baseline. *(P1-3)*
2. `NetworkCollector.start()` tạo `NWPathMonitor` mới — **một dòng**, sửa bug nghiêm trọng nhất. *(P1-1)*
3. Build script: thêm `--arch arm64 --arch x86_64` — **một dòng**, xong chuyện Intel. *(P2-4, §4)*
4. Sheet uninstaller in đường dẫn executable đã phân giải thay vì `ecosystem.rawValue`. *(P2-3)*
5. Hoist `activeProcessorCount` ra khỏi vòng lặp. *(P3-2)*
6. Loại tunnel/bridge khỏi tổng throughput. *(P2-7)*

**Vòng 2 — nhánh lỗi (ước tính một ngày)**
7. Bỏ `onChange` cho login item; đưa hành động vào binding. *(P2-1)*
8. Viết lại `CommandRunner.run`: deadline trước, đọc pipe bất đồng bộ, `terminationHandler` thay `waitUntilExit`. *(P2-2)*
9. Quét **mọi** prefix package manager, và chọn executable theo prefix của package. *(P2-5)*
10. `.defaultLaunchBehavior(.suppressed)` + `.restorationBehavior(.disabled)`. *(P2-6)*

**Vòng 3 — kết cấu (một tới hai ngày)**
11. Tách `Sources/MyMac` thành library target + `@main` mỏng; thêm `MyMacAppTests` phủ đúng các bug ở vòng 1–2. *(P2-9)*
12. Đồng bộ README với code — 5 mâu thuẫn ở §6. Làm **sau** vòng 1–2 để chỉ phải viết lại một lần.
13. Thêm GitHub Actions chạy `swift build` + `swift test` cho cả hai kiến trúc. *(P1-3)*

**Vòng 4 — chất lượng hoàn thiện**
14. Accessibility: font scale động, tóm tắt VoiceOver cho chart/core bars, bỏ chữ trắng hard-code. *(P3-5, P3-6, P3-7)*
15. Sidebar có Section; Table sắp xếp bằng header cột; checkbox mixed-state. *(P3-15, P3-16, P3-17)*
16. Cache danh sách Uninstaller; throttle progress callback; scope riêng cho radio. *(P3-1, P3-3, P3-14)*
17. Duplicate scanner gom theo kích thước logic. *(P3-4)*

**Bị chặn bởi quyết định của bạn — làm cuối**
18. C-1 (Location/SSID) chặn P1-2 và mâu thuẫn README #1.
19. C-2/C-3 (phân loại rủi ro cleaner) chặn P2-8.
20. C-5 (đa ngôn ngữ) chặn P3-18 — và nếu chọn có, nên làm **trước** vòng 4 để không phải sửa chuỗi hai lần.

**Icon (C-6)** có thể làm song song bất cứ lúc nào; nó không chặn gì cả.
