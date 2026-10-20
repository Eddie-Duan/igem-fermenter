# 智能发酵罐固件：真实传感器与手机 BLE 适配版

Arduino IDE 打开 **[esp32-s3/main/main.ino](esp32-s3/main/main.ino)**，保留整个 `main` 文件夹及其中的 `src`。应用入口留在草图根目录；配置、共享状态和 BLE、控制、MQTT、Wi-Fi 网络、传感器等实现按功能存放在 `main/src/` 下。此版本把原发酵罐的真实采集、标定、温控、网页、MQTT 模块与本项目 Flutter App 的 BLE 协议连接起来。

- [接线、烧录与 App 连接步骤](esp32-s3/README.md)
- [软件思路、协议映射和边界](esp32-s3/APP_INTEGRATION.md)

本次替换仅涉及 `firmware`；`mobile_app` 继续使用现有代码。新固件不使用旧示例的模拟/默认传感器系数，不把 GPIO5 分配给搅拌。
