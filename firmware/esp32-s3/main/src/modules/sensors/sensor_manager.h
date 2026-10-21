#pragma once

namespace Sensors {
void begin();
void sample();
void loop();
bool requestBlankCalibration();
void resetBlankCalibration();
}

