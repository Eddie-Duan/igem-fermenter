#pragma once
#include <Arduino.h>

namespace Controller {
void begin();
void update();
void updateTemperatureControl();
void resetOpticalTrend();
bool setTargetTemperature(float value, String &error);
void setHeaterEnabled(bool enabled);
void clearAlarm();

// 搅拌为开环 PWM 映射（不是转速闭环）。Config::STIRRER_ENABLED 为 false 时
// 这些函数只会记录请求值，不会驱动任何引脚。
void setStirrer(bool enabled, uint16_t rpm);
bool stirrerSupported();
bool stirrerOn();
uint16_t stirrerRpm();
}

