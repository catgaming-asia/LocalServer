# Local Server (macOS)

App macOS phát CLR và Addressables của project qua Wi-Fi để điện thoại tải về khi test, **không cần mở Unity**, không cần Python.
Đây là công cụ Local Server chính thức của project (Build Tool không còn nút Local Server). Đường dẫn:

| URL | File trên máy |
|---|---|
| `http://<IP>:<port>/clr/<version>/<platform>/<file>` | `Export/CLR/deuegambit/<version>/<platform>/Upload/<file>` |
| `http://<IP>:<port>/addressables/<path>` | `ServerData/<path>` |

Build Tool export CLR / build Addressables vào thư mục theo môi trường (`Export/CLR/deuegambit/<env>/…`, `ServerData/<env>/…`) rồi tự chép bản mới nhất ra 2 đường dẫn trên, nên app luôn phát bản build gần nhất mà không cần chọn môi trường.

Repo: https://github.com/catgaming-asia/LocalServer

## Mở app

`build/LocalServer.app` đã được commit sẵn, mở thẳng:

```bash
open build/LocalServer.app
```

## Build lại

Cần macOS 14+ và Xcode (Swift 5.9+). Bấm đúp `build/build-app.command` trong Finder hoặc:

```bash
build/build-app.command
```

- Phiên bản lấy từ `VERSION` (CFBundleShortVersionString), build number = số commit.
- Ký bằng chứng chỉ Apple Development cố định (cùng My Connector, theo SHA-1) để macOS không hỏi lại quyền Local Network sau mỗi lần build; máy không có thì ký ad-hoc. Đổi bằng `LOCALSERVER_SIGN_IDENTITY`.
- Icon là icon game Deuce (`Resources/AppIcon.png`).

Chạy nhanh khi đang sửa code: `swift run`.

## Cập nhật (Check for Updates)

App tự kiểm bản mới khi mở (có bản mới thì hiện thanh xanh **Update…**), hoặc **Local Server › Check for Updates…** / menu bar.
App đọc `latest.json` ở thư mục công khai trên R2 (mặc định `https://data.catgaming.asia/LocalServer/release/`, đổi trong **Settings…**),
tải zip, kiểm kích thước + SHA-256 + bundle id + version, rồi thay app và mở lại.

Phát hành bản mới (trên nhánh `main`, working tree sạch):

```bash
build/release.command            # patch; hoặc minor | major | 1.2.0, thêm --notes "..." nếu muốn
```

Script tăng `VERSION`, build lại `build/LocalServer.app`, commit `Release v<x>` + tag `v<x>`, tạo `build/release/LocalServer-<x>.zip` và `latest.json`,
rồi hỏi có push không. Sau đó tải **zip trước, `latest.json` sau** lên `LocalServer/release/` trong bucket R2 và purge cache `latest.json`.

## Dùng

1. Mở app → **Project › Choose…** chọn thư mục project Unity. App tự đoán nếu nằm trong `<project>/Localserver`.
   **Addressables** và **CLR** mặc định là `ServerData` và `Export/CLR/deuegambit` trong project; **Choose…** để trỏ sang thư mục khác, **Reset** để về mặc định.
2. Chọn **LAN IP** của mạng Wi-Fi điện thoại đang dùng → **Start**. Lần đầu macOS hỏi quyền nhận kết nối mạng: chọn Allow.
3. Danh sách **CLR / Addressables** cho biết bản nào đang phát được; **Test** mở thử URL trên máy.
4. Trong Unity, Build Tool › chọn Game + Environment › **Config details › URL config** (ô xanh lá là của môi trường đang chọn):
   - `clrUrl_<env>` = `http://<IP>:8080/clr/` và **bỏ tích** `clrLocalOnly_<env>`.
   - `addressableUrl_<env>` = `http://<IP>:8080/addressables/[version]/[BuildTarget]/kid` (Adult: `/adult`).

   Rồi **Apply Configuration** → **BUILD/UPDATE ADDRESSABLE** (full build) → **UPDATE DLLs + CONTENT** → **BUILD AND RUN**.
   URL được ghi cứng vào app lúc build: đổi IP thì sửa lại URL rồi build lại. Hướng dẫn đầy đủ: `Document/BuildTool.html`.
5. **Request log** hiện từng file điện thoại tải. Mã QR là URL CLR.

Icon trên menu bar cho phép Start/Stop và copy URL khi đã đóng cửa sổ.

## Cloudflare Tunnel (HTTPS, khác mạng)

Khung **Cloudflare Tunnel** phát server ra internet qua HTTPS: điện thoại không cần chung Wi-Fi, iOS không bị chặn vì `http://`, và URL không đổi khi đổi IP. Cần `cloudflared`:

```bash
brew install cloudflared
```

- **Quick**: bấm **Start Tunnel** → URL ngẫu nhiên `https://<từ-ngẫu-nhiên>.trycloudflare.com`, không cần tài khoản. URL đổi mỗi lần start nên phải sửa URL config và build lại mỗi lần.
- **Custom domain**: URL cố định `https://<domain>`. Domain phải là zone trong tài khoản Cloudflare.
  1. Nhập **Domain** (vd. `cdn.example.com`) và **Tunnel** (tên tunnel, mặc định `deuegambit-localserver`).
  2. **Login…** một lần trên máy này. Đăng nhập Cloudflare **chưa đủ**: ở trang **Authorize Cloudflare Tunnel** phải chọn zone của domain
     (vd. `example.com` cho `cdn.example.com`) rồi bấm **Authorize**, khi đó mới có `~/.cloudflared/cert.pem` và app chuyển sang *Logged in*.
     Lỡ đóng tab: **Open Page**, hoặc **Copy** ở dòng *Login link* để dán vào trình duyệt khác; muốn làm lại: **Cancel** rồi **Login…**. Không thấy zone nào = domain chưa nằm trong tài khoản Cloudflare đó.
  3. **Start Tunnel**: app tự `cloudflared tunnel create` (nếu chưa có), `tunnel route dns --overwrite-dns` (tạo/ghi đè CNAME của domain) rồi `tunnel run`.

Khi tunnel chạy, URL trong danh sách CLR / Addressables và mã QR chuyển sang URL https. Trong Unity dùng:
`clrUrl_<env>` = `https://<domain>/clr/`, `addressableUrl_<env>` = `https://<domain>/addressables/[version]/[BuildTarget]/kid`.

Ai có URL cũng tải được file, nên tắt tunnel khi không test. Stop server hoặc thoát app cũng tắt tunnel.

## Chạy không giao diện (CLI)

Chạy trong Terminal (app Terminal của macOS hoặc tab Terminal của IDE) và để cửa sổ mở; **Ctrl-C** để dừng server và tunnel.
Không chạy bằng `!` trong ô chat của Claude Code: lệnh bị dừng ngay khi trả kết quả.
`--project` là đường dẫn tuyệt đối tới project Unity (repo này không nằm trong project).

Chỉ LAN:

```bash
build/LocalServer.app/Contents/MacOS/LocalServer --serve --project /Volumes/PM981/workspace/deuegambit --port 8080
```

LAN + tunnel HTTPS ngẫu nhiên (`https://….trycloudflare.com`, in ra ở dòng `Tunnel up:`):

```bash
build/LocalServer.app/Contents/MacOS/LocalServer --serve --project /Volumes/PM981/workspace/deuegambit --port 8080 --tunnel quick
```

LAN + domain cố định (đã `cloudflared tunnel login` hoặc **Login…** trong app một lần):

```bash
build/LocalServer.app/Contents/MacOS/LocalServer --serve --project /Volumes/PM981/workspace/deuegambit --port 8080 --tunnel cdn.example.com --tunnel-name deuegambit-localserver
```

Tuỳ chọn thêm khi không dùng thư mục mặc định: `--clr-dir /đường/dẫn/CLR` và `--addressables-dir /đường/dẫn/ServerData`.
Khi xuống dòng bằng `\`, sau `\` không được có dấu cách. Đừng dán nguyên `[...]` hay `<...>` vào zsh: đó là ký hiệu tuỳ chọn, zsh báo `bad pattern`.

### Lỗi `Address already in use` (port bị chiếm)

`Listener failed: … error 48 - Address already in use` nghĩa là đã có thứ khác nghe trên port đó, thường là chính Local Server:
một lần chạy CLI trước còn sống (tab Terminal khác, hoặc bấm Ctrl-Z thay vì Ctrl-C) hoặc app giao diện đang **Start** cùng port.

Xem ai đang giữ port 8080:

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
```

Tắt mọi Local Server chạy CLI và tunnel của nó:

```bash
pkill -f "LocalServer --serve"; pkill -f "cloudflared tunnel --no-autoupdate"
```

Hoặc tắt đúng tiến trình đang giữ port 8080:

```bash
kill $(lsof -tiTCP:8080 -sTCP:LISTEN)
```

Nếu là app giao diện thì bấm **Stop** (hoặc Quit). Không muốn tắt thì chạy CLI ở port khác, ví dụ `--port 8081`.
`kill` hay đóng cửa sổ Terminal đều tắt luôn `cloudflared`; còn sót thì lệnh `pkill` ở trên dọn nốt.

## Ghi chú

- Chỉ phục vụ `GET`/`HEAD`; không liệt kê thư mục; chặn `..` và mọi đường dẫn ra ngoài 2 thư mục gốc.
- Header `Cache-Control: no-store` để điện thoại luôn lấy bản mới.
- App chỉ phát file; URL trong build do Build Tool (URL config + Apply) quyết định.
