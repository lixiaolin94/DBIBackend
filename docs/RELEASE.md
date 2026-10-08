# 版本与发布

分发方式：Developer ID 签名 + 公证，直接分发，Sparkle 2 应用内自动更新，安装包放在 GitHub Release。
**在本机发版**（不用 CI），流程和脚本照搬 [Pier](https://github.com/lixiaolin94/Pier/blob/main/docs/RELEASE.md)。

## 版本号规则

- 格式 `主.次.修订`，当前是 **0.1.x**；0.1.1 是第一个公开版本。
- **每次发版只把最后一位加 1**：0.1.1 → 0.1.2 → …。次版本号、主版本号只在用户明确认可时才升（`scripts/bump_version.sh 0.2.0`）。
- 构建号 `CFBundleVersion` 等于版本号。Sparkle 靠它判断新旧，发出去的版本号不能再用。

## 什么时候发版

- 每项改动单独提交，并在 CHANGELOG 的「## 未发布」里加一条用户能看懂的说明；多项攒成一批再发。
- 线上版本有影响使用的 bug 时例外：修好就单独发。
- 门禁（`bump_version.sh` 自动跑）：单元测试全部通过；Release 构建成功且**零编译警告**。
  另外，这一批改动要在真实的 Switch（DBI「从 DBIbackend 安装游戏」）上验证过，没法实机验证的在 CHANGELOG 里注明。

## 发版步骤

```bash
scripts/bump_version.sh --push
```

1. `bump_version.sh`：检查工作区干净且在 main → 门禁 → 版本号最后一位 +1 → CHANGELOG「未发布」改成 `## 0.1.N — 日期` → 提交 `release: 0.1.N` → 打 tag → 推送；
2. `publish.sh`：`release.sh`（archive → Developer ID 导出 → 自检 → 公证 → staple → `DBIBackend-<版本>.zip`）→ 从钥匙串导出 Sparkle 私钥到临时目录 → `make_appcast.sh` 签名并生成 `appcast.xml` → 删掉私钥 → `gh release create`。

失败时修好原因，单独重跑 `scripts/publish.sh`（已公证的包会被复用）。`SKIP_NOTARIZE=1 scripts/release.sh` 只检查构建和签名，这样的包不能发布。

已安装的 DBI Backend 每天检查一次 `releases/latest/download/appcast.xml`，也可以从 App 菜单 ▸ 检查更新… 手动检查。
Sparkle 不支持降级：有问题的版本往前修，发下一个修订版。

## 一次性设置（和 Pier 共用）

- `gh` 已登录；仓库 `lixiaolin94/DBIBackend` 公开（Sparkle 匿名下载 Release 资源）。
- 登录钥匙串里的 Developer ID Application 证书、Sparkle EdDSA 私钥（与 Inbox、Pier 共用一把）。
- notarytool 钥匙串 profile `inbox-notary`（账号级凭据，见 Pier 的 docs/RELEASE.md）。
