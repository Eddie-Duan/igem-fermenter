#pragma once
#include <Arduino.h>

namespace Pins {
constexpr uint8_t PH_ANALOG = 1; // ADC1, pH AO through a 10k/10k divider
constexpr uint8_t ONE_WIRE = 4;
constexpr uint8_t I2C_SDA = 8;
constexpr uint8_t I2C_SCL = 9;
constexpr uint8_t OPTICAL_LED = 5; // GPIO drives a transistor/MOSFET only
constexpr uint8_t HEATER_RELAY = 6;
constexpr uint8_t BUZZER = 7;
}

namespace Config {
constexpr bool RELAY_ACTIVE_HIGH = true;
constexpr bool BUZZER_ACTIVE_HIGH = true;
constexpr bool LED_DRIVER_ACTIVE_HIGH = true;
constexpr float DEFAULT_TARGET_TEMP_C = 30.0f;
constexpr float TEMP_HYSTERESIS_C = 0.5f;
constexpr float MAX_TEMP_C = 40.0f;
constexpr uint32_t SAMPLE_PERIOD_MS = 5000;
// 记录到 flash 的周期：App 时间轴按 seq × 该值换算，改动需同步 App 的
// deviceSampleIntervalSeconds。
constexpr uint32_t RECORD_PERIOD_MS = 120000;
constexpr uint32_t MAX_TEMP_SAMPLE_AGE_MS = 15000;
constexpr float PH_DIVIDER_RATIO = 2.0f;
constexpr uint8_t PH_SAMPLES = 20;
constexpr uint8_t PH_TRIM_SAMPLES = 4;
constexpr uint16_t PH_SAMPLE_GAP_MS = 5;
constexpr float PH_ADC_MIN_MV = 20.0f;
constexpr float PH_ADC_MAX_MV = 2600.0f;
constexpr uint8_t OD_SMOOTH_WINDOW = 3;
constexpr uint8_t OD_WINDOW = 12;
constexpr uint8_t REQUIRED_FALLING_SAMPLES = 36;
constexpr float LYSIS_SLOPE_THRESHOLD_PER_MIN = -0.010f;
constexpr uint16_t TSL_INTEGRATION_MS = 100;
constexpr uint16_t TSL_SATURATION_COUNTS = TSL_INTEGRATION_MS == 100 ? 36863 : 65535;
constexpr uint8_t BLANK_CALIBRATION_SAMPLES = 10;
constexpr uint16_t LED_SETTLE_MS = 30;
constexpr uint8_t OPTICAL_AVERAGES = 3;
constexpr float MIN_USABLE_LIGHT_COUNTS = 30.0f;

// 搅拌：开环 PWM，rpm 只用于线性映射占空比，没有转速反馈。
// GPIO5 是光学 LED 驱动，绝不能复用；改引脚时必须避开传感器/执行器脚。
constexpr bool STIRRER_ENABLED = false;
constexpr uint8_t STIRRER_PIN = 10;
constexpr uint32_t STIRRER_PWM_HZ = 20000;
constexpr uint8_t STIRRER_PWM_BITS = 8;
constexpr uint16_t STIRRER_MIN_RPM = 100;
constexpr uint16_t STIRRER_MAX_RPM = 300;
constexpr uint8_t STIRRER_MIN_DUTY = 85;
constexpr uint8_t STIRRER_MAX_DUTY = 255;
static_assert(!STIRRER_ENABLED ||
                  (STIRRER_PIN != PH_ANALOG && STIRRER_PIN != ONE_WIRE &&
                   STIRRER_PIN != I2C_SDA && STIRRER_PIN != I2C_SCL &&
                   STIRRER_PIN != OPTICAL_LED && STIRRER_PIN != HEATER_RELAY &&
                   STIRRER_PIN != BUZZER),
              "Stirrer pin conflicts with sensor/actuator pins");

constexpr uint32_t MQTT_PUBLISH_PERIOD_MS = 5000;
constexpr uint32_t MQTT_COMMAND_MAX_AGE_SEC = 120;
}

