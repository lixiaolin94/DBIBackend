# 更新记录

每个版本发布前在「未发布」下面写清楚改了什么；`scripts/bump_version.sh` 发版时会把它改成版本号，
这一节的内容同时用作 GitHub Release 说明和 Sparkle 更新窗口里的说明。规则见 [docs/RELEASE.md](docs/RELEASE.md)。

## 未发布

- 第一个公开版本：macOS 原生的 DBI「从 DBIbackend 安装游戏」电脑端。
- 把 NSP、NSZ、XCI、XCZ 文件或文件夹拖进窗口，在 Switch 上选择要装的游戏，边传边装。没有 4 GB 限制，不占 SD 卡空间。
- Switch 进入这个模式时自动连上并把窗口拿到前面；拔线或退出后自动回到等待。
- 列表显示每个游戏的大小、安装进度和实时速度；列宽会被记住。
- 应用内自动更新（Sparkle）：每天检查一次，也可以从菜单「检查更新…」手动检查。
- 实测：7.7 GB NSZ、11.4 GB NSP 都能装好并正常启动，传输速度约 38–39 MB/s（USB 2.0）。
