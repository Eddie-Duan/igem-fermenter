# ESP32-S3 真实传感器 + Wi-Fi 手机接口固件

## 1. 这个版本提供什么

DS18B20、模拟 pH 模块、LED + TSL2591 的真实采集；pH 两点标定、光学空白标定；
加热回差控制与过温检查；蜂鸣器趋势报警；本地 Wi-Fi 网页、可选 MQTT TLS；以及
供手机 App 同步历史记录、下发控制的 HTTP 接口。

**Arduino 入口是 `main/main.ino`。** 应用代码位于 `main/src/`，按应用调度、
配置、共享状态和日志/控制/MQTT/网络/传感器模块分目录组织；不再包含旧
`components/*.ino`，避免旧引脚和新模块同时运行。

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

你的 24V、48W 加热器额定电流约 2A，24V 电源经继电器 COM/NO 给加热器供电；
24V 不接入 ESP32 GPIO。控制模块低压供电与负载供电按模块规格分别连接。

## 3. 编译与烧录

1. 安装 Arduino IDE 与 **esp32 by Espressif Systems 3.3.8**。
2. 安装库：Adafruit TSL2591 Library 1.4.5、Adafruit Unified Sensor 1.1.15、
   Adafruit BusIO 1.17.4、DallasTemperature 4.0.x、OneWire 2.3.8、
   PubSubClient 2.8、ArduinoJson 6.21.6。保留 MQTT 源码，因此即使未配置
   Broker 仍需后两项。
3. 打开 `main/main.ino`，选择 ESP32S3 Dev Module。
4. 按实物选择 Flash 与 PSRAM。已配置的编译目标为 8MB Flash、`default_8MB`
   （8M with spiffs，3MB APP）、PSRAM Disabled。
5. 根据所用 USB 接口选择 CDC；UART 转串口桥为 Disabled，原生 USB 为 Enabled。
   串口波特率 115200。
6. 选择真实设备端口，编译上传。切勿把编译成功等同于实机验证。

SPIFFS、Wi-Fi、Preferences 来自 ESP32 开发板包，无需安装同名第三方库。
`main/platformio.ini` 作为配置参考保留；其默认 Espressif32 平台可能使用
Arduino 2.x，不能直接作为本次适配的构建入口。本版本请使用 Arduino IDE 和
ESP32 Arduino 3.3.8。

## 4. 首次启动和标定

1. 查看串口输出的设备热点、密码、网页地址。连接热点，在 `http://192.168.4.1`
   用 `admin` 登录。
2. 检查温度和继电器有效电平，保持自动加热关闭。
3. 如果串口显示 `Log filesystem unavailable`，在**自动加热禁用**时通过串口
   输入 `LOG_FORMAT`，首次建立 SPIFFS 日志文件系统。该指令会清空 SPIFFS，
   包括历史日志并把序号重置为 0；不会清空 NVS 中的 pH/空白/网络标定。
   已有历史时先同步导出，格式化后 App 使用新批次。
4. 用两种缓冲液完成 pH 标定（网页操作，或 `PHCAL 7.00`、`PHCAL 4.00`，
   以缓冲液标签为准）。
5. 装入空白培养基，执行网页“标定纯培养基空白”或串口 `CAL`，等待完成。
6. 保证温度、pH、相对光学衰减均有效。首条有效记录会进入日志，之后有效数据
   每 120 秒记录一条。串口与网页仍按约 5 秒采样更新。

日志记录只能表达数值，没有 null/无效标志。未完成标定或传感器异常时，固件
继续本地采样与温控，但暂缓生成新记录，串口会说明原因。

## 5. 手机 App 操作

1. 手机连上设备热点 `Fermenter-S3-XXXXXX`（地址 `192.168.4.1`），
   或者先在设备网页里填路由器 Wi-Fi，让手机和设备接入同一路由器。
2. 打开 App 的设备页，填写 IP、用户 `admin`、串口日志里的网页密码，点连接。
3. 创建真实实验批次，目标温度建议先设 30℃，**搅拌关闭**。App 可选到 42℃，
   本固件软件上限 40℃，拒绝目标 ≥39.5℃。
4. 选择批次执行同步。App 会先校时，再分页拉取历史并落库，最后通知设备回收。
5. 同步后设备继续按 120 秒写入新记录；再次点同步即可补齐。修改批次里的加热
   开关和目标温度会自动下发到固件。加热开关表示“启用自动温控”，不表示继电器
   持续吸合。
6. 想修改 pH/光学标定，请用网页或串口；App 还没有这类命令。

网络断开不影响采样和已启用的温控。可选搅拌输出在断开/新连接时归零，重新
连接同步后 App 会重新下发批次当前控制状态。

日志最多 2000 条，按 120 秒约可保存 66 小时 40 分钟有效记录。满后停止新增
历史，保留未确认数据；温控、网页、串口继续运行。请定期同步。

## 6. 配置与维护

- `main/src/config/fermenter_config.h`：引脚、5 秒采样、120 秒记录周期、
  回差与保护阈值、可选搅拌参数。
- `main/src/config/mqtt_config.h`：可选 MQTT，默认服务器和证书为空；App 不
  依赖 MQTT。
- `main/src/modules/network/network_manager.cpp`：网页与 `/api/*` 接口。
- `main/src/modules/log/log_store.cpp`：双文件日志、恢复与回收。

启用搅拌前，将 `STIRRER_ENABLED` 改为 `true`，确认独立驱动接线及 GPIO10
可用，再校准 PWM 占空比。当前 rpm 字段仅映射为开环 PWM，无转速传感器，
不能保证真实 100–300 rpm。默认禁用时请保持 App 搅拌关闭；请求开启会返回
参数错误或 warning。

原本地使用细节仍见 `main/docs/使用指南.md`；本次适配差异以此文和
[APP_INTEGRATION.md](APP_INTEGRATION.md) 为准。
