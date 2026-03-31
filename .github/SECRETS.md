# GitHub Actions Secrets 配置指南

在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 中添加以下 Secrets：

## 必填（构建签名 + TestFlight 发布）

| Secret 名称 | 说明 | 如何获取 |
|---|---|---|
| `BUILD_CERTIFICATE_BASE64` | iOS 发布证书（.p12）的 Base64 编码 | Keychain Access → 导出 .p12 → `base64 -i cert.p12` |
| `P12_PASSWORD` | .p12 文件的密码 | 导出时设置的密码 |
| `KEYCHAIN_PASSWORD` | CI 临时 Keychain 密码 | 任意字符串，如 `ci-keychain-pass` |
| `PROVISIONING_PROFILE_BASE64` | iPhone App 的 Provisioning Profile Base64 | Apple Developer → Profiles → 下载 → `base64 -i xxx.mobileprovision` |
| `WATCH_PROVISIONING_PROFILE_BASE64` | Watch Extension 的 Provisioning Profile Base64 | 同上，选 Watch App Extension 类型 |
| `DEVELOPMENT_TEAM` | Apple 开发者 Team ID | Apple Developer → Membership → Team ID（10位字母数字） |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API Key ID | App Store Connect → Users → Integrations → Keys |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect Issuer ID | 同上页面顶部 |
| `APP_STORE_CONNECT_KEY_BASE64` | API Key .p8 文件 Base64 | 下载 .p8 → `base64 -i AuthKey_xxx.p8` |

## 快速生成 Base64 命令

```bash
# 证书
base64 -i ~/Downloads/Certificates.p12 | pbcopy

# Provisioning Profile
base64 -i ~/Downloads/App_Distribution.mobileprovision | pbcopy

# App Store Connect Key
base64 -i ~/Downloads/AuthKey_XXXXXXXX.p8 | pbcopy
```

## 工作流说明

| 触发条件 | 执行的 Job |
|---|---|
| PR 到 main | `build`（编译验证，不签名） |
| push 到 main | `build` + `release`（签名 + 打包 + TestFlight） |
| 手动触发 | `build` + `release` |
