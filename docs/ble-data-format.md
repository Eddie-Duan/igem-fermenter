# 记录数据格式

## 20 字节记录

一条读数正好占一次 Notify（默认 ATT MTU 23 → 载荷 20 字节），所有整数**小端序**：

| 字段 | 长度 | 类型 | 说明 |
|---|---:|---|---|
| `magic` | 1 | u8 | 固定 `0xA5` |
| `version` | 1 | u8 | 数据格式版本，当前 `0x01` |
| `seq` | 4 | u32 | 设备内递增序号，从 0 开始 |
| `timestamp` | 4 | u32 | Unix 秒；未校时时为 `0` |
| `temperature_c_x100` | 2 | i16 | 温度 ×100（24.35 °C → `2435`） |
| `ph_x100` | 2 | i16 | pH ×100（6.85 → `685`） |
| `od_x1000` | 2 | i16 | OD600 ×1000（1.255 → `1255`，上限 32.767） |
| `battery_mv` | 2 | u16 | 电池/供电电压，单位 mV |
| `crc16` | 2 | u16 | 对前 **18** 字节算 CRC-16/CCITT-FALSE |

字段顺序即字节顺序：`magic, version, seq(4), timestamp(4), temp(2), ph(2), od(2), battery(2), crc(2)`。

> pH / OD 用定点整数而不是 float：省 4 个字节，且避免两端浮点格式化不一致。
> App 侧解码后除以 100 / 1000 还原成 `SensorReading` 的 double 字段。

## 校验

- CRC 算法：**CRC-16/CCITT-FALSE** —— 多项式 `0x1021`，初值 `0xFFFF`，
  不反转输入输出，结果不异或。
- 参考值：`"123456789"` 的 CRC = `0x29B1`。
- 手机侧收到 Notify 后，先查长度 == 20、`magic` == `0xA5`、`version` == 当前版本，
  再校验 CRC；任何一项不过就**不回 ACK**，等设备重发。

## 去重与落库

- 主键语义是 `device_id + seq`。手机库里一个批次对应一台设备，因此实际用 `seq` 判重。
- 已存在的记录视为重复包：仍然回 ACK（设备可能只是没收到上一次 ACK），但不重复入库。
- `seq` 单调递增且不重用；设备只有在收到 `COMMIT` 之后才回收旧记录、之后从 `oldest_seq` 继续。

## 与 App 字段的对应

| 协议字段 | `SensorReading` 字段 |
|---|---|
| `seq` | `seq` |
| `timestamp` | `recordedAt`（未校时时退回手机当前时间） |
| `temperature_c_x100` | `temperatureC` |
| `ph_x100` | `ph` |
| `od_x1000` | `od` |
| — | `source` 固定为 `'ble'` |
| — | `simSeconds` 由 App 按 `timestamp - batch_start` 换算 |

`simSeconds` 不入包：它是 App 侧的实验时间轴，设备只提供绝对时间戳。
