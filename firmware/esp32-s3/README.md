# ESP32-S3 固件示例

发酵罐主控：采样温度 / pH / 浊度（OD600）/ 电池电压，写进自身 flash 日志，
通过 BLE 让手机 App 把历史记录拉走，并接受 App 下发的搅拌与加热控制。

协议的唯一来源是 [`docs/ble-gatt.md`](../../docs/ble-gatt.md) 与
[`docs/ble-data-format.md`](../../docs/ble-data-format.md)，字节级常量落在
[`components/protocol/protocol.h`](components/protocol/protocol.h)。三处必须一致。

## 目录

```text
main/main.ino                       setup/loop：采样节奏、串口调试
components/protocol/protocol.h      UUID、记录格式、指令、CRC（唯一字节级定义）
components/time/time.ino            时钟：SET_TIME 校准 + NVS 持久化
components/flash/flash.ino          追加式日志、NVS 游标、按 COMMIT 回收
components/sensors/sensors.ino      DS18B20 / PH-4502C / TSL2591 / 电池
components/control/control.ino      搅拌 PWM + 加热滞环
components/ble/ble.ino              GATT Server、指令解析、ACK 节奏的同步状态机
```

`.ino` 之间靠 `#include` 拼接（Arduino 只给主 sketch 生成函数原型，
所以每个文件顶部都有一份 `对外接口前置声明`；改函数签名时记得一起改）。

## 接线

| 功能 | ESP32-S3 引脚 | 说明 |
|---|---|---|
| DS18B20 温度 | GPIO4 | 数据线，4.7 kΩ 上拉到 3V3 |
| PH-4502C | GPIO1 (ADC1_CH0) | 变送器 `Po` 输出，**不要超过 3.1 V** |
| 电池电压 | GPIO2 (ADC1_CH1) | 分压中点，`BATTERY_DIVIDER` 按实际电阻改 |
| 搅拌电机 | GPIO5 | MOSFET 栅极，20 kHz PWM |
| 加热片 | GPIO6 | 固态继电器控制脚（HIGH = 加热） |
| TSL2591 | GPIO8 = SDA, GPIO9 = SCL | I2C 地址 0x29 |

避开 GPIO0/3/45/46（strapping）与 GPIO19/20（USB）——那几个脚上电或插 USB 时会闹脾气。

## 构建与烧录

代码按 **Arduino IDE + ESP32 core 3.x** 写（`ledcAttach`、`ESP_MAC_BT` 都是 3.x 的 API）。

1. Arduino IDE → 开发板管理器安装 `esp32`（≥ 3.0）。
2. 库管理器安装：`DallasTemperature`、`OneWire`、`Adafruit TSL2591`。
3. 板子选 **ESP32S3 Dev Module**；`USB CDC On Boot` 打开，否则串口没输出。
4. 整个 `esp32-s3/` 目录就是 sketch（主文件 `main/main.ino` 需保持这个名字，
   用 Arduino IDE 打开 `main/main.ino` 后把 sketch 目录指到 `main/`，
   或直接 `arduino-cli compile --fqbn esp32:esp32:esp32s3 main`）。

分区表用默认的 `Default 4MB with spiffs` 即可 —— SPIFFS 要留出放日志的空间
（2000 条 × 20 B ≈ 40 KB，32 KB 的默认 SPIFFS 分区偏小）。

若改用 ESP-IDF（`idf.py set-target esp32s3 && idf.py build`），需要把
Arduino 作为 component 引入，并把 `.ino` 改成 `.cpp` + 补 `#include <Arduino.h>`；
协议层（`protocol.h`）与逻辑都不用动。

## 标定（务必先做，示例系数不可直接用）

- **pH**：用 pH 7.00 与 pH 4.00 缓冲液各测一次 `analogReadMilliVolts(PIN_PH)`，
  把 7.00 那个值填进 `PH_MV_AT_7`，斜率填 `PH_MV_PER_PH`（默认按 25 °C 理论值 59.16 mV/pH）。
- **OD600**：装空白培养基记下 `getLuminosity(TSL2591_FULLSPECTRUM)` 当 `OD_BLANK_RAW`；
  用已知 OD 的样品核对 `OD_K`。光路（LED 与光电二极管间距、遮挡）一变就要重标。
- **电池**：确认分压电阻比与 `BATTERY_DIVIDER` 一致。

## 协议与 App 的对应关系

| 固件位置 | 协议 | App 侧 |
|---|---|---|
| `protocol.h` 的 `recordEncode` | 20 字节记录 + CRC-16/CCITT | `ble_protocol.dart` 的 `BleReadingRecord` |
| `ble.ino` 的 `ControlCallbacks::onWrite` | `SYNC_REQ` / `ACK` / `SET_TIME` / `COMMIT` / `SET_CONTROL` | `BleFrames` |
| `ble.ino` 的 `notifyStatus` | `SYNC_END` / `ERROR` / `LOG_STATUS` | `BleStatusMessage` |
| `flash.ino` 的 `flashReclaim` | 只有 ACK 过的记录才回收 | `BleSyncService` 的游标与 `COMMIT` |
| `protocol.h` 的 `SAMPLE_INTERVAL_S` | 采样周期 | `FermenterController.deviceSampleIntervalSeconds` |

改任意一处都要同步另一处，并跑一遍 App 侧的单测
（`cd ../../mobile_app && flutter test test/ble_protocol_test.dart test/ble_sync_service_test.dart`）。

## 用 nRF Connect 验一下（不用写 App）

1. 连接 `Fermenter-ESP32S3`，展开服务 `4fafc201-…`。
2. 读 `0000a101-…`：应当看到固件版本 1.0.0、MAC、电池 mV、日志容量。
3. 订阅 `0000a104-…`（SyncStatus），把指令写给 `0000a103-…`：
   - `03` + 4 字节 Unix 秒（小端）→ 串口打印校准后的时间；
   - `01` + `00000000` → 手机侧会开始逐条收到 20 字节记录，每条的
     `seq` 在第 3–6 字节；记录之间设备在等 `02` + seq 的 ACK，
     不发 ACK 就会在 5 秒后收到 `81` + next_seq（SYNC_END）；
   - `04` + 已确认的最大 seq → 串口打印回收了几条。
4. 想在两分钟采样周期之外补数据，串口输入 `n` 立刻采一条。

## 已知边界

- 日志元数据（`oldest`/`next`）每次追加都写 NVS。掉电时文件与元数据对不上会自动按
  文件重推；文件本身损坏（断档、坏块）时整段清空、序号接着往后走——App 侧只会少一段
  设备历史，不会出现序号错位。
- 没有做 MTU 协商：一次 Notify 正好 20 字节，依赖默认 MTU 23。要传更大帧得先加
  `BLEDevice::setMTU()` 与 App 侧协商。
- 温度控制是滞环通断，不是 PID。接口（`controlApply`/`controlTick`）保持不变就能替换。
