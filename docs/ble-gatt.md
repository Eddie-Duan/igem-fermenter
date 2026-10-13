# BLE GATT 接口（App ↔ ESP32-S3）

App 与发酵罐主控之间只有一条通路：**BLE**。设备把采样记录写在自身 flash 上，
App 连上后按序号把记录拉过来、校验、落进手机本地库，再回 ACK 允许设备回收空间。

> 本文件是 App 与固件共同的协议来源。改协议必须同时改三处：
> `mobile_app/lib/ble/`、`firmware/esp32-s3/`、本目录的文档。

## 角色

```text
ESP32-S3：BLE Peripheral / GATT Server（数据在 flash 里，只按请求吐记录）
手机 App：BLE Central / GATT Client（扫描、连接、拉取、落库、下发控制）
```

设备不断广播；App 主动扫描并连接。断开后设备继续采样写 flash，不做实时补偿。

## UUID

| 项目 | UUID | 属性 | 用途 |
|---|---|---|---|
| Service | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` | — | 发酵罐 BLE 服务 |
| `DeviceInfo` | `0000a101-0000-1000-8000-00805f9b34fb` | Read | 固件版本、MAC、电池电压、日志容量 |
| `SensorData` | `0000a102-0000-1000-8000-00805f9b34fb` | Notify | 一条 20 字节读数记录 |
| `SyncControl` | `0000a103-0000-1000-8000-00805f9b34fb` | Write With Response | 同步请求、ACK、COMMIT、校时、控制 |
| `SyncStatus` | `0000a104-0000-1000-8000-00805f9b34fb` | Notify | 同步结束、存储状态、错误码 |

所有整数一律**小端序**。默认 ATT MTU 23 → Notify 载荷上限 20 字节，
因此一条记录正好一次 Notify 发完（见 [`ble-data-format.md`](ble-data-format.md)）。

## 控制指令（App → SyncControl）

| 指令 | 首字节 | 格式 | 说明 |
|---|---:|---|---|
| `SYNC_REQ` | `0x01` | `0x01 + next_seq(uint32)` | 从 `next_seq` 开始（**含**）回发记录 |
| `ACK` | `0x02` | `0x02 + seq(uint32)` | 手机已校验并落库该条记录 |
| `SET_TIME` | `0x03` | `0x03 + timestamp(uint32)` | 用手机时间校准设备 Unix 时钟 |
| `COMMIT` | `0x04` | `0x04 + last_seq(uint32)` | 允许回收该序号及以前的记录 |
| `SET_CONTROL` | `0x10` | `0x10 + flags(uint8) + rpm(uint16) + target_c_x10(uint16)` | 搅拌与加热控制 |

`SYNC_REQ` 传的是**下一条想要的序号**（本地已落库的最大 `seq` + 1，空批次为 0），
设备判据是 `record.seq >= next_seq`。这样双方对"缺哪一条"的理解一致：重发语义天然幂等。

`SET_CONTROL` 的 `flags`：bit0 搅拌开、bit1 加热开（其余位保留，写 0）。
`rpm` 100–300，`target_c_x10` 是目标温度 ×10（如 37.0 °C → `370`）。

设备处理失败时通过 `SyncStatus` 回 `ERROR`（见下），而不是静默丢弃。

## 状态通知（Device → SyncStatus）

| 指令 | 首字节 | 格式 | 说明 |
|---|---:|---|---|
| `SYNC_END` | `0x81` | `0x81 + next_seq(uint32)` | flash 日志已发完，下一条待发的序号 |
| `ERROR` | `0x82` | `0x82 + code(uint8)` | 错误码 |
| `LOG_STATUS` | `0x84` | `0x84 + oldest_seq(uint32) + count(uint32)` | flash 里现存的最旧序号与条数 |

连接建立后（Notify 订阅完成）设备立刻推一帧 `LOG_STATUS`，手机据此在设备页显示
"设备上还有 N 条待同步"，不必等同步跑完。

错误码：`0x01` 参数非法、`0x02` CRC/长度不对、`0x03` flash 写失败、`0x04` 序号超出范围。

## 同步规则

```text
手机算出本地已落库的最大 seq，next_seq = 最大 seq + 1（空批次为 0）
    ↓  SET_TIME(now)                # 每次连接先校时
    ↓  SYNC_REQ(next_seq)
ESP32 从 flash 里取出 seq >= next_seq 的记录
    ↓  SensorData Notify 一条记录
手机：查长度/magic/version/CRC → 去重 → 写入 SQLite → 发 ACK(seq)
    ↓  设备只有收到 ACK 才把这条标记为可回收，然后发下一条
ESP32 发完最后一条 → SyncStatus Notify SYNC_END(next_seq)
    ↓
手机发送 COMMIT(已确认的最大 seq)  →  设备回收它及以前的记录
```

要点：

- **Notify 送达 ≠ 手机已存好**。必须有应用层 ACK，未 ACK 的记录设备不能删。
- 断开重连后：手机用自己库里该设备的最大 `seq` + 1 重新 `SYNC_REQ`，设备重发即可。
- 去重键是 `device_id + seq`（手机侧落库后即用 `seq` 判断）。
- **没有缺口才能回收**：手机的同步游标停在第一个没收到的序号上，
  `COMMIT` 只覆盖缺口之前的部分；否则设备会删掉手机其实没有的记录。
  一条都没确认落库时**不发** `COMMIT`（`0 - 1` 会回绕成 `0xFFFFFFFF`，等于让设备清空日志）。
- `peak` / `harvest` 这类判断全部在手机侧做，设备只负责采样、存储和回传。

## 采样与实时性

- 设备按固定周期（默认 120 s）采样一条，写入 flash 并立即 Notify 一次。
  手机侧的时间轴按 `seq × 120 s` 换算（见 `fermenter_controller.dart` 的
  `deviceSampleIntervalSeconds`），所以设备没校时也能画出正确的曲线。
- App 打开某个批次时：先同步 flash 里的历史，再把后续 Notify 当作实时曲线追加
  （同一条订阅，没有第二个流程）。
- **批次一旦绑定设备就不再回退到仿真**：设备掉线时该批次停止进点，等设备回来接着同步。
  未绑定设备的批次仍然由 [`SimulatedSensorSource`](../mobile_app/lib/services/simulated_sensor_source.dart) 驱动。
- 控制状态是双向的：手机改搅拌/加热/目标温度 → `SET_CONTROL`；设备只为记录附带电池电压。
- 批次与设备的绑定关系只存在内存里：App 重启后重新连接、重新同步即可（数据在设备 flash 上）。
