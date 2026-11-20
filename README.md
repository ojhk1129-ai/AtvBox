# AtvBox

免费开源的 iPhone 工具：手机通过 ADB（WiFi）连接安卓电视 / 电视盒子（比如天猫魔盒），安装 APK、管理应用、截图。

功能和 iOS 上的 atvTools 差不多，但完全免费、代码公开：

- 扫描局域网，找出开了 ADB 调试的电视和盒子
- 手动输入 IP 连接（比如 `192.168.10.14`）
- 记住上次连过的设备
- 选 APK 文件上传安装到盒子上
- 查看盒子里已装的应用，打开、卸载
- 电视截图保存到相册
- 重启盒子

## 用之前：盒子要做的事

1. 盒子 → 设置 → 关于本机 → 连续点击“版本号”七次，开启开发者选项。
2. 设置 → 开发者选项 → 打开“USB 调试”（ADB 调试）。
3. 盒子 → 设置 → 网络，记下盒子的 IP 地址。
4. 手机和盒子连同一个 WiFi。

第一次连接时，电视上会弹出“允许 USB 调试吗？”的窗口，在电视上点“允许”。之后再连就不用点了。

## 怎么编译（用 GitHub Actions，不用 Mac）

1. 把这个仓库传到 GitHub（新建一个仓库，把这些文件推上去）。
2. 打开仓库的 **Actions** 标签页，等 `Build iOS App` 跑完。
3. 跑完后在页面下方 **Artifacts** 里下载 `AtvBox-unsigned-ipa`，得到 `AtvBox-unsigned.ipa`。

## 怎么免费装到 iPhone 上

编出来的 IPA 是**未签名**的，不能直接装，需要用你的免费 Apple ID 重新签名。有两个常用办法：

### 办法一：AltStore（推荐）

1. 电脑上装 [AltStore](https://altstore.io/)（Windows 或 Mac 都可以），手机上装 AltStore。
2. 把 `AtvBox-unsigned.ipa` 传到手机（微信发给自己、AirDrop、网盘都行）。
3. 在手机上用 AltStore 打开这个 IPA，输入你的 Apple ID 和密码（只用来签名，不会上传到别处），装好就能用。
4. 免费账号签名的 App 每 7 天要刷新一次，AltStore 会在同一 WiFi 下自动帮你续。

### 办法二：SideStore

和 AltStore 类似，但不需要电脑常开，适合不想总开电脑的人。见 [SideStore 官网](https://sidestore.io/)。

### 有 Mac 的话

在 Mac 上装 Xcode，打开项目（`xcodegen generate` 生成 `AtvBox.xcodeproj` 后打开），把 `PRODUCT_BUNDLE_IDENTIFIER` 改成你自己的（比如 `com.你的名字.atvbox`），选你的 Apple ID 做签名，直接点运行装到手机上。

## 在自己电脑上编译

需要一台 Mac + Xcode：

```bash
brew install xcodegen
xcodegen generate
open AtvBox.xcodeproj
```

## 文件说明

```
AtvBox/
  AtvBoxApp.swift            App 入口
  Models/DeviceStore.swift   已保存的设备（UserDefaults）
  ADB/
    ADBProtocol.swift        ADB 消息格式、常量
    ADBKey.swift             RSA 密钥（钥匙串）、签名、公钥格式
    ADBConnection.swift      ADB 客户端：握手、shell、传文件、装应用
    DeviceScanner.swift      扫描局域网找盒子
  Views/
    DeviceListView.swift     设备列表（照着 atvTools 的样子）
    DeviceDetailView.swift   设备详情：装 APK、应用列表、截图、重启
project.yml                  xcodegen 配置
.github/workflows/ios.yml    GitHub Actions 编译流程
```

## 常见问题

**搜不到设备？**
- 手机和盒子要在同一个 WiFi 下。
- 盒子要开 ADB 调试（上面“用之前”那几步）。
- 有些路由器开了“AP 隔离”会挡住局域网互访，关掉再试。
- 也可以点“手动输入 IP 连接”，直接填盒子的 IP。

**连不上，提示等授权？**
- 第一次连要在电视上点“允许 USB 调试”。电视上没弹出窗口的话，重启一下盒子再连。

**装 APK 失败？**
- APK 要和盒子的芯片架构匹配（大多数盒子是 arm64）。
- 有些盒子装应用要先在盒子设置里允许“未知来源应用安装”。
- 安装时手机不要锁屏、不要切走，等装完。

**和 atvTools 比少了什么？**
- atvTools 有遥控器、文件管理、应用图标等更多功能。AtvBox 只做最核心的：连设备、装 APK、管应用、截图。以后可以慢慢加。

## 诚实说明

这份代码**没有在真机上编译和实测过**（作者这边没有 Mac，也连不上你的盒子）。如果你编译时报错、或者连不上盒子、装不上 APK，请把报错截图或文字发回来，我会修。
