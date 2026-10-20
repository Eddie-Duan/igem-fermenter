#pragma once
#include <Arduino.h>

struct FermenterState {
  float tempC = NAN;
  float ph = NAN;
  float phAdcMv = NAN;
  float phModuleMv = NAN;
  float phCalibrationReference = NAN;
  float lightCounts = NAN;
  float lightFullCounts = NAN;
  float lightIrCounts = NAN;
  float darkCounts = NAN;
  float lux = NAN;
  float blankCounts = NAN;
  float odProxy = NAN;
  float slopePerMin = NAN;
  float targetTempC = 30.0f;
  bool tempValid = false;
  uint32_t lastTempSampleMs = 0;
  bool phVoltageValid = false;
  bool phCalibrated = false;
  bool phValid = false;
  bool phCalibrationPending = false;
  bool opticalValid = false;
  bool heaterEnabled = false;
  bool heaterOn = false;
  bool lysisAlarm = false;
  bool calibrationRunning = false;
  uint8_t calibrationSamples = 0;
};

extern FermenterState gState;

