# DBI Backend

macOS 原生的 DBI「从 DBIbackend 安装游戏」电脑端：把 NSP / NSZ / XCI / XCZ 拖进窗口，在 Switch 上选择要装的游戏，边传边装。
没有 4 GB 限制，不占 SD 卡空间，也不需要屏蔽 macOS 的任何系统服务。

要求 macOS 13 或更新版本。目前没有打包好的下载，需要自己用 Xcode 编译（见下方「开发」）。

> 本项目与 DBI 作者、任天堂均无关联。请只安装你合法拥有的游戏。

## 用法

1. 打开 DBI Backend。
2. 在 Switch 上打开 DBI，选「从 DBIbackend 安装游戏」。窗口会显示「已连接 Switch」。
3. 把游戏文件或文件夹拖进窗口（或 ⌘O 添加）。
4. 在 Switch 上选择要安装的游戏。

## 工作原理

- 进入这个模式后，Switch 换成另一个 USB 身份：VID `0x057E`、PID `0x3000`、名字 "DBI"，只有一个厂商自定义接口（class `0xFF`），端点 `0x01` 发、`0x81` 收。
  macOS 的 ptpcamerad 只认 PTP/MTP 设备，不会占这个接口，所以用 IOUSBHost 直接打开即可（2026-10-08 实测）。
  IOKit 按 VID/PID 匹配接口时必须同时给接口号和配置号，否则匹配不到。
- 协议和 DBI 官方的 [dbibackend](https://github.com/rashevskyv/dbi/blob/main/dbibackend) 一致：16 字节头 `"DBI0"` + 类型 + 命令 + 长度；
  Switch 要列表（`LIST`）、要某个文件的某一段（`FILE_RANGE`，偏移 64 位），电脑照发；`EXIT` 表示 Switch 退出这个模式。
- DBI 会先读文件头和文件尾、也会重读同一段，所以进度按"已发送的区间"合并计算（`Coverage`）。

## 实测（2026-10-08，DBI，Switch 固件 22.5.0）

- 7.7 GB NSZ：传输 38–39 MB/s，约 3 分 20 秒装完，游戏正常启动。
- 11.43 GB NSP：装完，游戏正常启动。

## 开发

```bash
xcodegen generate
xcodebuild -project DBIBackend.xcodeproj -scheme DBIBackend test
```

代码结构：
- `Backend/DBIProtocol.swift`：协议和会话循环（不碰 USB，可单测）
- `Backend/USBLink.swift`：IOUSBHost 打开接口、阻塞读写
- `Backend/Installer.swift`：监听 Switch 插拔、游戏列表、会话线程
- `Backend/Coverage.swift`：进度区间
- `UI/MainWindowController.swift`：唯一的窗口
