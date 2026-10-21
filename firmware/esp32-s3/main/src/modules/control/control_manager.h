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
}

