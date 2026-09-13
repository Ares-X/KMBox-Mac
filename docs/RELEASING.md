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

## 第一次发布到 GitHub

先在自己的 GitHub 账户创建一个**空仓库**，不额外生成 README/许可证；将真实仓库 URL 填入下面的占位值。不要在已有 origin 上盲目执行。

```bash
git remote add origin GITHUB_REPOSITORY_URL
git remote -v
git log -1 --oneline
git push -u origin HEAD
```

本地准备分支可以直接成为初始分支；是否采用 `main` 由仓库维护者决定。创建仓库和推送是独立的公开发布动作，本地初始化/提交不代表已经发布。本项目文档不预设一个尚不存在的 GitHub 仓库或 Release 下载地址。

## 验证与二进制

```bash
swift test
bash scripts/build-app.sh
python3 tools/verify_cli.py dist/kmctl
codesign --verify --deep --strict "dist/KMBox Mac.app"
```

应用资源包含 README、来源、许可证与公开 docs。构建脚本重建资源，避免旧版私有历史文档残留。先关闭正在运行的应用，再替换已有构建。

二进制、固件和研究下载不要加入源码提交。制作 Release 时使用本次干净源码的新构建，不要复用开源整理前的旧 ZIP：旧包可能携带旧版开发记录。

例如为一个已提交版本生成带提交号的应用 ZIP：

```bash
revision="$(git rev-parse --short HEAD)"
ditto -c -k --sequesterRsrc --keepParent "dist/KMBox Mac.app" "dist/KMBox-Mac-${revision}.zip"
shasum -a 256 "dist/KMBox-Mac-${revision}.zip"
```

CLI 可单独附上 `dist/kmctl` 和相应 SHA-256。检查 ZIP CRC、实际文件及随包许可；Release 说明列出系统要求、签名状态、已测试设备和未验证功能。这里的 ZIP 只有 App；不要暗示其中同时包含单独 CLI。

当前构建为 ad-hoc 签名，没有 Developer ID 或公证。若将来增加正式签名，应通过维护者自己的证书和发布流程处理，不把证书、私钥或 Apple 凭据写入仓库。
