#include <Arduino.h>
#include <stdlib.h>
#include "./fermenter_app.h"
#include "../shared/app_state.h"
#include "../modules/sensors/sensor_manager.h"
#include "../modules/sensors/ph_sensor.h"
#include "../modules/control/control_manager.h"
#include "../modules/network/network_manager.h"
#include "../modules/mqtt/mqtt_manager.h"
#include "../modules/ble/ble_manager.h"
#include "../config/fermenter_config.h"

namespace {
uint32_t lastSampleMs = 0;
String serialLine;

void printHelp() {
  Serial.println("# Commands: CAL/BLANK, BLANKRESET, PHCAL <buffer_pH>, PHRESET, STATUS, RESET, WIFI_RESET, BLE_FORMAT, HELP");
}

void processSerialCommand(String command) {
  command.trim();
  command.toUpperCase();
  if (command == "CAL" || command == "BLANK") {
    Serial.println(Sensors::requestBlankCalibration() ? "# Blank calibration queued" : "# Blank calibration already running");
  } else if (command == "BLANKRESET") {
    Sensors::resetBlankCalibration();
  } else if (command.startsWith("PHCAL ")) {
    const String text = command.substring(6);
    char *end = nullptr;
    const float referencePh = strtof(text.c_str(), &end);
    String message;
    if (end == text.c_str() || *end != '\0') message = "Usage: PHCAL 7.00";
    else PhSensor::captureCalibrationPoint(referencePh, message);
    Serial.println(String("# ") + message);
  } else if (command == "PHRESET") {
    String message;
    PhSensor::resetCalibration(message);
    Serial.println(String("# ") + message);
  } else if (command == "BLE_FORMAT") {
    Serial.println(FermenterBle::formatLogStorage() ? "# BLE log filesystem formatted; sequence reset to 0" : "# BLE_FORMAT failed: disconnect Bluetooth, disable automatic heating, check SPIFFS partition");
  } else if (command == "RESET") Controller::clearAlarm();
  else if (command == "WIFI_RESET") FermenterNetwork::resetCredentials();
  else if (command == "STATUS") {
    Serial.printf("# temp=%.2f ph=%.3f ph_adc_mV=%.1f ph_module_mV=%.1f ph_valid=%u ph_calibrated=%u ph_pending=%u light=%.2f blank=%.2f od_proxy=%.4f slope=%.5f heater_enabled=%u heater=%u target=%.1f alarm=%u mqtt=%u\n",
                  gState.tempC, gState.ph, gState.phAdcMv, gState.phModuleMv, gState.phValid ? 1 : 0,
                  gState.phCalibrated ? 1 : 0, gState.phCalibrationPending ? 1 : 0,
                  gState.lightCounts, gState.blankCounts, gState.odProxy, gState.slopePerMin,
                  gState.heaterEnabled ? 1 : 0, gState.heaterOn ? 1 : 0,
                  gState.targetTempC, gState.lysisAlarm ? 1 : 0, MqttManager::connected() ? 1 : 0);
  } else printHelp();
}

void readSerialCommands() {
  while (Serial.available()) {
    const char c = char(Serial.read());
    if (c == '\n' || c == '\r') {
      if (serialLine.length()) processSerialCommand(serialLine);
      serialLine = "";
    } else if (serialLine.length() < 63) serialLine += c;
  }
}

void printCsv() {
  // Preserve the original first eight columns; append pH and raw optical fields.
  Serial.printf("%lu,%.3f,%.2f,%.3f,%.5f,%u,%u,%u,%.3f,%.1f,%.1f,%u,%u,%u,%.1f,%.1f,%.1f,%.2f,%u\n",
                static_cast<unsigned long>(millis()), gState.tempC, gState.lightCounts,
                gState.odProxy, gState.slopePerMin, gState.opticalValid ? 1 : 0,
                gState.heaterOn ? 1 : 0, gState.lysisAlarm ? 1 : 0,
                gState.ph, gState.phAdcMv, gState.phModuleMv, gState.phVoltageValid ? 1 : 0,
                gState.phCalibrated ? 1 : 0, gState.phValid ? 1 : 0,
                gState.lightFullCounts, gState.lightIrCounts, gState.darkCounts, gState.lux,
                gState.calibrationRunning ? 1 : 0);
}
}

namespace FermenterApp {
void begin() {
  Serial.begin(115200);
  delay(200);
  Controller::begin(); // put actuator outputs in their inactive state first
  Sensors::begin();
  FermenterNetwork::begin();
  MqttManager::begin();
  FermenterBle::begin();
  Serial.println("# millis,temp_C,light_counts,od_proxy,slope_per_min,optical_valid,heater_on,lysis_alarm,ph,ph_adc_mV,ph_module_mV,ph_voltage_valid,ph_calibrated,ph_valid,full_counts,ir_counts,dark_counts,lux,calibration_running");
  printHelp();
  lastSampleMs = millis() - Config::SAMPLE_PERIOD_MS;
}

void loop() {
  Controller::updateTemperatureControl();
  readSerialCommands();
  FermenterBle::loop();
  FermenterNetwork::loop();
  MqttManager::loop();
  Sensors::loop();
  const uint32_t now = millis();
  if (now - lastSampleMs >= Config::SAMPLE_PERIOD_MS) {
    lastSampleMs = now;
    Sensors::sample(); // temperature and pH continue during optical calibration
    Controller::update();
    printCsv();
    FermenterBle::recordSample();
  }
  FermenterBle::loop();
  Controller::updateTemperatureControl();
}


} // namespace FermenterApp
