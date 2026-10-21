# ESP32-S3 真实传感器 + Flutter App BLE 固件

## 1. 这个版本提供什么

DS18B20、模拟 pH 模块、LED + TSL2591 的真实采集；pH 两点标定、光学空白标定；加热回差控制与过温检查；蜂鸣器趋势报警；原有本地 Wi-Fi 网页和可选 MQTT TLS；新增 BLE 设备发现、手机校时、历史同步和加热控制。

**Arduino 入口是 `main/main.ino`。** 应用代码位于 `main/src/`，按应用调度、配置、共享状态和 BLE/控制/MQTT/网络/传感器模块分目录组织；不再包含旧 `components/*.ino`，避免旧引脚和新模块同时运行。

## 2. 接线

| 功能 | GPIO / 接法 |
|---|---|
| pH AO | GPIO1，AO 先经 10kΩ/10kΩ 分压，ADC 节点对地 100nF；调理板按说明供电 |
| DS18B20 | GPIO4；DATA 经 4.7kΩ 上拉到 3.3V |
| 光路 LED 驱动 | GPIO5，经过晶体管/MOSFET 与限流电路 |
| 加热继电器 | GPIO6，默认高电平触发；模块支持 3.3V 逻辑 |
| 蜂鸣器 | GPIO7，经合适驱动 |
| TSL2591 | SDA=GPIO8，SCL=GPIO9，I²C 上拉到 3.3V |
| 可选搅拌驱动 | 默认禁用；预留 GPIO10，不能复用 GPIO5 |

你的 24V、48W 加热器额定电流约 2A，24V 电源经继电器 COM/NO 给加热器供电；24V 不接入 ESP32 GPIO。控制模块低压供电与负载供电按模块规格分别连接。

## 3. 编译与烧录

1. 安装 Arduino IDE 与 **esp32 by Espressif Systems 3.3.8**。
2. 安装库：Adafruit TSL2591 Library 1.4.5、Adafruit Unified Sensor 1.1.15、Adafruit BusIO 1.17.4、DallasTemperature 4.0.x、OneWire 2.3.8、PubSubClient 2.8、ArduinoJson 6.21.6。保留 MQTT 源码，因此即使未配置 Broker 仍需后两项。
3. 打开 `main/main.ino`，选择 ESP32S3 Dev Module。
4. 按实物选择 Flash 与 PSRAM。已配置的编译目标为 8MB Flash、`default_8MB`（8M with spiffs，3MB APP）、PSRAM Disabled。BLE + Wi-Fi 固件应保留足够应用分区和 SPIFFS；普通 1.2MB 应用分区可能装不下。
5. 根据所用 USB 接口选择 CDC；UART 转串口桥为 Disabled，原生 USB 为 Enabled。串口波特率 115200。
6. 选择真实设备端口，编译上传。切勿把编译成功等同于实机验证。

BLE、SPIFFS、Wi-Fi、Preferences 来自 ESP32 开发板包，无需安装同名第三方库。原 `main/platformio.ini` 作为配置参考保留；其默认 Espressif32 平台可能使用 Arduino 2.x，不能直接作为本次适配的构建入口。本版本请使用 Arduino IDE 和 ESP32 Arduino 3.3.8。

## 4. 首次启动和标定

1. 查看串口输出的设备热点、密码、网页地址。连接热点，在 `http://192.168.4.1` 用 `admin` 登录。
2. 检查温度和继电器有效电平，保持自动加热关闭。
3. 如果串口显示 `BLE log filesystem unavailable`，在**蓝牙断开、自动加热禁用**时输入 `BLE_FORMAT`，首次建立 SPIFFS 日志文件系统。该指令会清空 SPIFFS，包括历史日志并把序号重置为 0；不会清空 NVS 中的 pH/空白/网络标定。已有历史时先同步导出，格式化后 App 使用新批次。
4. 用两种缓冲液完成 pH 标定（网页操作，或 `PHCAL 7.00`、`PHCAL 4.00`，以缓冲液标签为准）。
5. 装入空白培养基，执行网页“标定纯培养基空白”或串口 `CAL`，等待完成。
6. 保证温度、pH、相对光学衰减均有效。首条有效记录会进入 BLE 日志，之后有效数据每 120 秒记录一条。原串口与网页仍按约 5 秒采样更新。

现有 App 的 v1 数据帧只能表达数值，没有 null/无效标志。未完成标定或传感器异常时，固件继续本地采样与温控，但暂缓生成新的 BLE 记录，串口会说明原因。

## 5. 手机 App 操作

1. 打开本项目 App 的设备页面，允许蓝牙权限。
2. 扫描并连接 **Fermenter-ESP32S3**；选择真实设备，不选演示设备。
3. 创建真实实验批次，目标温度建议先设 30℃，**搅拌关闭**。现有 App 可选到 42℃，本固件保持原软件上限 40℃，拒绝目标 ≥39.5℃。
4. 选择批次执行同步。App 自动订阅通知并发送手机时间，按序接收历史、落库、ACK，完成后发送 COMMIT。
5. 同步后保持连接，新记录自动进入该批次；修改加热开关和目标温度会下发到固件。加热开关表示“启用自动温控”，不表示继电器持续吸合。
6. 想修改 pH/光学标定，请用网页或串口；现有 App BLE 协议尚无这类命令。

蓝牙断开不影响采样和已启用的温控。可选搅拌输出在断开/新连接时归零。重新连接同步后，App 会重新下发批次当前控制状态。

日志最多 2000 条，按 120 秒约可保存 66 小时 40 分钟有效记录。满后停止新增 BLE 历史，保留未确认数据；温控、网页、串口继续运行。请定期同步。同步超过 App 的 45 秒等待窗口时，已落库的记录保留，重新同步可从游标继续；只有成功同步并 COMMIT 后才回收。

## 6. 配置与维护

- `main/src/config/fermenter_config.h`：引脚、5 秒采样、回差和保护阈值。
- `main/src/config/ble_config.h`：120 秒记录周期、ACK 重试、可选搅拌引脚。
- `main/src/config/mqtt_config.h`：可选 MQTT，默认服务器和证书为空；App 不依赖 MQTT。
- `main/src/modules/ble/ble_manager.cpp`：BLE 连接、命令队列、记录与同步。
- `main/src/modules/ble/ble_log.cpp`：双文件日志、恢复、ACK 后回收。

启用搅拌前，将 `STIRRER_ENABLED` 改为 `true`，确认独立驱动接线及 GPIO10 可用，再校准 PWM 占空比。当前 rpm 字段仅映射为开环 PWM，无转速传感器，不能保证真实 100–300rpm。默认禁用时，请保持 App 搅拌关闭；请求开启会返回参数错误。

原本地使用细节仍见 `main/docs/使用指南.md`；本次适配差异以此文和 [APP_INTEGRATION.md](APP_INTEGRATION.md) 为准。
