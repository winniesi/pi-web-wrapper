# Pi Web Wrapper

一个约 300 行的 Swift 原生壳，替代 Safari「添加到程序坞」生成的 Web App，
实现「打开 app 自动启动 pi-web 服务，关闭 app 自动停止服务」。

适用于 [pi-web](https://github.com/agegr/pi-web)（pi coding agent 的 Web UI）。

## 行为

- 启动时检测 `http://127.0.0.1:30141`：
  - 服务未运行 → 后台拉起 `pi-web --no-open`（日志写入
    `~/Library/Application Support/PiWebWrapper/pi-web.log`），等端口就绪后加载页面
  - 服务已在运行 → 直接复用，不重复启动
- 退出（关窗 / Cmd+Q）时：只杀「自己拉起的」pi-web 进程；
  终端手动启动的服务不受影响
- 崩溃残留的服务（有 pid 文件）会在下次启动时被接管，退出时正常回收
- 站外链接（非 127.0.0.1/localhost）交给默认浏览器打开

## 构建前提

- macOS 14+
- Xcode Command Line Tools（`xcode-select --install`，用于 `swiftc`）
- 已通过 npm 全局安装 pi-web：`npm install -g @agegr/pi-web`

## 构建

```
./build.sh
```

产物安装到 `~/Applications/Pi Web.app`。如果你之前用 Safari 生成过同名的
Web App，建议先改名备份再执行。

## 升级 pi-web 是否需要重新编译？

不需要。壳只依赖固定路径 `/opt/homebrew/bin/pi-web` 和默认端口 30141，
`npm update -g @agegr/pi-web` 后照常工作。只有 pi-web 更换默认端口、
或要改壳自身行为时才需要 `./build.sh` 重编（约几秒）。

## 说明

- 图标 `ApplicationIcon.icns` 取自 @agegr/pi-web（MIT License）
- pi-web 与 pi 的路径 / 端口写死在 `main.swift` 顶部常量，可按需修改
