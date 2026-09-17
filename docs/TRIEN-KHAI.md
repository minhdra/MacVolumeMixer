# MacVolumeMixer — Tài liệu bối cảnh & cách triển khai

Tài liệu này giải thích **tại sao** dự án này tồn tại, **cách nó hoạt động** ở mức khái niệm, và
**từng phần code khớp với nhau ra sao** — dành cho người đọc lần đầu, chưa cần biết chi tiết API
Core Audio (chi tiết API nằm ở [audio-architecture.md](audio-architecture.md) và
[architecture-options.md](architecture-options.md); hướng dẫn build/sign nằm ở
[README.md](../README.md) gốc).

## 1. Bối cảnh — bài toán cần giải

macOS không có "Volume Mixer" theo app như Windows (mỗi app có thanh volume riêng trong Windows Volume
Mixer). Trên Mac chỉ có **một** volume hệ thống dùng chung cho mọi app. Người dùng thường muốn: nghe
nhạc Spotify nhỏ hơn trong khi Chrome (đang họp) to hơn, mà không đổi volume tổng của máy.

Mục tiêu: xây một app menu bar nhỏ, cho mỗi app đang phát âm thanh (Chrome, Spotify, VLC, Discord...)
một thanh volume + nút mute riêng, độc lập hoàn toàn với volume hệ thống và với các app khác.

Ràng buộc quan trọng nhất: **chỉ dùng API public của Apple** (không driver ảo kiểu BlackHole, không
kernel extension, không private API), **native 100%** (Swift/AppKit/SwiftUI/Core Audio — không
Electron/web view), **offline hoàn toàn**, và **CPU/RAM lúc idle phải gần 0** (event-driven, không
polling).

## 2. Vì sao không đơn giản — macOS không có "gain theo từng app"

Trước khi viết bất kỳ dòng UI nào, việc đầu tiên là xác minh macOS SDK thực sự hỗ trợ gì (xem
[audio-architecture.md](audio-architecture.md) để có bằng chứng từ header SDK thật, không đoán mò).
Kết luận ngắn gọn:

- **Không tồn tại** property kiểu `kAudioProcessPropertyVolumeScalar`. HAL chỉ cho biết một process
  *đang tồn tại* và *có đang phát âm thanh hay không* (`AudioProcess` object: PID, bundle ID,
  isRunningOutput...), **không** cho set gain trực tiếp của process đó.
- macOS 14.2+ có **Process Tap** (`CATapDescription` + `AudioHardwareCreateProcessTap`) — nhưng đây là
  cơ chế **CAPTURE** (lấy mẫu âm thanh ra để ghi âm/quan sát), **không phải CONTROL** (chỉnh volume).
  Đừng nhầm hai khái niệm này — nhầm là sai kiến trúc ngay từ đầu.
- Điểm mấu chốt biến CAPTURE thành CONTROL: `CATapDescription` có cờ `muteBehavior`. Đặt
  `.muted` sẽ **im lặng đường ra loa gốc của process đó**, đồng thời ta vẫn nhận được mẫu âm thanh của
  nó qua tap. Nghĩa là: ta câm app ở nguồn, rồi tự phát lại âm thanh đó ra loa thật với mức gain do
  chính ta chọn — đó chính là "thanh volume" của mixer này.

## 3. Luồng tín hiệu (signal path) — cái này là trái tim của app

```
App gốc (vd Spotify)
      │  CoreAudio route âm thanh ra loa như bình thường
      ▼
CATapDescription(processes: [spotifyObjectID], muteBehavior: .muted)
      │  AudioHardwareCreateProcessTap → tạo ra một "tap" object
      │  Từ giờ Spotify KHÔNG còn phát tiếng ra loa nữa (bị câm ở nguồn)
      ▼
Aggregate device riêng tư, tạo ngay lúc runtime (không cài đặt gì, không persistent)
      │  gồm: tap ở trên + thiết bị output thật (loa MacBook / tai nghe...)
      ▼
IOProc của chính app MacVolumeMixer
      │  nhận buffer âm thanh (đã bị câm) của Spotify
      │  nhân từng sample với 1 hệ số gain (0.0 → 1.0) — ĐÂY LÀ THANH VOLUME
      ▼
Thiết bị output thật (loa/tai nghe)
      │
      ▼
Người dùng nghe Spotify ở mức volume do MacVolumeMixer đặt,
volume hệ thống và Chrome/Discord/... không hề bị đụng tới.
```

Toàn bộ luồng trên chỉ dùng API public, không có driver ảo nào được cài vào máy — aggregate device
được tạo bằng `AudioHardwareCreateAggregateDevice` lúc app chạy và tự huỷ khi app tắt.

## 4. Kiến trúc code — từng file làm gì

```
MacVolumeMixer/Sources/MacVolumeMixer/
├── App/
│   ├── main.swift              Khởi động NSApplication, gắn AppDelegate
│   └── AppDelegate.swift       Tạo NSStatusItem (icon 🔊 trên menu bar) + NSPopover,
│                                gọi AudioEngine.start()/stop()
├── Audio/                      ← toàn bộ logic Core Audio, KHÔNG biết gì về SwiftUI
│   ├── AudioProcessMonitor.swift   Phát hiện app nào đang phát âm thanh, bằng
│                                    property listener (event-driven, không timer)
│   ├── VolumeController.swift      Cài đặt luồng tín hiệu ở mục 3, cho MỘT app
│   ├── AudioEngine.swift           "Nhạc trưởng": ghép Monitor + VolumeController +
│                                    lưu trạng thái, expose ra danh sách app cho UI
│   └── OSStatusError.swift         Helper biến mã lỗi OSStatus thành text đọc được
├── Models/
│   └── AudioAppProcess.swift    Struct đại diện 1 dòng trong mixer (tên, icon, volume, mute...)
├── Services/
│   ├── ApplicationResolver.swift   Gộp các process con (Chrome Helper, Chrome Helper
│                                    (Renderer)...) về đúng 1 app "Chrome" duy nhất
│   └── VolumeStore.swift           Lưu volume/mute vào UserDefaults theo bundle ID
└── UI/                          ← SwiftUI thuần, chỉ đọc dữ liệu từ AudioEngine
    ├── MixerPopover.swift       Toàn bộ popover khi bấm icon menu bar
    ├── AppVolumeRow.swift       Một dòng: icon + tên + slider + nút mute
    └── SettingsView.swift       Cửa sổ Settings nhỏ (mở System Settings permission, nút Quit)
```

Nguyên tắc tách lớp: **Audio/** không import SwiftUI, không biết "popover" là gì — nó chỉ expose
`@Published var apps: [AudioAppProcess]` và 2 hàm `setVolume`/`setMuted`. **UI/** chỉ đọc dữ liệu đó,
không gọi thẳng Core Audio bao giờ. Nhờ vậy có thể test logic Audio mà không cần dựng UI (xem
`Tests/`).

## 5. Vòng đời hoạt động (chạy app thì diễn ra gì)

1. `main.swift` khởi động `NSApplication`, giao cho `AppDelegate`.
2. `AppDelegate` tạo icon menu bar + popover (popover rỗng, chưa hiện), rồi gọi `engine.start()`.
3. `AudioEngine.start()` bảo `AudioProcessMonitor` bắt đầu lắng nghe
   `kAudioHardwarePropertyProcessObjectList` (danh sách process nào đang đụng tới audio HAL).
4. Mỗi khi danh sách đổi (app mở/đóng) hoặc một app bắt đầu/ngừng phát tiếng
   (`kAudioProcessPropertyIsRunningOutput`), listener bắn callback — **không có vòng lặp polling nào
   cả**.
5. `AudioEngine` nhận callback, gom các process con về đúng "app logic" (nhờ `ApplicationResolver`),
   nạp lại volume/mute đã lưu trước đó (nhờ `VolumeStore`), rồi:
   - Nếu app đó **đang phát tiếng** → trước tiên kiểm tra quyền "Screen & System Audio Recording"
     (`CGPreflightScreenCaptureAccess()`). **Chưa có quyền thì KHÔNG câm gì cả** — chỉ hiện banner xin
     quyền trong popover. Có quyền rồi mới tạo `VolumeController` mới → thực hiện luồng ở mục 3 → câm
     app ở nguồn, phát lại ở đúng mức volume đã lưu. (Lý do bắt buộc kiểm tra trước: tap với
     `muteBehavior = .muted` vẫn câm được app ngay cả khi CHƯA có quyền — chỉ là dữ liệu âm thanh trả về
     cho mình sẽ toàn số 0, tức câm thật nhưng phát lại ra toàn im lặng. Đây chính là bug "mất hẳn tiếng"
     đã gặp và đã sửa ở bản v0.1.1.)
   - Nếu app đó **ngừng phát tiếng** → dừng và huỷ `VolumeController` (không giữ tap chạy không cho
     app im lặng — tiết kiệm tài nguyên).
   - Nếu app **thoát hẳn** → xoá luôn khỏi danh sách hiển thị.
6. Người dùng bấm icon menu bar → `AppDelegate` show popover → SwiftUI vẽ danh sách `engine.apps`.
7. Kéo slider → `AppVolumeRow` gọi `engine.setVolume(...)` → `AudioEngine` cập nhật
   `VolumeStore` (lưu lại) và, nếu app đang chạy tap, cập nhật ngay hệ số gain trong
   `VolumeController` (không cần gọi lại Core Audio "đắt tiền" nào — chỉ ghi một số Float).
8. Bấm mute → tương tự, nhưng gain hiệu dụng = 0 trong khi volume đã lưu **không đổi** (unmute lại về
   đúng mức cũ).
9. Thoát app (`applicationWillTerminate`) → `engine.stop()` → mọi tap được huỷ, mọi app đang bị câm
   được **bỏ câm lại**, mọi aggregate device được dọn sạch. Đây là bước quan trọng để không để sót app
   nào bị im lặng sau khi MacVolumeMixer tắt.

## 6. Vì sao chọn macOS 15.0 làm minimum

Cơ chế tap ở mục 3 dùng được từ macOS 14.2/14.4, nhưng code sản phẩm dùng một lớp Swift hiện đại hơn
(`AudioHardwareSystem`, `AudioHardwareProcess`, `AudioHardwareTap`...) được phát hiện bằng cách đọc
trực tiếp file `.swiftinterface` đã compile sẵn trong SDK — lớp này chỉ có từ macOS 15.0. Đổi lại, code
ngắn hơn, dùng `throws` thay vì tự check `OSStatus` thủ công ở khắp nơi, an toàn hơn. Chi tiết đầy đủ
và bằng chứng: [audio-architecture.md](audio-architecture.md), phần "Update: a newer, Swift-native Core
Audio surface exists".

## 7. Ba bug thực tế đã gặp và cách sửa

- **Mất hẳn tiếng khi mở app**: nguyên nhân đúng như cảnh báo ở mục 5 — bản v0.1.0 câm app ngay khi phát
  hiện nó đang phát tiếng, mà chưa chắc mình đã có quyền để phát lại. Sửa bằng cách gọi
  `CGPreflightScreenCaptureAccess()` (API public, cùng nhóm quyền với Screen Recording) **trước khi câm
  bất kỳ app nào** — chưa có quyền thì không đụng vào app đó, chỉ hiện banner "Grant Permission…".
  Ngoài ra còn thêm một "watchdog": nếu sau 1 giây mà luồng phát lại chưa nhận được buffer nào (trường
  hợp nhiều aggregate device tranh nhau cùng một thiết bị output vật lý), tự động huỷ tap/bỏ câm thay vì
  để app đó câm mãi mãi không rõ lý do (`AudioEngine.watchForSilentFailure`).
- **Bấm Quit không thoát hẳn**: app là menu-bar-only agent (`LSUIElement`), không có Dock icon, không có
  application menu bar → không có Cmd+Q. Sửa hai việc: (1) thêm nút Quit thẳng trong popover, không phải
  chui vào Settings mới thấy; (2) `applicationWillTerminate` giờ luôn đặt một hẹn giờ "ép thoát"
  (`exit(0)`) chạy trên queue nền, độc lập với main thread — dù bước dọn dẹp Core Audio có bị treo vì lý
  do gì, app vẫn đảm bảo thoát hẳn trong tối đa 1 giây.
- **Đã cấp quyền rồi mà vẫn câm** (bug gặp ngay sau khi sửa bug đầu tiên ở trên): cấp quyền `Screen &
  System Audio Recording` **trong lúc app đang chạy** không có tác dụng ngay — giống hệt cơ chế của
  quyền Screen Recording (macOS Sonoma gộp chung 2 quyền này). `coreaudiod` có vẻ chốt quyết định cấp
  quyền cho một process ngay tại thời điểm process đó thử tap lần đầu; bật quyền lên giữa chừng không
  làm process đang chạy nhận ra ngay, phải khởi động lại app. `AudioEngine` giờ tự phát hiện chuyển trạng
  thái "chưa có quyền → có quyền" NGAY TRONG PHIÊN CHẠY này (`needsRelaunchToUsePermission`), và nếu phát
  hiện đúng trường hợp đó thì **không thử tap nữa** (tránh lặp lại y hệt bug câm-mà-không-phát-lại), thay
  vào đó hiện nút "Restart Now" — bấm vào sẽ tự tắt app cũ, mở lại app mới (`AppDelegate.relaunch()`
  dùng `/usr/bin/open` mở lại chính bundle của mình rồi thoát tiến trình hiện tại).

## 8. Giới hạn cần biết (không giấu)

- Độ trễ thêm ~5-20ms cho app bị câm-và-phát-lại (một chu kỳ IO của HAL). Không nhận ra được khi nghe
  nhạc/video/họp, có thể nhận ra trong game nhịp điệu (rhythm game).
- Nếu MacVolumeMixer **crash** trong lúc đang câm một app, app đó có thể im lặng cho tới khi
  MacVolumeMixer khởi động lại (hoặc app đó tự restart). Thoát bình thường luôn dọn sạch.
- Nếu một app **sinh thêm process con mới giữa chừng lúc đang phát** (không phải lúc mới mở), process
  con mới đó chưa được gộp vào tap đang chạy cho tới khi app dừng rồi phát lại từ đầu.
- Kéo slider cho app **đang không phát tiếng** chỉ lưu giá trị, chưa có gì để nghe thử ngay (vì không
  giữ tap chạy khi im lặng, để tiết kiệm tài nguyên).

## 9. Đọc thêm

- Bằng chứng API, so sánh kiến trúc: [audio-architecture.md](audio-architecture.md)
- So sánh 4 phương án kiến trúc (A/B/C/D) và lý do chọn B: [architecture-options.md](architecture-options.md)
- Build, sign, permission, cách chạy: [README.md](../README.md)
- Proof-of-concept CLI chạy thật trên máy: [Prototype/README.md](../Prototype/README.md)
