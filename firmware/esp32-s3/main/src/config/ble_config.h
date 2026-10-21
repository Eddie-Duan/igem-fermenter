#pragma once
#include <Arduino.h>

namespace BleConfig {
// Must match FermenterController.deviceSampleIntervalSeconds in the existing app.
constexpr uint32_t RECORD_PERIOD_MS = 120000;
constexpr uint32_t ACK_TIMEOUT_MS = 5000;
constexpr uint8_t MAX_RETRIES = 2;
// GPIO5 belongs to the optical LED. Never reuse it for the motor.
constexpr bool STIRRER_ENABLED = false;
constexpr uint8_t STIRRER_PIN = 10;
constexpr uint32_t STIRRER_PWM_HZ = 20000;
constexpr uint8_t STIRRER_PWM_BITS = 8;
// Open-loop duty mapping, NOT a measured RPM controller; calibrate on real hardware.
constexpr uint16_t STIRRER_MIN_RPM = 100;
constexpr uint16_t STIRRER_MAX_RPM = 300;
constexpr uint8_t STIRRER_MIN_DUTY = 85;
constexpr uint8_t STIRRER_MAX_DUTY = 255;
static_assert(!STIRRER_ENABLED || (STIRRER_PIN != 1 && STIRRER_PIN != 4 &&
    STIRRER_PIN != 5 && STIRRER_PIN != 6 && STIRRER_PIN != 7 &&
    STIRRER_PIN != 8 && STIRRER_PIN != 9), "Stirrer pin conflicts with sensor/actuator pins");
}
