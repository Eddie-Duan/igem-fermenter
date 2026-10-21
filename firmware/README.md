# 智能发酵罐固件：真实传感器 + Wi-Fi 手机接口

Arduino IDE 打开 **[esp32-s3/main/main.ino](esp32-s3/main/main.ino)**，保留整个
`main` 文件夹及其中的 `src`。应用入口留在草图根目录；配置、共享状态和日志、
控制、MQTT、Wi-Fi 网络、传感器等实现按功能存放在 `main/src/` 下。

- [接线、烧录与手机连接步骤](esp32-s3/README.md)
- [软件思路、HTTP 接口与已知边界](esp32-s3/APP_INTEGRATION.md)

手机与设备通过局域网 HTTP 通信，不使用蓝牙。设备始终开着配置热点
`192.168.4.1`，密码见串口日志；也可以让它连上路由器后使用路由器地址。
