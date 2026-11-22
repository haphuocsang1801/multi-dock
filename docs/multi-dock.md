# MultiDock

Ứng dụng macOS (menu bar) tạo thêm Dock riêng cho từng màn hình, giống
ExtraDock. Viết bằng Swift + AppKit, chạy theo sự kiện nên gần như không tốn CPU
khi rảnh.

Mã nguồn: [`Sources/MultiDock`](../Sources/MultiDock).

## Build và cài đặt

Yêu cầu macOS 13 trở lên và Xcode (hoặc Command Line Tools có Swift). Chạy từ
thư mục gốc của repo:

```bash
./scripts/build-app.sh            # tạo build/MultiDock.app
./scripts/build-app.sh --install  # tạo và copy vào ~/Applications
```

App ký ad-hoc. Lần đầu mở, nếu macOS chặn, bấm chuột phải vào app → Open.
Script ký app theo bundle ID (`com.hasang.multidock`) nên quyền Trợ năng được
giữ qua các lần build. Nếu quyền từng cấp cho bản build cũ (trước khi đổi cách
ký), mục MultiDock trong Trợ năng trông như đang bật nhưng không còn tác dụng:
xóa nó (nút −) rồi thêm lại, hoặc chạy
`tccutil reset Accessibility com.hasang.multidock` rồi cấp lại.

Icon app vẽ ở [`Resources/AppIcon.svg`](../Resources/AppIcon.svg); build chỉ dùng
`Resources/AppIcon.icns` đã tạo sẵn. Sửa SVG xong thì chạy
`./scripts/make-icon.sh` (cần `rsvg-convert`: `brew install librsvg`) để tạo lại
file `.icns`.

GitHub Actions ([`.github/workflows/build.yml`](../.github/workflows/build.yml))
build app trên runner `macos-26` mỗi khi push lên `main` hoặc mở PR, và đính
`MultiDock.zip` vào trang của lần chạy đó. Để phát hành, push một tag dạng
`v1.2.0`: workflow ghi số phiên bản vào app rồi tạo GitHub Release kèm file zip.

## Sử dụng

Giao diện bám theo Dock của macOS (đo trực tiếp từ Dock hệ thống): các ô icon
sát nhau, nền kính (Liquid Glass) bo góc, chấm nhỏ dưới app đang mở, Thùng rác
ở cuối sau vạch ngăn. Thứ tự giống macOS: app đã ghim → app đang chạy (và app
gần đây nếu bật) → thư mục/file đã ghim → Thùng rác.

Dock tự theo **Cài đặt hệ thống › Giao diện**, không cần cài riêng:

- **Sáng/Tối/Tự động**: nền kính, nhãn tên, chấm, vạch ngăn, Thùng rác.
- **Liquid Glass** (thanh trượt Trong ↔ Phủ màu): nền Dock, nhãn tên, Stack
  dùng kính chuẩn của macOS nên đổi theo.
- **Kiểu biểu tượng và tiện ích** (Mặc định/Tối/Trong/Phủ màu, Luôn luôn/Tự
  động) và **Màu thư mục**: icon được vẽ lại ngay khi đổi.
- **Giảm độ trong suốt / Tăng độ tương phản** (Trợ năng): kính tự đổi theo.

"Màu chủ đề" và "Phủ màu nền cửa sổ theo hình nền" chỉ áp dụng cho cửa sổ ứng
dụng, Dock hệ thống cũng không dùng.

Biểu tượng Dock trên menu bar → **Cài đặt…**:

- **Vị trí**: màn hình, cạnh (dưới/trái/phải/trên).
- **Kích thước và phóng to**: kích thước 16–128, bật/tắt phóng to và mức
  phóng to (giống Dock hệ thống).
- **Giao diện** (riêng cho từng Dock): chủ đề màu (Hệ thống, macOS cổ điển,
  Than chì, Đại dương, Hoàng hôn, Rừng, Neon hồng/xanh/chanh, Tùy chỉnh); nền
  Kính (Liquid Glass, phủ màu theo chủ đề), Màu đặc hoặc Trong suốt (không
  nền); màu nền và độ đậm, màu và độ dày viền, viền phát sáng kiểu neon, màu
  chấm chỉ báo và vạch ngăn; khoảng cách giữa icon (0–24) và độ bo góc. Chủ đề
  "Hệ thống" giữ giao diện mặc định theo Sáng/Tối; sửa một màu bất kỳ sẽ chuyển
  sang "Tùy chỉnh". Nút **Khôi phục mặc định** đưa toàn bộ phần Giao diện của
  Dock đó về như ban đầu.
- **Hành vi**: tự động ẩn/hiện (kèm độ trễ và tốc độ), tự động ẩn khi màn
  hình đó có app toàn màn hình (mặc định bật; đưa chuột ra cạnh màn hình để
  hiện lại, giống Dock macOS — nhưng nếu Dock hệ thống nằm cùng cạnh thì
  MultiDock ẩn hẳn và nhường cho Dock hệ thống, vì macOS luôn hiện Dock hệ
  thống ở cạnh đó khi toàn màn hình), giữ chỗ cho Dock khi phóng to cửa sổ
  (mặc định bật, xem bên dưới), hiệu ứng nảy khi mở
  ứng dụng, chỉ báo app đang mở, làm mờ icon app bị ẩn, hiển thị app gần đây,
  hiển thị Thùng rác, khóa nội dung Dock.
- **App đang chạy**: chỉ mục đã ghim / app có cửa sổ trên màn hình này (mặc
  định) / tất cả app đang chạy.
- **Sao chép từ Dock hệ thống**: lấy Finder, các app và thư mục đã ghim, kích
  thước, phóng to từ Dock của macOS.

Thao tác trên Dock:

- Kéo app/thư mục/file từ Finder thả vào Dock để ghim; kéo icon để sắp xếp;
  kéo ra ngoài hoặc vào Thùng rác để xóa khỏi Dock; kéo sang Dock khác để chuyển.
- Thả file lên icon app để mở bằng app đó; thả lên Thùng rác để đưa vào Thùng rác.
- Kéo vạch ngăn lên/xuống (hoặc sang ngang với Dock dọc) để đổi kích thước.
- Bấm thư mục để mở dạng lưới (Stack) hoặc danh sách; chuột phải vào thư mục
  để đổi "Sắp xếp theo" (tên, ngày thêm, ngày sửa đổi, loại) và "Xem nội dung
  dưới dạng".
- Chuột phải vào app đang chạy: menu giống hệt Dock macOS, gồm danh sách cửa
  sổ (✓ cửa sổ hiện tại), các lệnh riêng của app (ví dụ Chrome: Hồ sơ, Cửa sổ
  mới, Cửa sổ ẩn danh mới), Hiển thị tất cả cửa sổ, Ẩn, Thoát; giữ ⌥ để thành
  Ẩn các app khác / Buộc thoát. Mục Tùy chọn là của MultiDock (Giữ trong Dock,
  Hiển thị trong Finder, Chuyển sang Dock khác).
  Ứng dụng chỉ đưa menu này cho Dock hệ thống, nên MultiDock đọc nó qua quyền
  Trợ năng và chạy lệnh qua Dock hệ thống; menu của Dock hệ thống mở thoáng
  (~0,2 giây) trên màn hình chứa Dock hệ thống. Chưa cấp quyền Trợ năng thì
  menu rút gọn: Tùy chọn, Ẩn, Thoát.
- Chuột phải vào Thùng rác: Mở, Dọn sạch Thùng rác (có hỏi xác nhận).
- Chuột phải vào vạch ngăn hoặc nền Dock: bật/tắt ẩn, ẩn khi toàn màn hình, phóng to, vị trí,
  màn hình, khóa nội dung, Cài đặt Dock…
- ⌘-click để hiện mục trong Finder.
- **Badge thông báo**: số tin chưa đọc (hoặc chấm, chữ) mà app gắn lên icon
  hiện ở góc trên bên phải, giống Dock hệ thống. App chỉ gắn badge lên icon của
  mình trong Dock hệ thống, nên MultiDock đọc lại badge từ đó qua quyền Trợ năng
  (khoảng 2 giây một lần). Tắt badge của một app ở **Cài đặt hệ thống › Thông
  báo** thì MultiDock cũng ẩn theo.
- **Đổi biểu tượng**: chuột phải vào app, thư mục hoặc file → Tùy chọn → Đổi
  biểu tượng… rồi chọn ảnh (PNG, ICNS, JPEG…) hoặc một app để mượn icon của nó;
  Dùng biểu tượng gốc để bỏ. Cũng làm được ở danh sách Mục đã ghim trong Cài đặt
  (nút ảnh). Icon áp dụng cho app đó trên mọi Dock, kể cả khi app chỉ đang chạy
  mà không ghim; ảnh được chép vào
  `~/Library/Application Support/MultiDock/Icons/`.

Tab **Chung**: mở cùng lúc đăng nhập; cấp quyền Trợ năng (không bắt buộc) để
khi bấm app trên một Dock, cửa sổ của app nằm trên màn hình đó được đưa lên
trước, để menu chuột phải liệt kê các cửa sổ, để hiện badge thông báo, và để
giữ chỗ cho Dock.

**Giữ chỗ cho Dock**: macOS chỉ chừa chỗ cho Dock hệ thống, nên cửa sổ phóng
to (nút xanh, bấm đúp thanh tiêu đề, Cửa sổ › Lấp đầy, xếp ô) vẫn phủ xuống
dưới MultiDock. Khi bật, MultiDock theo dõi việc đổi kích thước cửa sổ qua quyền
Trợ năng và cắt cửa sổ lại cho dừng ở mép Dock, giống Dock hệ thống. Kéo di
chuyển cửa sổ thì không bị can thiệp (macOS cũng cho kéo cửa sổ xuống dưới
Dock); đang kéo mép để đổi cỡ thì đợi thả chuột mới cắt. Không áp dụng khi Dock
đang ẩn (tự ẩn, toàn màn hình, nhường cho Dock hệ thống) và với cửa sổ toàn màn
hình.

Lần chạy đầu tiên tự tạo một Dock ở cạnh dưới cho mỗi màn hình phụ (màn hình
chính vẫn dùng Dock hệ thống), sao chép sẵn nội dung và kích thước của Dock
hệ thống.

## Cấu hình

Lưu tại `~/Library/Application Support/MultiDock/config.json`. Xóa file này để
quay về mặc định.

## Hiệu năng

- Danh sách app cập nhật theo thông báo của NSWorkspace. Việc quét cửa sổ
  (app nào ở màn hình nào, Dock hệ thống đang hiện ở đâu) chạy mỗi ~2 giây
  khi có ít nhất một Dock, và ~10 lần/giây chỉ trong lúc con trỏ ở sát cạnh
  có Dock hệ thống (hoặc lúc MultiDock đang nhường chỗ cho nó).
- Icon được vẽ một lần thành texture; phóng to chỉ đổi khung layer
  (Core Animation, chạy trên GPU).
- Theo dõi di chuyển chuột toàn cục luôn bật nhưng chỉ so tọa độ; phần việc
  nặng (phóng to, nhãn tên) chỉ chạy khi con trỏ ở trên Dock.
- Đo thực tế lúc rảnh: 0.0% CPU, ~16 MB bộ nhớ.

## Hạn chế đã biết

- Dock hệ thống của macOS tự nhảy sang màn hình khi bạn đưa chuột xuống đáy màn
  hình đó (và luôn hiện ở đáy màn hình nào khi có app toàn màn hình). MultiDock
  không chặn được việc này; thay vào đó, khi Dock hệ thống hiện trên màn hình
  và cùng cạnh với một MultiDock, MultiDock đó ẩn đi (chậm khoảng nửa giây) và
  hiện lại khi Dock hệ thống rời đi, để hai Dock không đè lên nhau. Nếu Dock
  hệ thống không tự ẩn, nó ở lại màn hình đó cho tới khi bạn đưa chuột xuống
  đáy màn hình khác. Muốn MultiDock luôn hiện: đặt MultiDock ở cạnh khác, hoặc
  chuyển Dock hệ thống sang trái/phải (Dock hệ thống ở trái/phải không nhảy
  màn hình).
- Giữ chỗ cho Dock là cắt cửa sổ sau khi app đã phóng to nó, nên cửa sổ có thể
  phủ kín màn hình trong chốc lát rồi mới co lên. Cửa sổ đã phóng to từ trước khi
  bật tính năng chỉ được cắt ở lần đổi cỡ kế tiếp. App có kích thước tối thiểu
  lớn hơn chỗ còn lại hoặc không cho đổi cỡ qua Trợ năng thì không co được.
- Badge thông báo cập nhật chậm hơn Dock hệ thống tới khoảng 2 giây (Dock hệ
  thống không báo khi badge đổi nên MultiDock phải đọc định kỳ), và cần quyền
  Trợ năng.
- Menu chuột phải là menu chuẩn của macOS, không có mũi tên chỉ vào icon như
  menu của Dock hệ thống.
- Các cài đặt về thu nhỏ cửa sổ (hiệu ứng Genie/Thu nhỏ, thu nhỏ vào biểu
  tượng app, bấm đúp thanh tiêu đề) chỉ Dock hệ thống điều khiển được, nên
  MultiDock không có.
- Biểu tượng Thùng rác đầy/rỗng cần quyền Truy cập toàn bộ ổ đĩa để đọc
  `~/.Trash`; không có quyền thì luôn hiện thùng rỗng.
