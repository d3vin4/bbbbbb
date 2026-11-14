# NOTICE

## bbbbbb — file manager cho iOS dựa trên kỹ thuật `worse_query`

Kỹ thuật truy cập container mà app này dùng là **`worse_query`** của
[Taj C (forcequitOS)](https://github.com/forcequitOS/worse_query) — bản quyền
**GPL-3.0-or-later**. App này là một **bản cài đặt độc lập** của cùng kỹ thuật
đó (tự viết lại từ đầu, không sao chép mã nguồn của tác giả).

Phần liệt kê thư mục bằng `fsgetpath` (dò inode để tìm đường dẫn khi không
được phép `readdir`) lấy cảm hứng từ dự án
[KAMUI / kamui-escape](https://github.com/murk-sus/kamui-escape) của murk-sus
(MIT) — cũng được viết lại độc lập.

### Điều kiện bắt buộc
`worse_query` cần **một App Group entitlement** trong profile ký: kỹ thuật hoán
đổi `Library/Caches` của app group để containermanagerd cấp token cho đường dẫn
đích. Tên app group không quan trọng — app dùng bất kỳ group nào profile cấp.

### Phần còn lại của app
Toàn bộ phần còn lại (giao diện, quét container, trình duyệt tệp, bộ xem
plist/hex/SQLite, dọn temp, nhận diện container bằng xattr) là **tự viết** cho
dự án này.

## Giấy phép
Xem `LICENSE` — GPL-3.0-or-later (kế thừa từ kỹ thuật gốc).
