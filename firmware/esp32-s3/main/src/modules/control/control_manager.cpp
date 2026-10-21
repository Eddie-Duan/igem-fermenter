#include <Arduino.h>
#include <Preferences.h>
#include <math.h>
#include "../../shared/app_state.h"
#include "../../config/fermenter_config.h"
#include "./control_manager.h"
#include "../../shared/sensor_math.h"

namespace {
Preferences preferences;
float smoothBuffer[Config::OD_SMOOTH_WINDOW] = {};
uint8_t smoothIndex = 0, smoothSize = 0;
float trendBuffer[Config::OD_WINDOW] = {};
uint8_t trendIndex = 0, trendSize = 0;
uint8_t fallingSamples = 0;

bool stirrerReady = false;
bool stirrerRequested = false;
uint16_t stirrerRequestedRpm = 0;

void setOutput(uint8_t pin, bool on, bool activeHigh) {
  digitalWrite(pin, (on == activeHigh) ? HIGH : LOW);
}

void setHeater(bool on) {
  gState.heaterOn = on;
  setOutput(Pins::HEATER_RELAY, on, Config::RELAY_ACTIVE_HIGH);
}

void updateAlarmOutput() {
  setOutput(Pins::BUZZER, gState.lysisAlarm, Config::BUZZER_ACTIVE_HIGH);
}

void resetTrend() {
  smoothIndex = smoothSize = 0;
  trendIndex = trendSize = 0;
  fallingSamples = 0;
  gState.odProxy = NAN;
  gState.slopePerMin = NAN;
}

void addTrendValue(float value) {
  smoothBuffer[smoothIndex] = value;
  smoothIndex = (smoothIndex + 1) % Config::OD_SMOOTH_WINDOW;
  if (smoothSize < Config::OD_SMOOTH_WINDOW) ++smoothSize;
  float smooth = 0.0f;
  for (uint8_t i = 0; i < smoothSize; ++i) smooth += smoothBuffer[i];
  smooth /= smoothSize;
  trendBuffer[trendIndex] = smooth;
  trendIndex = (trendIndex + 1) % Config::OD_WINDOW;
  if (trendSize < Config::OD_WINDOW) ++trendSize;
}

float slopePerMinute() {
  if (trendSize < Config::OD_WINDOW) return NAN;
  const float stepMin = Config::SAMPLE_PERIOD_MS / 60000.0f;
  float meanX = 0.0f, meanY = 0.0f;
  for (uint8_t i = 0; i < trendSize; ++i) {
    meanX += i * stepMin;
    meanY += trendBuffer[(trendIndex + i) % trendSize];
  }
  meanX /= trendSize;
  meanY /= trendSize;
  float numerator = 0.0f, denominator = 0.0f;
  for (uint8_t i = 0; i < trendSize; ++i) {
    const float x = i * stepMin - meanX;
    const float y = trendBuffer[(trendIndex + i) % trendSize] - meanY;
    numerator += x * y;
    denominator += x * x;
  }
  return denominator > 0.0f ? numerator / denominator : NAN;
}
}

namespace Controller {
void begin() {
  pinMode(Pins::HEATER_RELAY, OUTPUT);
  pinMode(Pins::BUZZER, OUTPUT);
  setHeater(false);
  gState.heaterEnabled = false; // require explicit arming after each reset
  gState.lysisAlarm = false;
  updateAlarmOutput();
  // 搅拌引脚可能和光学/传感器脚冲突，配置里用 static_assert 兜住了。
  if (Config::STIRRER_ENABLED) {
    pinMode(Config::STIRRER_PIN, OUTPUT);
    digitalWrite(Config::STIRRER_PIN, LOW);
    stirrerReady = ledcAttach(Config::STIRRER_PIN, Config::STIRRER_PWM_HZ,
                              Config::STIRRER_PWM_BITS);
    if (stirrerReady) ledcWrite(Config::STIRRER_PIN, 0);
    Serial.printf("# Stirrer PWM ready=%u (open loop, RPM is not measured)\n", stirrerReady);
  } else {
    Serial.println("# Stirrer disabled in fermenter_config.h; control requests are acknowledged but not driven");
  }
  preferences.begin("fermenter", false);
  gState.targetTempC = preferences.getFloat("target", Config::DEFAULT_TARGET_TEMP_C);
  if (!isfinite(gState.targetTempC) || gState.targetTempC < 5.0f ||
      gState.targetTempC >= Config::MAX_TEMP_C - Config::TEMP_HYSTERESIS_C)
    gState.targetTempC = Config::DEFAULT_TARGET_TEMP_C;
}

void updateTemperatureControl() {
  const bool staleTemperature = millis() - gState.lastTempSampleMs > Config::MAX_TEMP_SAMPLE_AGE_MS;
  if (!gState.heaterEnabled || !gState.tempValid || staleTemperature || gState.tempC >= Config::MAX_TEMP_C) {
    setHeater(false);
  } else if (!gState.heaterOn && gState.tempC <= gState.targetTempC - Config::TEMP_HYSTERESIS_C) {
    setHeater(true);
  } else if (gState.heaterOn && gState.tempC >= gState.targetTempC + Config::TEMP_HYSTERESIS_C) {
    setHeater(false);
  }

}

void update() {
  updateTemperatureControl();
  if (gState.calibrationRunning || !gState.opticalValid) {
    resetTrend();
    return;
  }
  gState.odProxy = SensorMath::relativeAbsorbance(gState.lightCounts, gState.blankCounts,
                                                Config::MIN_USABLE_LIGHT_COUNTS);
  if (!isfinite(gState.odProxy)) {
    resetTrend();
    return;
  }
  addTrendValue(gState.odProxy);
  gState.slopePerMin = slopePerMinute();
  if (isfinite(gState.slopePerMin) && gState.slopePerMin <= Config::LYSIS_SLOPE_THRESHOLD_PER_MIN) {
    if (fallingSamples < Config::REQUIRED_FALLING_SAMPLES) ++fallingSamples;
    if (fallingSamples >= Config::REQUIRED_FALLING_SAMPLES) gState.lysisAlarm = true;
  } else {
    fallingSamples = 0;
  }
  updateAlarmOutput();
}

bool setTargetTemperature(float value, String &error) {
  if (!isfinite(value) || value < 5.0f || value >= Config::MAX_TEMP_C - Config::TEMP_HYSTERESIS_C) {
    error = "目标温度须在 5°C 与软件过温上限之间";
    return false;
  }
  gState.targetTempC = value;
  preferences.putFloat("target", value);
  return true;
}

void setHeaterEnabled(bool enabled) {
  gState.heaterEnabled = enabled;
  updateTemperatureControl();
}

void resetOpticalTrend() { resetTrend(); }

void clearAlarm() {
  gState.lysisAlarm = false;
  resetTrend();
  updateAlarmOutput();
}

bool stirrerSupported() { return stirrerReady; }
bool stirrerOn() { return stirrerRequested && stirrerReady; }
uint16_t stirrerRpm() { return stirrerRequested ? stirrerRequestedRpm : 0; }

/// 开环 PWM：rpm 只用于线性映射占空比，不读取实际转速。
void setStirrer(bool enabled, uint16_t rpm) {
  stirrerRequested = enabled;
  stirrerRequestedRpm = enabled ? rpm : 0;
  if (!stirrerReady) return;
  uint32_t duty = 0;
  if (enabled) {
    const uint16_t clamped = constrain(rpm, Config::STIRRER_MIN_RPM, Config::STIRRER_MAX_RPM);
    duty = map(clamped, Config::STIRRER_MIN_RPM, Config::STIRRER_MAX_RPM,
               Config::STIRRER_MIN_DUTY, Config::STIRRER_MAX_DUTY);
  }
  ledcWrite(Config::STIRRER_PIN, duty);
}
}

