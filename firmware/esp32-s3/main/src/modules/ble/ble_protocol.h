// BLE v1 wire definitions matching mobile_app/lib/ble/ble_protocol.dart.
// Integration notes: ../APP_INTEGRATION.md. Keep UUIDs and frame layout stable.
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>

// ===================== 服务与特征 UUID =====================
#define BLE_SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define BLE_CHAR_DEVICE_INFO "0000a101-0000-1000-8000-00805f9b34fb"  // Read
#define BLE_CHAR_SENSOR_DATA "0000a102-0000-1000-8000-00805f9b34fb"  // Notify
#define BLE_CHAR_SYNC_CONTROL "0000a103-0000-1000-8000-00805f9b34fb" // Write With Response
#define BLE_CHAR_SYNC_STATUS "0000a104-0000-1000-8000-00805f9b34fb"  // Notify

// 广播名：App 靠服务 UUID 过滤，名字只是给人看的。
#define BLE_DEVICE_NAME "Fermenter-ESP32S3"

// ===================== 记录格式 =====================
// 一条记录正好一次 Notify（默认 ATT MTU 23 → 载荷 20 字节）。
#define RECORD_SIZE 20
#define RECORD_MAGIC 0xA5
#define RECORD_VERSION 0x01

// BLE 记录周期（秒）；本地传感器仍每5秒采样。App时间轴按seq × 此值换算，
// 改这里必须同时改 mobile_app/lib/services/fermenter_controller.dart
// 的 deviceSampleIntervalSeconds。
#define SAMPLE_INTERVAL_S 120

// flash 上最多保留多少条记录（20 B/条 → 2000 条约 40 KB）。
#define LOG_CAPACITY 2000

// 固件版本1.1.0；DeviceInfo首个u32，记录格式仍为v1。
#define FIRMWARE_VERSION 0x00010100u

// ===================== 手机 → 设备（SyncControl）=====================
#define CMD_SYNC_REQ 0x01  // 0x01 + next_seq(u32)：从 next_seq 开始（含）回发
#define CMD_ACK 0x02       // 0x02 + seq(u32)：该条已校验并落库
#define CMD_SET_TIME 0x03  // 0x03 + timestamp(u32)：Unix 秒
#define CMD_COMMIT 0x04    // 0x04 + last_seq(u32)：回收该序号及以前
#define CMD_SET_CONTROL 0x10 // 0x10 + flags(u8) + rpm(u16) + target_c_x10(u16)

// SET_CONTROL 的 flags 位。
#define CTRL_FLAG_STIRRER 0x01
#define CTRL_FLAG_HEATER 0x02

// ===================== 设备 → 手机（SyncStatus）=====================
#define ST_SYNC_END 0x81   // 0x81 + next_seq(u32)
#define ST_ERROR 0x82      // 0x82 + code(u8)
#define ST_LOG_STATUS 0x84 // 0x84 + oldest_seq(u32) + count(u32)

#define ERR_INVALID_ARG 0x01
#define ERR_BAD_FRAME 0x02
#define ERR_FLASH_FAILURE 0x03
#define ERR_BAD_SEQUENCE 0x04

// ===================== 小端读写 =====================
static inline uint16_t rdU16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static inline uint32_t rdU32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline void wrU16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)(v >> 8);
}

static inline void wrU32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

// ===================== CRC-16/CCITT-FALSE =====================
// 多项式 0x1021、初值 0xFFFF、不反转不异或。
// 自检："123456789" → 0x29B1（App 侧单测锁死了同一个值）。
static inline uint16_t crc16Ccitt(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++)
    {
        crc ^= (uint16_t)data[i] << 8;
        for (int bit = 0; bit < 8; bit++)
        {
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021)
                                 : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

// ===================== 记录结构 =====================
struct LogRecord
{
    uint32_t seq;       // 设备内单调递增，从 0 开始
    uint32_t timestamp; // Unix 秒；未校时写 0
    int16_t tempC_x100; // 温度 ×100
    int16_t ph_x100;    // pH ×100
    int16_t od_x1000;   // 相对光衰减 ×1000（兼容 App od 字段，负值按 0 处理）
    uint16_t batteryMv; // 电池电压 mV
};

// ---- 字段 → 20 字节帧（含 CRC）----
static inline void recordEncode(const LogRecord &r, uint8_t *out)
{
    out[0] = RECORD_MAGIC;
    out[1] = RECORD_VERSION;
    wrU32(out + 2, r.seq);
    wrU32(out + 6, r.timestamp);
    wrU16(out + 10, (uint16_t)r.tempC_x100);
    wrU16(out + 12, (uint16_t)r.ph_x100);
    wrU16(out + 14, (uint16_t)r.od_x1000);
    wrU16(out + 16, r.batteryMv);
    wrU16(out + 18, crc16Ccitt(out, RECORD_SIZE - 2));
}

// ---- 20 字节帧 → 字段；长度/magic/版本/CRC 任何一项不对就返回 false ----
static inline bool recordDecode(const uint8_t *in, LogRecord &r)
{
    if (in[0] != RECORD_MAGIC || in[1] != RECORD_VERSION)
        return false;
    if (rdU16(in + 18) != crc16Ccitt(in, RECORD_SIZE - 2))
        return false;
    r.seq = rdU32(in + 2);
    r.timestamp = rdU32(in + 6);
    r.tempC_x100 = (int16_t)rdU16(in + 10);
    r.ph_x100 = (int16_t)rdU16(in + 12);
    r.od_x1000 = (int16_t)rdU16(in + 14);
    r.batteryMv = rdU16(in + 16);
    return true;
}

// 传感器抽风时宁可饱和，也不要让定点值回绕（-300 °C 这种读数比没读数更糟）。
static inline int16_t clampToInt16(float value, float scale)
{
    float scaled = value * scale;
    if (scaled > 32767.0f)
        return 32767;
    if (scaled < -32768.0f)
        return -32768;
    return (int16_t)(scaled >= 0 ? scaled + 0.5f : scaled - 0.5f);
}

static inline uint16_t clampToUint16(float value)
{
    if (value < 0.0f)
        return 0;
    if (value > 65535.0f)
        return 65535;
    return (uint16_t)(value + 0.5f);
}

// 由物理量填一条记录（时间戳由调用方补，通常是 time.ino 的 nowUnix()）。
static inline LogRecord makeRecord(uint32_t seq, uint32_t timestamp,
                                   float tempC, float ph, float od,
                                   uint16_t batteryMv)
{
    LogRecord r;
    r.seq = seq;
    r.timestamp = timestamp;
    r.tempC_x100 = clampToInt16(tempC, 100.0f);
    r.ph_x100 = clampToInt16(ph, 100.0f);
    r.od_x1000 = clampToInt16(od < 0 ? 0 : od, 1000.0f);
    r.batteryMv = batteryMv;
    return r;
}
