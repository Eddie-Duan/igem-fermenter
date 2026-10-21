#pragma once
#include <Arduino.h>
#include "./record_format.h"

/// flash 上的定长传感器日志（A/B 双文件，按序号回收）。
/// App 通过 /api/readings 读取，落库后调用 /api/readings/commit。
namespace LogStore {
bool begin();
bool format();
bool ready();
uint32_t oldest();
uint32_t next();
uint32_t count();
bool read(uint32_t seq, uint8_t *frame);
/// 直接读出结构体（HTTP 层用）。
bool read(uint32_t seq, LogRecord &record);
bool append(float temperature, float ph, float od, uint32_t timestamp, uint32_t &seq);
bool reclaim(uint32_t lastSeq);
}
