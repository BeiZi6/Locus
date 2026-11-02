# Locus

把地图上的坐标写到自己的手机。iOS 使用系统开发者定位服务，Android 使用 adb 的测试定位。

## 下载

在 [Releases](https://github.com/BeiZi6/Locus/releases) 下载 `Locus-*-macOS-arm64.zip`（Apple 芯片，macOS 14+）。app 未经 Apple 签名，首次打开前执行一次 `xattr -cr /Applications/Locus.app`。

## 自行构建

```sh
scripts/build-app.sh
open dist/Locus.app
```

iOS 17 及以上需要开发者模式，并用数据线连接后信任这台 Mac。Android 需要已启动的 adb，并允许模拟位置。
