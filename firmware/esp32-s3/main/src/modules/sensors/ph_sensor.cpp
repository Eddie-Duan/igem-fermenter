#include <Arduino.h>
#include <Preferences.h>
#include "../../shared/app_state.h"
#include "../../config/fermenter_config.h"
#include "./ph_sensor.h"
#include "../../shared/sensor_math.h"

namespace {
Preferences preferences;
SensorMath::PhCalibration calibration;
bool storageReady = false;
float firstModuleMv = NAN;

static_assert(Config::PH_SAMPLES > 2 * Config::PH_TRIM_SAMPLES,
              "pH filter must retain at least one sample");

void updatePhValue() {
  gState.phCalibrated = SensorMath::calibrationValid(calibration);
  gState.ph = gState.phVoltageValid
      ? SensorMath::phFromMillivolts(gState.phModuleMv, calibration) : NAN;
  gState.phValid = isfinite(gState.ph);
}
}

namespace PhSensor {
void begin() {
  pinMode(Pins::PH_ANALOG, INPUT);
  analogReadResolution(12);
  analogSetPinAttenuation(Pins::PH_ANALOG, ADC_11db);
  // Keep the standalone sketch's namespace/key so completed pH calibrations survive merging.
  storageReady = preferences.begin("ph-tsl-demo", false);
  if (storageReady && preferences.getBytesLength("ph-cal") == sizeof(calibration))
    preferences.getBytes("ph-cal", &calibration, sizeof(calibration));
  gState.phCalibrationPending = false;
  gState.phCalibrationReference = NAN;
  firstModuleMv = NAN;
  updatePhValue();
  Serial.printf("# pH: GPIO%u, divider=%.3f, calibration=%s\n", Pins::PH_ANALOG,
                Config::PH_DIVIDER_RATIO, gState.phCalibrated ? "loaded" : "missing");
  if (!storageReady) Serial.println("# ERROR: pH calibration storage unavailable");
}

void sample() {
  uint32_t readings[Config::PH_SAMPLES];
  for (uint8_t i = 0; i < Config::PH_SAMPLES; ++i) {
    readings[i] = analogReadMilliVolts(Pins::PH_ANALOG);
    delay(Config::PH_SAMPLE_GAP_MS);
  }
  for (uint8_t i = 1; i < Config::PH_SAMPLES; ++i) {
    const uint32_t value = readings[i];
    int j = i - 1;
    while (j >= 0 && readings[j] > value) {
      readings[j + 1] = readings[j];
      --j;
    }
    readings[j + 1] = value;
  }
  uint32_t sum = 0;
  for (uint8_t i = Config::PH_TRIM_SAMPLES;
       i < Config::PH_SAMPLES - Config::PH_TRIM_SAMPLES; ++i) sum += readings[i];
  gState.phAdcMv = sum / float(Config::PH_SAMPLES - 2 * Config::PH_TRIM_SAMPLES);
  gState.phModuleMv = gState.phAdcMv * Config::PH_DIVIDER_RATIO;
  gState.phVoltageValid = gState.phAdcMv > Config::PH_ADC_MIN_MV &&
                         gState.phAdcMv < Config::PH_ADC_MAX_MV;
  updatePhValue();
}

bool captureCalibrationPoint(float referencePh, String &message) {
  if (!isfinite(referencePh) || referencePh < 0.0f || referencePh > 14.0f) {
    message = "缓冲液参考 pH 须在 0 至 14 之间";
    return false;
  }
  if (!storageReady) {
    message = "标定存储不可用，请重启后重试";
    return false;
  }
  // Measure now, rather than reusing a sample taken before the electrode was moved.
  sample();
  if (!gState.phVoltageValid) {
    message = "pH 电压异常，请检查供电、分压和接线";
    return false;
  }
  if (!gState.phCalibrationPending) {
    firstModuleMv = gState.phModuleMv;
    gState.phCalibrationReference = referencePh;
    gState.phCalibrationPending = true;
    message = String("已记录 pH ") + String(referencePh, 2) +
              "，请换另一种缓冲液，等读数稳定后记录第二点";
    return true;
  }
  SensorMath::PhCalibration candidate;
  if (!SensorMath::calibrate(gState.phCalibrationReference, firstModuleMv,
                            referencePh, gState.phModuleMv, candidate)) {
    message = "两种缓冲液或电压过于接近，请检查后重试；第一点仍保留";
    return false;
  }
  if (preferences.putBytes("ph-cal", &candidate, sizeof(candidate)) != sizeof(candidate)) {
    message = "标定保存失败，旧标定仍有效，请重试第二点";
    return false;
  }
  calibration = candidate;
  gState.phCalibrationPending = false;
  gState.phCalibrationReference = NAN;
  firstModuleMv = NAN;
  updatePhValue();
  message = "pH 两点标定已完成并保存";
  return true;
}

bool resetCalibration(String &message) {
  const SensorMath::PhCalibration empty;
  if (!storageReady || preferences.putBytes("ph-cal", &empty, sizeof(empty)) != sizeof(empty)) {
    message = "清除标定失败，请检查存储后重试";
    return false;
  }
  calibration = empty;
  gState.phCalibrationPending = false;
  gState.phCalibrationReference = NAN;
  firstModuleMv = NAN;
  updatePhValue();
  message = "pH 标定已清除，请重新采集两点";
  return true;
}
}
