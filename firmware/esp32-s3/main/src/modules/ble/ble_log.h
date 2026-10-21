#pragma once
#include <Arduino.h>
#include "./ble_protocol.h"

namespace BleLog {
bool begin();
bool format();
bool ready();
uint32_t oldest();
uint32_t next();
uint32_t count();
bool read(uint32_t seq, uint8_t *frame);
bool append(float temperature, float ph, float od, uint32_t timestamp, uint32_t &seq);
bool reclaim(uint32_t lastSeq);
}
