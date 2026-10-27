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
Mỗi lần build lại, chữ ký thay đổi nên có thể phải cấp lại quyền Trợ năng.

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
- **Hành vi**: tự động ẩn/hiện (kèm độ trễ và tốc độ), hiệu ứng nảy khi mở
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
- Chuột phải vào app: danh sách cửa sổ (cần quyền Trợ năng), Tùy chọn (Giữ
  trong Dock, Hiển thị trong Finder, Chuyển sang Dock khác), Ẩn, Thoát; giữ ⌥
  để thành Buộc thoát.
- Chuột phải vào Thùng rác: Mở, Dọn sạch Thùng rác (có hỏi xác nhận).
- Chuột phải vào vạch ngăn hoặc nền Dock: bật/tắt ẩn, phóng to, vị trí,
  màn hình, khóa nội dung, Cài đặt Dock…
- ⌘-click để hiện mục trong Finder.

Tab **Chung**: mở cùng lúc đăng nhập; cấp quyền Trợ năng (không bắt buộc) để
khi bấm app trên một Dock, cửa sổ của app nằm trên màn hình đó được đưa lên
trước, và để menu chuột phải liệt kê các cửa sổ.

Lần chạy đầu tiên tự tạo một Dock ở cạnh dưới cho mỗi màn hình phụ (màn hình
chính vẫn dùng Dock hệ thống), sao chép sẵn nội dung và kích thước của Dock
hệ thống.

## Cấu hình

Lưu tại `~/Library/Application Support/MultiDock/config.json`. Xóa file này để
quay về mặc định.

## Hiệu năng

- Không có timer chạy liên tục. Danh sách app cập nhật theo thông báo của
  NSWorkspace; việc quét cửa sổ theo màn hình chỉ chạy mỗi ~2 giây khi có Dock
  dùng chế độ "app trên màn hình này".
- Icon được vẽ một lần thành texture; phóng to chỉ đổi khung layer
  (Core Animation, chạy trên GPU).
- Theo dõi chuột toàn cục chỉ bật trong lúc con trỏ đang ở trên Dock.
- Đo thực tế lúc rảnh: 0.0% CPU, ~16 MB bộ nhớ.

## Hạn chế đã biết

- Dock hệ thống của macOS tự nhảy sang màn hình khi bạn đưa chuột xuống đáy màn
  hình đó, nên có thể đè lên MultiDock nếu cả hai cùng nằm ở cạnh dưới. Cách
  tránh: đặt MultiDock ở cạnh khác, hoặc chuyển Dock hệ thống sang trái/phải
  (Dock hệ thống ở trái/phải không nhảy màn hình).
- Không có badge thông báo và "Hiển thị tất cả cửa sổ" (cần API riêng của
  Apple).
- Các cài đặt về thu nhỏ cửa sổ (hiệu ứng Genie/Thu nhỏ, thu nhỏ vào biểu
  tượng app, bấm đúp thanh tiêu đề) chỉ Dock hệ thống điều khiển được, nên
  MultiDock không có.
- Biểu tượng Thùng rác đầy/rỗng cần quyền Truy cập toàn bộ ổ đĩa để đọc
  `~/.Trash`; không có quyền thì luôn hiện thùng rỗng.
