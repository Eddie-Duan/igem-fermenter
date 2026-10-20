# Arduino 草图入口

在 Arduino IDE 打开本目录的 **main.ino**，并保留整个 src 子目录。

- [接线、烧录、标定、手机连接](../README.md)
- [软件思路与 BLE 对接架构](../APP_INTEGRATION.md)
- [本地网页、串口与传感器使用细节](docs/使用指南.md)

本草图包含真实温度、pH、光学采集，以及温控、报警、Wi-Fi、可选 MQTT 和 BLE。手机 App 的 Device 页面支持填写设备热点/路由器 IP 与网页密码，通过 Wi-Fi 查看实时状态、每 3 秒刷新，并下发温控；BLE 仍用于历史记录同步。设备热点地址为 `192.168.4.1`，首次启动的热点密码和网页登录密码会打印在串口。配置位于 `src/config/`，具体目录说明见下方。原发酵罐项目中的独立示例和本机测试未复制到本项目。

## 目录结构

```text
main.ino                 Arduino 草图入口
src/app/                 应用初始化与主循环
src/config/              引脚、采样、BLE 与 MQTT 配置
src/shared/              共享状态和传感器数学工具
src/modules/ble/         BLE 协议、连接与历史日志
src/modules/control/     温度控制与报警
src/modules/mqtt/        可选 MQTT 客户端
src/modules/network/     Wi-Fi、网页和 HTTP API
src/modules/sensors/     温度、pH 与光学传感器
docs/                    使用与架构文档
```

本版本使用 ESP32 Arduino 3.3.8 构建；旧 platformio.ini 仅保留为迁移参考，其默认平台可能使用不支持本版可选搅拌 API 的 Arduino 2.x。
