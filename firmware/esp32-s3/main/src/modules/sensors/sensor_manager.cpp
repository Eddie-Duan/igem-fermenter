#include <Arduino.h>
#include <Wire.h>
#include <OneWire.h>
#include <DallasTemperature.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_TSL2591.h>
#include <Preferences.h>
#include "../../shared/app_state.h"
#include "../../config/fermenter_config.h"
#include "./sensor_manager.h"
#include "./ph_sensor.h"
#include "../../shared/sensor_math.h"
#include "../control/control_manager.h"

namespace {
OneWire oneWire(Pins::ONE_WIRE);
DallasTemperature temperatureSensor(&oneWire);
Adafruit_TSL2591 tsl(2591);
Preferences preferences;
bool tslReady = false;
bool calibrationRequested = false;
float calibrationSum = 0.0f;
uint32_t lastTslInitMs = 0;
constexpr uint8_t TSL_ADDRESS = 0x29;

static_assert(Config::TSL_INTEGRATION_MS >= 100 && Config::TSL_INTEGRATION_MS <= 600 &&
              Config::TSL_INTEGRATION_MS % 100 == 0, "TSL2591 integration must be 100..600 ms");
static_assert(Config::OPTICAL_AVERAGES > 0, "Optical average count must be positive");

void setLed(bool on) {
  digitalWrite(Pins::OPTICAL_LED, on == Config::LED_DRIVER_ACTIVE_HIGH ? HIGH : LOW);
}

bool lightResponds() {
  Wire.beginTransmission(TSL_ADDRESS);
  return Wire.endTransmission() == 0;
}

void beginLightSensor() {
  lastTslInitMs = millis();
  tslReady = tsl.begin(&Wire);
  if (!tslReady) {
    Serial.println("# TSL2591 missing at 0x29; temperature/pH continue; retrying in 5 s");
    return;
  }
  tsl.setGain(TSL2591_GAIN_LOW);
  tsl.setTiming(static_cast<tsl2591IntegrationTime_t>(Config::TSL_INTEGRATION_MS / 100 - 1));
  Serial.println("# TSL2591 ready");
}

bool readFrame(uint16_t &full, uint16_t &ir) {
  if (!lightResponds()) {
    tslReady = false;
    return false;
  }
  const uint32_t packed = tsl.getFullLuminosity();
  full = uint16_t(packed & 0xFFFFu);
  ir = uint16_t(packed >> 16);
  if (!lightResponds()) {
    tslReady = false;
    return false;
  }
  return SensorMath::frameUsable(full, ir, Config::TSL_SATURATION_COUNTS);
}

bool readPhase(float &fullMean, float &irMean) {
  uint16_t full = 0, ir = 0;
  if (!readFrame(full, ir)) return false; // discard one frame after a light step
  uint32_t fullSum = 0, irSum = 0;
  for (uint8_t i = 0; i < Config::OPTICAL_AVERAGES; ++i) {
    if (!readFrame(full, ir)) return false;
    fullSum += full;
    irSum += ir;
  }
  fullMean = fullSum / float(Config::OPTICAL_AVERAGES);
  irMean = irSum / float(Config::OPTICAL_AVERAGES);
  return true;
}

bool readOpticalCounts() {
  gState.lightCounts = gState.lightFullCounts = gState.lightIrCounts = NAN;
  gState.darkCounts = gState.lux = NAN;
  if (!tslReady) return false;

  setLed(false);
  delay(Config::LED_SETTLE_MS);
  float darkIr = NAN;
  if (!readPhase(gState.darkCounts, darkIr)) return false;
  setLed(true);
  delay(Config::LED_SETTLE_MS);
  const bool litValid = readPhase(gState.lightFullCounts, gState.lightIrCounts);
  setLed(false);
  if (!litValid) return false;

  if (gState.lightFullCounts > 0) {
    const float lux = tsl.calculateLux(uint16_t(gState.lightFullCounts), uint16_t(gState.lightIrCounts));
    if (isfinite(lux) && lux >= 0.0f) gState.lux = lux;
  }
  gState.lightCounts = SensorMath::transmittedCounts(gState.darkCounts, gState.lightFullCounts,
                                                   Config::MIN_USABLE_LIGHT_COUNTS);
  return isfinite(gState.lightCounts);
}

void storeBlank(float counts) {
  gState.blankCounts = counts;
  const bool saved = preferences.putFloat("blank", counts) == sizeof(float);
  if (!saved)
    Serial.println("# WARNING: blank active in RAM but NVS save failed");
  Controller::resetOpticalTrend();
  Serial.printf("# blank_counts=%.2f %s\n", counts, saved ? "saved" : "RAM only");
}
}

namespace Sensors {
void begin() {
  pinMode(Pins::OPTICAL_LED, OUTPUT);
  setLed(false);
  Wire.begin(Pins::I2C_SDA, Pins::I2C_SCL);
  Wire.setClock(100000);
  Wire.setTimeOut(50);
  temperatureSensor.begin();
  temperatureSensor.setResolution(12);
  PhSensor::begin();
  preferences.begin("fermenter", false);
  gState.blankCounts = preferences.getFloat("blank", NAN);
  if (!isfinite(gState.blankCounts) || gState.blankCounts < Config::MIN_USABLE_LIGHT_COUNTS)
    gState.blankCounts = NAN;
  beginLightSensor();
}

void sample() {
  temperatureSensor.requestTemperatures();
  const float tempC = temperatureSensor.getTempCByIndex(0);
  gState.tempValid = tempC != DEVICE_DISCONNECTED_C && isfinite(tempC) && tempC > -55.0f && tempC < 125.0f;
  gState.tempC = gState.tempValid ? tempC : NAN;
  gState.lastTempSampleMs = millis();
  Controller::updateTemperatureControl();
  PhSensor::sample();
  // Blank calibration owns the optical path; temperature and pH still run on schedule.
  if (!gState.calibrationRunning) gState.opticalValid = readOpticalCounts();
}

bool requestBlankCalibration() {
  if (calibrationRequested || gState.calibrationRunning) return false;
  calibrationRequested = true;
  return true;
}

void resetBlankCalibration() {
  calibrationRequested = false;
  gState.calibrationRunning = false;
  gState.calibrationSamples = 0;
  gState.blankCounts = NAN;
  if (preferences.putFloat("blank", NAN) != sizeof(float))
    Serial.println("# WARNING: blank reset in RAM only; NVS write failed");
  setLed(false);
  Controller::resetOpticalTrend();
  Serial.println("# Optical blank cleared");
}

void loop() {
  if (!tslReady && millis() - lastTslInitMs >= 5000) beginLightSensor();
  if (calibrationRequested) {
    calibrationRequested = false;
    calibrationSum = 0.0f;
    gState.calibrationSamples = 0;
    gState.calibrationRunning = true;
    gState.opticalValid = false;
    Controller::resetOpticalTrend();
    Serial.println("# CAL: keep clean medium in the optical path; measuring 10 samples");
  }
  if (!gState.calibrationRunning) return;
  if (!readOpticalCounts()) {
    gState.calibrationRunning = false;
    gState.opticalValid = false;
    Serial.println("# CAL failed: missing sensor, low signal or saturation; old blank retained");
    return;
  }
  calibrationSum += gState.lightCounts;
  ++gState.calibrationSamples;
  if (gState.calibrationSamples >= Config::BLANK_CALIBRATION_SAMPLES) {
    storeBlank(calibrationSum / gState.calibrationSamples);
    gState.calibrationRunning = false;
    // Require a fresh sample before the new baseline enters trend analysis.
    gState.opticalValid = false;
  }
}
}

