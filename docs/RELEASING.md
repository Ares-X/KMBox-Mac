# 维护与发布

## 源码仓库

项目根目录应是 `KMBoxMac` 自己的 Git 根；不要把旁边的其他项目作为同一开源仓库提交。

```bash
git rev-parse --show-toplevel
git status --short
git remote -v
git ls-files
git diff --check
```

公开内容包含 `Sources/`、`Tests/`、`tools/`、`scripts/`、`Resources/`、公开文档和许可证。`.gitignore` 排除 `research/`、`artifacts/`、`dist/`、构建缓存及本机环境。它不会清理已经提交的历史，因此每次发布前仍应审阅暂存区及实际打包文件。

来源变更更新 `SOURCES.md` 与 `docs/sources.json`；版本变更更新 `Resources/Info.plist`、README 和 CHANGELOG。许可证只覆盖本项目有权授权的材料，不将厂商资料重新授权。

## GitHub 仓库

公开源码位于 [Ares-X/KMBox-Mac](https://github.com/Ares-X/KMBox-Mac)，二进制位于 [Releases](https://github.com/Ares-X/KMBox-Mac/releases)。本项目为**非官方版本**；README、应用“关于”与 Release 标题均应保留此标识。

首次克隆：

```bash
git clone git@github.com:Ares-X/KMBox-Mac.git
cd KMBox-Mac
git remote -v
git log -1 --oneline
```

初始默认分支为 `codex/open-source`。后续发布前确认远端默认分支、分支保护规则、工作区状态与已有标签；不要覆盖已有标签或强制推送。Release 标签应指向生成附件所用的干净源码提交。

## 验证与二进制

```bash
swift test
bash scripts/build-app.sh
python3 tools/verify_cli.py dist/kmctl
codesign --verify --deep --strict "dist/KMBox Mac.app"
```

应用资源包含 README、来源、许可证与公开 docs。构建脚本重建资源，避免旧版私有历史文档残留。先关闭正在运行的应用，再替换已有构建。

二进制、固件和研究下载不要加入源码提交。制作 Release 时使用本次干净源码的新构建，不要复用开源整理前的旧 ZIP：旧包可能携带旧版开发记录。

例如为一个已提交版本生成应用 ZIP 与校验文件（版本号应与 `Resources/Info.plist` 一致）：

```bash
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ditto -c -k --sequesterRsrc --keepParent "dist/KMBox Mac.app" "dist/KMBox-Mac-${version}-universal.zip"
(cd dist && shasum -a 256 "KMBox-Mac-${version}-universal.zip" kmctl > SHA256SUMS.txt)
```

Release 附件包含应用 ZIP、单独的 `kmctl` 与 `SHA256SUMS.txt`。检查 ZIP CRC、实际文件及随包许可；说明列出源码提交、系统要求、签名状态、已测试设备和未验证功能。这里的 ZIP 只有 App；不要暗示其中同时包含单独 CLI。直接下载 CLI 后，在终端执行 `chmod +x kmctl` 再使用。

当前构建为 ad-hoc 签名，没有 Developer ID 或公证。若将来增加正式签名，应通过维护者自己的证书和发布流程处理，不把证书、私钥或 Apple 凭据写入仓库。
