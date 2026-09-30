# MyMac — Rà soát luồng Uninstaller

**Ngày:** 2026-09-21 · **Phạm vi:** `Sources/MyMacCore/Uninstaller/`, `Sources/MyMacUI/Features/Uninstaller/`,
và `Sources/MyMacCore/Cleaner/PathSafety.swift` ở phần uninstaller gọi tới.
**Máy kiểm chứng:** macOS 26.x (Darwin 25.6.0), Apple Silicon · Xcode 27.0 · Swift 6
**Ngôn ngữ báo cáo:** tiếng Việt, giữ nguyên tên định danh / đường dẫn / chuỗi giao diện bằng tiếng Anh.

> Báo cáo này **không sửa code**. Ngoại lệ: các mục đánh dấu **đã sửa** dưới đây đã được
> thực hiện theo yêu cầu, mỗi mục có test đỏ trước khi sửa. Bốn mục còn lại cần bạn quyết
> định trước, nên vẫn nguyên.

## Trạng thái thực hiện

| Ngày | Nội dung | Kết quả |
|---|---|---|
| 2026-09-21 | U-1 | 191 test |
| 2026-09-24 | O-3 · O-4 · U-2 · U-3 · U-4 · U-5 · U-8 · U-9 | 200 test, build xanh |
| 2026-09-24 | U-6 · U-7 · O-1 · O-2 theo quyết định của bạn · U-10 phát hiện khi sửa U-6 | 215 test, build xanh |
| 2026-09-25 | Vòng review: 9/10 finding được xác nhận và sửa, 1 là đánh đổi đã chọn | **219 test**, build sạch xanh |

### Vòng review 2026-09-25

Code review (`/code-review high`) trả về 10 finding chưa xác minh. Lead tự kiểm từng cái trước khi sửa.

| # | Finding | Kiểm chứng | Xử lý |
|---|---|---|---|
| R-1 | Formula nhiều keg bị kiểm O-3 báo sai là thất bại | ✅ `brew uninstall --help`: chỉ `--force` mới gỡ mọi version; 10 formula trên máy giữ nhiều keg | Thêm `--force`; test với brew giả hành xử như brew thật |
| R-2 | Sàn độ sâu 2 áp cho cả thư mục không phải bundle | ✅ `/Applications/Python 3.11` ở cấp 2, không được bảo vệ | Sàn hạ chỉ dành cho đường dẫn `.app`; test trên `/Library/Fonts` |
| R-3 | Bộ lọc là `brew leaves -r`, không phải `brew leaves`; receipt thiếu key bị ẩn | ✅ đọc help và code | Sửa tài liệu cho đúng; receipt không nói lý do thì giữ lại |
| R-4 | Lời từ chối PEP 668 dựa trên pip đầu tiên, không theo Python của dòng | ✅ máy có dòng python3.12/3.13, chỉ có pip 3.14 | So version pip với version site-packages; lệch thì nói đúng lý do lệch |
| R-5 | Cask app không còn đường lui về Trash khi brew thất bại | Đánh đổi của quyết định U-6 | Không sửa — xem dưới |
| R-6 | Support files bị bỏ qua lặng lẽ khi bundle không gỡ được | ✅ đọc code | Summary giờ ghi rõ bao nhiêu file được giữ lại và vì sao |
| R-7 | Sheet đọc đĩa trên main actor mỗi lần render | ✅ đọc code | Tính một lần trong `prepare()` |
| R-8 | `…` không phân biệt được "đang đo" với "không đo được" | ✅ đọc code | `—` khi đã đo xong mà không có số |
| R-9 | `forget` khớp cask theo hai cách biểu diễn | ✅ đọc code | Dòng Caskroom cũng mang `cask`; một phép so sánh |
| R-10 | Hai cơ chế cho một race (khoá Refresh + generation) | ✅ đọc code | Bỏ khoá Refresh, giữ generation |

**R-5 — đánh đổi, không phải lỗi.** Cask có stanza `uninstall` cần root (xoá trong `/Library`,
`launchctl`) sẽ khiến brew gọi `sudo`; không có tty nên thất bại, và app báo nguyên output của
brew. Trước U-6, app này trash được bundle — với cái giá là sổ sách của brew bị sai. Không có gì
chạy dưới quyền root, nên invariant #7 vẫn giữ. Nếu muốn đường lui về Trash cho riêng trường hợp
này thì đó là một quyết định mới.

**Chưa kiểm bằng test:** R-7, R-8, R-10 ở tầng view, repo không có harness cho view. Generation
token của U-4/R-10 vẫn chỉ được kiểm bằng đọc code. Một formula mà chỉ cask cần
(`depends_on formula:`) vẫn hiện trong danh sách và sẽ kết thúc bằng "required by …" — receipt
của formula không ghi quan hệ đó.

**Quyết định đã chốt:** U-6 gỡ cask app qua `brew uninstall --cask` ngay từ tab Applications;
U-7 quét thêm đúng một cấp thư mục sản phẩm; O-1 chỉ liệt kê formula tự cài mà không gì
phụ thuộc; O-2 tắt nút và giải thích thay vì chạy pip.

**U-10 · P1 · phát hiện khi sửa U-6, đã sửa.** Khi bundle không gỡ được — brew báo lỗi,
hoặc thiếu quyền trên một app cài cho mọi user — support files vẫn bị ném vào Trash.
Kết quả: app vẫn còn cài nhưng mất sạch settings. Giờ support files chỉ bị động tới khi
bundle đã thật sự biến mất. Test `leavesSupportFilesAloneWhenTheApplicationCouldNotBeRemoved`
đi qua nhánh cask, vì đó là chỗ giả lập thất bại được; nhánh Trash dùng chung quy tắc
nhưng không có test riêng, vì muốn `trashItem` thất bại cần một file thuộc root.

**O-1 — ba formula lệch với `brew leaves` đã được giải thích.** `k9s`,
`kubectl-argo-rollouts`, `kubelogin` đến từ tap bên thứ ba, được cài theo yêu cầu, và
`brew uses --installed` cho thấy không gì phụ thuộc vào chúng. Chúng gỡ được; chính
`brew leaves` bỏ sót chúng. Trên máy kiểm chứng, tab Others còn 22 formula thay vì 84.

**U-4 không có test đơn vị.** Repo không có harness cho tầng view, và đường đo dung lượng
trong model đọc đĩa thật. Bản sửa gồm hai phần — vô hiệu hoá nút Refresh khi đang đo (cắt
đường chạm tới), và một generation token để lần đo đã bị thay thế không xoá cờ của lần kế
nhiệm. Cả hai chỉ được kiểm bằng đọc code, không bằng test.

## Chuẩn để đối chiếu

Không có tài liệu policy riêng cho uninstaller. Theo thứ tự thẩm quyền, chuẩn ở đây là:

1. `README.md:455-508` — mục "The uninstaller", mô tả cam kết hành vi.
2. `CLAUDE.md` — 7 invariant, đặc biệt #4 (không subprocess cho metrics), #5 (mọi deletion
   qua `PathSafety`), #7 (không chạy root).
3. `Tests/MyMacCoreTests/UninstallerTests.swift`, `Tests/MyMacUIUnitTests/UninstallerSortingTests.swift`.
4. Doc comment trong source — yếu nhất, nhưng ở repo này thường là bản ghi duy nhất của một
   quyết định đã cân nhắc.

**Nợ có sẵn, không phải do thay đổi gần đây.** `git log` vùng này: commit gần nhất chạm
uninstaller là `48fc52e` (icon) và `2a876a4` (sorting), đều trước bản sửa hôm nay.

---

## Ba nguyên nhân gốc

Tám phát hiện dưới đây quy về ba chỗ hở cấu trúc. Sửa theo gốc thì tám mục thành ba quyết định.

### Gốc A — Luật của `PathSafety` được cân theo root sâu của cleaner, rồi dùng lại nguyên vẹn cho uninstaller

Cleaner chỉ làm việc trong `~/Library/…` (sâu ≥ 4 cấp) và danh sách của nó do
`CleanupCatalog` khai báo cứng. Uninstaller thì làm việc ở `/Applications` (sâu 2 cấp) và
lấy đầu vào từ **metadata do chính app bị gỡ khai báo**. Hai giả định khác hẳn nhau, nhưng
dùng chung một bộ luật. → U-1, U-2, U-3.

### Gốc B — Đường ống đo dung lượng chỉ publish vào `items`, và cờ vòng đời của nó thuộc sở hữu của một task có thể bị thay thế

`measureSizes()` ghi kết quả vào `items` và bật/tắt `isSizing`, nhưng `pending` là một bản
sao độc lập, còn `isSizing` có thể bị task cũ đã huỷ ghi đè sau khi task mới đã bật.
→ U-4, U-5.

### Gốc C — `ApplicationCatalog` định nghĩa "ứng dụng đã cài" là "thư mục con trực tiếp có đuôi `.app`", không đối chiếu với `PackageCatalog` và không đệ quy

Định nghĩa này bỏ sót bundle lồng nhau và đồng thời liệt kê hai lần thứ được cài bằng
Homebrew Cask. → U-6, U-7.

---

## Phát hiện

| # | Mức | Vấn đề | Phân loại | Kiểm chứng |
|---|---|---|---|---|
| U-1 | **P0** | Không gỡ được bất kỳ app nào trong `/Applications` | (A) | ✅ lead — **đã sửa** |
| U-4 | **P1** | Bảng tự sắp xếp lại giữa lúc đo, ngay trên nút xoá | (A) | ✅ lead — **đã sửa** |
| U-6 | **P1** | Cask bị liệt kê ở cả hai tab; gỡ ở tab Applications làm hỏng sổ sách của brew | (A) | ✅ lead — **đã sửa** |
| U-2 | P2 | `/Applications/Utilities` là con nông duy nhất không được bảo vệ | (A) | ✅ lead — **đã sửa** |
| U-3 | P2 | Tên hiển thị của app chèn thẳng vào path component | (A) | ✅ lead — **đã sửa** |
| U-5 | P2 | Sheet và summary báo sai dung lượng khi chưa đo xong | (A) | ✅ lead — **đã sửa** |
| U-8 | P2 | Thất bại một phần để lại dòng của app đã bị xoá | (A) | ✅ lead — **đã sửa** |
| U-7 | P3 | Bundle lồng trong thư mục sản phẩm không được liệt kê | **(C)** | ✅ lead — **đã sửa** |
| U-9 | P3 | `CLAUDE.md` mô tả sai chi phí của tab Others | **(B)** | ✅ lead — **đã sửa** |

---

### U-1 · P0 · `minimumDepth = 3` từ chối mọi ứng dụng trong `/Applications` — **đã sửa**

`PathSafety.swift:104` đặt sàn độ sâu chung là 3. `/Applications/IntelliJ IDEA.app` chỉ có
2 thành phần dưới gốc volume, nên `canonicalPathForRemoval` ném `.tooShallow` trước cả khi
xét allowlist.

**Hậu quả:** không phải riêng IDEA — **mọi** ứng dụng nằm trực tiếp trong `/Applications`
đều không gỡ được, với thông báo "path is too close to the volume root" không nói lên điều gì
cho người dùng. Chỉ `/Applications/Utilities/*.app` và `~/Applications/*.app` (sâu 3) lọt qua.

**Vì sao test không bắt được:** `UninstallSafetyTests` dựng home giả trong thư mục tạm, nên
mọi bundle trong test đều ở `/private/var/folders/…/Applications/Example.app` — luôn sâu hơn 3.
Fixture che mất đúng chiều mà production khác nó.

**Đã sửa trong phiên này:** tách sàn độ sâu thành tham số của
`canonicalPathForRemoval` (mặc định vẫn 3), thêm `PathSafety.minimumApplicationDepth = 2`,
`UninstallService` dùng sàn 2 cho bundle và giữ sàn 3 cho leftovers. Ba test hồi quy, trong
đó `doesNotRefuseAnApplicationForSittingDirectlyInApplications` đã được xác nhận đỏ trước
khi sửa.

### U-4 · P1 · Refresh giữa lúc đo làm bảng tự sắp xếp lại dưới con trỏ

`UninstallerView.swift:81` — nút Refresh chỉ `.disabled(model.isLoading)`, không tính `isSizing`.
Trong lúc đo, `isLoading == false`, nên nút bấm được.

`UninstallerModel.swift:170` — `load(force:)` gọi `work?.cancel()` rồi tạo task mới.
Task cũ đang kẹt trong `UninstallService.measure(item)` (một bundle cỡ Xcode mất vài giây),
thoát vòng lặp ở lần kiểm `Task.isCancelled` kế tiếp, rồi chạy dòng cuối của `measureSizes()`:
`await MainActor.run { self.isSizing = false }` — **sau khi** task mới đã đặt `isSizing = true`.

**Hậu quả:** `isOrdered(_:before:by:)` (`UninstallerModel.swift:126-128`) mất chốt
`guard !isSizing`, nên cột Size sắp xếp lại mỗi khi một phép đo hạ cánh. Đó đúng là điều
doc comment ngay tại đó nói là để tránh: *"Re-sorting as each measurement lands would move
rows out from under the pointer, and every row here has a destructive button."*
Dòng dịch chuyển ngay dưới con trỏ đang nhắm nút thùng rác.

Kèm theo: chỉ báo "measuring sizes…" ở footer biến mất trong lúc vẫn đang đo — đó chính là
điều kiện `UninstallerSortingTests` và UI test chờ trước khi assert thứ tự.

**Cách chạm tới:** mở tab Uninstaller, bấm Refresh trong lúc footer còn hiện "measuring sizes…".

### U-6 · P1 · Ứng dụng cài bằng Homebrew Cask xuất hiện ở cả hai tab

Cask cài payload vào `/Applications`. `ApplicationCatalog.scan` thấy bundle ở đó,
`PackageCatalog.scan` thấy entry trong `Caskroom`, và không bên nào biết bên kia.

**Kiểm chứng trên máy này:** `/opt/homebrew/Caskroom` chứa `android-studio` và `libreoffice`;
`/Applications` chứa `Android Studio.app`. Cùng một phần mềm, hai dòng, hai cơ chế gỡ.

**Hậu quả:** gỡ ở tab Applications sẽ ném bundle vào Trash mà không chạm tới sổ sách của
Homebrew — `brew list --cask` vẫn báo đã cài, và lần `brew upgrade` sau sẽ hành xử trên một
thứ không còn tồn tại. Đây chính xác là điều `README.md:481-483` nói app tránh:
*"deleting a package's files by hand leaves its manager's bookkeeping inconsistent"*.
Cam kết đó được giữ cho tab Others, nhưng tab Applications mở sẵn cửa sau và không cảnh báo gì.

### U-2 · P2 · `/Applications/Utilities` là con nông duy nhất không được bảo vệ

`protectedDirectories` (`PathSafety.swift:65-68`) có `/Applications` nhưng không có
`/Applications/Utilities`. Sau U-1, sàn độ sâu cho bundle là 2, nên mọi con trực tiếp của
`/Applications` đều qua được cửa độ sâu.

**Chưa chạm tới được hôm nay:** `ApplicationCatalog` chỉ sinh ra entry có đuôi `.app`, còn
`Utilities` thì không. Nhưng nó là thư mục nông duy nhất nằm trong một root mà uninstaller
đã khai báo và lại không nằm trong tập bảo vệ — tức là lớp phòng thủ cuối cùng ở đó đang
dựa hoàn toàn vào một bất biến của tầng trên.

### U-3 · P2 · Tên hiển thị của app được chèn thẳng vào path component

`LeftoverScanner.swift:47-50` nội suy `item.name` vào đường dẫn:

```swift
library.appendingPathComponent("Application Support/\(item.name)")
library.appendingPathComponent("Logs/\(item.name)")
```

`item.name` là `CFBundleDisplayName` đọc từ `Info.plist` của chính app sắp bị gỡ — dữ liệu
do app kiểm soát, không phải do người dùng nhập.

**Kiểm chứng:** một tên chứa `/` mở rộng thành đường dẫn lồng nhau —
`Google/Chrome` → `~/Library/Application Support/Google/Chrome`. Đường dẫn đó nằm **trong**
một allowed root, nên `PathSafety` chấp nhận, và `prepare()` tick sẵn checkbox cho nó
(`UninstallerModel.swift:222`). Nhãn checkbox chỉ hiện `leftover.name` = "Chrome".

`../` thì đã bị chặn: `../Safari` chuẩn hoá thành `~/Library/Safari`, nằm ngoài mọi
leftover root → `.outsideAllowedRoot`. Chỉ còn lại lối `/`.

**Hậu quả:** một app có thể khiến uninstaller đề nghị xoá dữ liệu của app khác, đã tick sẵn.
Cần cài một app cố ý đặt tên như vậy, nên đây là hardening chứ không phải lỗ hổng đang bị
khai thác — nhưng chặn nó tốn một dòng.

### U-5 · P2 · Sheet và summary báo sai dung lượng khi mở trước lúc đo xong

`apply(sizes:)` (`UninstallerModel.swift:199`) chỉ ghi vào `items`. `pending` là bản sao
lấy tại thời điểm `prepare()`, không bao giờ được cập nhật.

**Hậu quả khi bấm nút thùng rác trên một dòng còn hiện "…":**
`pendingTotalBytes` bỏ qua bundle → sheet ghi "Removing 0 bytes"; `UninstallService` nhận
`item.size ?? 0` → `reclaimedBytes` thiếu phần bundle; summary báo một con số nhỏ hơn nhiều
so với thực tế. Không mất dữ liệu, nhưng là con số sai hiển thị ngay tại màn hình xác nhận
một hành động phá huỷ.

### U-8 · P2 · Thất bại một phần để lại dòng của app đã bị xoá

`confirm()` (`UninstallerModel.swift:264`): `if outcome.succeeded { self.items.removeAll { … } }`.
`succeeded` là `failures.isEmpty` — tính cả leftovers.

**Hậu quả:** bundle đã vào Trash nhưng một leftover từ chối xoá (chẳng hạn quyền) →
`succeeded == false` → dòng ở lại danh sách cho một app không còn tồn tại. Bấm gỡ lần nữa
thì `.doesNotExist` bị bỏ qua im lặng → `trashedCount == 0`, `failures` rỗng → summary báo
"Removed X · 0 items" rồi mới xoá dòng. Tự lành, nhưng đi qua hai màn hình nói sai.

### U-7 · P3 · **(C) — luật chưa định nghĩa** · Bundle lồng trong thư mục sản phẩm không được liệt kê

`ApplicationCatalog.scan` duyệt đúng một cấp (`contentsOfDirectory` + lọc `pathExtension == "app"`).

**Kiểm chứng trên máy này:** `/Applications/Python 3.11/IDLE.app` tồn tại và không có trong danh sách.

Với helper bên trong bundle (`Zalo.app/Contents/ZaloHelper.app`) thì **không liệt kê là đúng**.
Với thư mục sản phẩm cấp một (Adobe, Python.org, một số bản cài JetBrains) thì app đơn giản
là vắng mặt, không có dấu hiệu gì.

**Đây là câu hỏi, không phải task:** quét đệ quy một cấp sẽ nhặt được thư mục sản phẩm nhưng
cũng nhặt luôn helper của mọi bundle, và gỡ một helper là xoá ruột một app đang chạy. Cần
bạn quyết: giữ nguyên một cấp (và nói rõ trong README), hay đệ quy một cấp nhưng bỏ qua
bất cứ thứ gì nằm dưới một `.app` khác.

### U-9 · P3 · **(B) — tài liệu sai, code đúng**

`CLAUDE.md`, mục UI tests: *"Switching to it measures every installed package, **spawning a
package manager per entry**"*.

**Kiểm chứng:** `grep -rn "CommandRunner.run\|Process()" Sources/` cho đúng **một** call site —
`UninstallService.swift:113`, trong `removePackage`, tức chỉ khi người dùng thật sự bấm gỡ.
Không có subprocess nào trong đường liệt kê; chi phí thực là `DirectorySizer.measure` cho
từng package. Kết luận ("đừng viết UI test cho tab Others") vẫn đúng, chỉ lý do là sai —
và một lý do sai sẽ dẫn người đọc sau tối ưu nhầm chỗ.

---

## Bổ sung 2026-09-23 — tab Others (gỡ package)

Đo trực tiếp trên máy này, với đúng environment mà `CommandRunner` dựng
(`PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, `CI=1`, `NO_COLOR=1`,
stdin `/dev/null`). Không có lệnh gỡ thật nào được chạy: mọi phép thử dùng tên package không
tồn tại, hoặc một venv dùng một lần trong scratchpad.

### Gốc D — `removePackage` coi "tool thoát mã 0" là "đã gỡ xong"

`UninstallService.swift:113-118` chạy tool rồi trả về `Outcome(trashedCount: 1, …, failures: [])`
bất cứ khi nào exit code là 0. Không có bước nào đối chiếu xem thứ vừa yêu cầu gỡ có thật sự
biến mất hay không. Mọi package manager ở đây đều có ít nhất một đường thoát 0 mà không làm gì.
→ O-3.

| # | Mức | Vấn đề | Kiểm chứng |
|---|---|---|---|
| O-3 | **P1** | Báo "đã gỡ" khi tool thoát 0 mà không gỡ gì | ✅ lead — **đã sửa** |
| O-1 | **P1** | 65/84 formula Homebrew chắc chắn báo lỗi khi gỡ | ✅ lead — **đã sửa** |
| O-2 | **P1** | Mọi package Python đều báo lỗi `externally-managed-environment` | ✅ lead — **đã sửa** |
| O-4 | P2 | Size hiện `0 B` cho package có tên phân phối khác tên thư mục | ✅ lead — **đã sửa** |

### O-3 · P1 · Thoát mã 0 mà không gỡ gì → app báo thành công sai

Hàng trong danh sách đến từ **một prefix cụ thể**, nhưng `executables(near:)` chỉ phân hoạch
thứ tự ưu tiên rồi lấy file thực thi đầu tiên tồn tại — nó không kiểm tra tool đó có quản lý
đúng prefix ấy không. Khi hai bên lệch nhau, tool thoát 0 và không làm gì:

```
$ npm uninstall --global <không-tồn-tại>     →  "up to date in 679ms"                    exit 0
$ pip uninstall --yes <không-tồn-tại>        →  "WARNING: Skipping … as it is not installed"  exit 0
```

**Hậu quả:** `succeeded == true` → SummarySheet ghi **"Removed X · 1 item"**, `confirm()` xoá
dòng khỏi danh sách (`UninstallerModel.swift:264`), package vẫn nguyên trên đĩa. Dòng cảnh báo
thật có nằm trong ô output, nhưng tiêu đề nói ngược lại nó.

**Chạm tới được ngay trên máy này:** catalog quét site-packages của `python3.12`, `3.13` **và**
`3.14`, nhưng chỉ tồn tại một `/opt/homebrew/bin/pip3` (của 3.14). Mọi hàng Python đến từ 3.12
hoặc 3.13 sẽ được gỡ bằng pip của 3.14. Hôm nay O-2 che mất đường này vì pip lỗi trước; trên
máy dùng pyenv hoặc python.org thì nó lộ ra nguyên vẹn.

Cùng một dạng cho npm khi global prefix của `npm` được resolve khác với root đã sinh ra hàng
(`/opt/homebrew/lib/node_modules` vs `~/.npm-global/lib/node_modules`).

### O-1 · P1 · Phần lớn formula Homebrew chắc chắn báo lỗi khi gỡ

Tab Others liệt kê **mọi** thư mục trong `Cellar`, tức cả dependency lẫn thứ người dùng tự cài.

**Đo trên máy này:** `ls /opt/homebrew/Cellar` → **84**; `brew leaves` → **19**.
Tức **65 hàng** sẽ làm `brew uninstall --formula X` thất bại với *"Refusing to uninstall …
because it is required by …"*. Ví dụ đã kiểm: `brotli` là dependency của `node`.

Người dùng không có cách nào biết trước hàng nào gỡ được: cột Manager chỉ ghi "Homebrew",
sheet xác nhận vẫn hiện lệnh và vẫn bật nút Uninstall. Popup lỗi là kết quả mặc định cho
đa số hàng trong tab.

### O-2 · P1 · Mọi package Python đều báo lỗi PEP 668

`/opt/homebrew/bin/pip3` trỏ tới `../Cellar/python@3.14/3.14.7/bin/pip3`, và interpreter đó có
file `EXTERNALLY-MANAGED`. Đo với đúng environment của app:

```
error: externally-managed-environment
× This environment is externally managed
╰─> To install Python packages system-wide, try brew install xyz …
    If you wish to install a Python library that isn't in Homebrew,
    use a virtual environment: python3 -m venv path/to/venv
exit 1
```

**Hậu quả:** không một package Python nào trong tab Others gỡ được, và thông báo người dùng
nhận được là một đoạn dài khuyên họ tạo virtualenv — không liên quan gì tới việc họ vừa yêu cầu.
Exit code 1 nên ít nhất app báo thất bại chứ không báo nhầm thành công.

Với Homebrew Python, cách gỡ đúng là `brew uninstall`, không phải `pip uninstall`.

### O-4 · P2 · Size hiện `0 B` khi tên phân phối khác tên thư mục

`PackageCatalog.swift:92` dựng location là `site-packages/<tên-lấy-từ-dist-info>`. Tên phân phối
và tên thư mục import thường khác nhau.

**Đo trên máy này**, trong `/opt/homebrew/lib/python3.14/site-packages`:
`pillow-12.2.0.dist-info` → không có thư mục `pillow` (thư mục thật là `PIL`);
`ndiff-7.99.dist-info` → không có thư mục `ndiff`.

`DirectorySizer.measure` trên đường dẫn không tồn tại trả về 0, và `UninstallService.measure`
biến mọi lỗi thành `?? 0`. Cột Size vì thế hiện **"0 B"** — một con số sai — thay vì "…" vốn là
ký hiệu dành cho "chưa đo được". Không ảnh hưởng tới việc gỡ, vì `pip` tự chuẩn hoá tên.

---

## Đã kiểm và thấy đúng

Phần này là khoảng trống âm bản: không có nó thì người đọc không phân biệt được "đã kiểm, ổn"
với "chưa kiểm".

**`CommandRunner`** — không có shell ở bất kỳ đâu; `Process` nhận executable URL + mảng
argument. `standardInput = FileHandle.nullDevice`, nên một tool hỏi câu hỏi sẽ không treo mãi.
Deadline được lập **trước** khi có gì chặn, SIGTERM rồi 5 giây ân hạn rồi SIGKILL.
`terminationHandler` gắn trước `run()`. `ExitWaiter`/`OutputCollector` khoá đúng và chỉ resume
continuation một lần. Pipe được rút song song với việc chờ, nên buffer đầy không chặn tiến
trình con. `validate` từ chối ký tự lạ và từ chối `-` đứng đầu.

**`PackageCatalog`** — quét **mọi** install root chứ không chỉ root đầu tiên (Homebrew arm64
và x86_64 song song). `id` khoá theo location chứ theo tên, nên cùng một package dưới hai
prefix không đè nhau. Yarn đọc manifest thay vì `node_modules` (v1 hoist toàn bộ transitive).

**`PathSafety`** (ngoài U-2) — `lstat` chứ không `stat`, nên symlink bị nhận diện chứ không bị
đi theo. Chuẩn hoá **thư mục cha** qua `realpath` để lộ ra symlink ở giữa đường. `isDescendant`
so theo nguyên path component, nên `/a/bc` không nằm trong `/a/b`, và không gì là hậu duệ của
chính nó. Mọi root của `CleanupCatalog` tự động vào tập bảo vệ.

**`DirectorySizer`** — không đi theo symlink, bộ nhớ có chặn trên, kiểm cancellation mỗi 512 mục.

**`ApplicationCatalog`** — loại app của Apple (`com.apple.` prefix), bỏ qua bundle là symlink,
`seen` chặn trùng giữa ba search location.

**`UninstallerModel.isOrdered`** — là một total order thật: mọi cột đều rơi về tên, tên hoà thì
rơi về `id`. Item chưa đo được luôn nằm cuối bất kể chiều mũi tên.

**Toàn bộ gỡ ứng dụng đi qua Trash**, không `unlink` thẳng; không có `sudo`, không helper
đặc quyền (invariant #7 giữ nguyên).

---

## Thứ tự đề nghị làm

Xếp theo chi phí và mức ràng buộc, không chỉ theo mức nghiêm trọng.

1. **U-4** — một dòng: `.disabled(model.isLoading || model.isSizing)`, hoặc chắc hơn là gắn
   `isSizing` với một token thế hệ để task cũ không ghi đè được. Rẻ nhất, và đang nói dối
   người dùng ngay trên nút phá huỷ.
2. **U-5** — đồng bộ `pending.size` trong `apply(sizes:)`, hoặc đọc size từ `items` thay vì
   từ bản sao. Vài dòng.
3. **U-3** — `guard !item.name.contains("/")` trước hai dòng ghép tên. Một dòng.
4. **U-8** — tách điều kiện: xoá dòng khi *bundle* vào được Trash, độc lập với leftovers.
5. **U-2** — thêm `/Applications/Utilities` vào `protectedDirectories`. Một dòng, kèm test.
6. **U-9** — sửa `CLAUDE.md`, giữ kết luận, thay lý do.
7. **U-6** — tốn nhất và cần thiết kế: đối chiếu bundle với `Caskroom` để hoặc gộp hai dòng,
   hoặc hiện cảnh báo ở sheet xác nhận của tab Applications. Nên làm sau khi bạn chốt U-7,
   vì cả hai đều là câu hỏi "cái gì được tính là một ứng dụng đã cài".
8. **U-7** — **bị chặn bởi quyết định của bạn.** Xem mục U-7.
