#pragma once
#include <Arduino.h>

namespace PhSensor {
void begin();
void sample();
bool captureCalibrationPoint(float referencePh, String &message);
bool resetCalibration(String &message);
}
