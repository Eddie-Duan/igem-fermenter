#include <Arduino.h>
#include <ArduinoJson.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <time.h>
#include <math.h>
#include <string.h>
#include "../../shared/app_state.h"
#include "../../config/fermenter_config.h"
#include "../../config/mqtt_config.h"
#include "./mqtt_manager.h"
#include "../control/control_manager.h"
#include "../sensors/sensor_manager.h"
#include "../sensors/ph_sensor.h"

namespace {
WiFiClientSecure tlsClient;
PubSubClient mqttClient(tlsClient);
String availabilityTopic;
String telemetryTopic;
String commandTopic;
String acknowledgementTopic;
struct CommandResult {
  String id;
  String message;
  bool ok = false;
};
CommandResult processedCommands[8];
uint8_t processedIdIndex = 0;
uint32_t nextConnectAttemptMs = 0;
uint32_t retryDelayMs = 2000;
uint32_t lastPublishMs = 0;
bool timeSyncStarted = false;
bool connectRetryScheduled = false;
uint32_t lastTimeSyncAttemptMs = 0;
bool initialized = false;

bool mqttConfigured() {
  return strlen(MqttConfig::BROKER_HOST) > 0 && strlen(MqttConfig::ROOT_CA) > 100;
}

void putFinite(JsonDocument &doc, const char *key, float value) {
  if (isfinite(value)) doc[key] = value;
  else doc[key] = nullptr;
}

void publishAcknowledgement(const String &commandId, bool ok, const String &message, bool duplicate = false) {
  StaticJsonDocument<768> doc;
  doc["id"] = commandId;
  doc["ok"] = ok;
  doc["message"] = message;
  doc["duplicate"] = duplicate;
  doc["heaterEnabled"] = gState.heaterEnabled;
  doc["heaterOn"] = gState.heaterOn;
  doc["targetTempC"] = gState.targetTempC;
  putFinite(doc, "ph", gState.ph);
  doc["phCalibrated"] = gState.phCalibrated;
  doc["phCalibrationPending"] = gState.phCalibrationPending;
  putFinite(doc, "phCalibrationReference", gState.phCalibrationReference);
  doc["calibrationRunning"] = gState.calibrationRunning;
  if (doc.overflowed()) return;
  char payload[1024];
  if (measureJson(doc) >= sizeof(payload)) return;
  const size_t length = serializeJson(doc, payload, sizeof(payload));
  if (length > 0) mqttClient.publish(acknowledgementTopic.c_str(), payload, false);
}

const CommandResult *findProcessedCommand(const String &commandId) {
  for (const CommandResult &saved : processedCommands)
    if (saved.id == commandId) return &saved;
  return nullptr;
}

void rememberCommand(const String &commandId, bool ok, const String &message) {
  processedCommands[processedIdIndex].id = commandId;
  processedCommands[processedIdIndex].ok = ok;
  processedCommands[processedIdIndex].message = message;
  processedIdIndex = (processedIdIndex + 1) % 8;
}

void onMqttMessage(char *topic, byte *payload, unsigned int length) {
  if (String(topic) != commandTopic || length == 0 || length > 512) return;
  StaticJsonDocument<512> doc;
  const DeserializationError parseError = deserializeJson(doc, payload, length);
  String commandId = doc["id"] | "";
  if (parseError) {
    publishAcknowledgement(commandId.length() <= 64 ? commandId : String(""), false, "invalid_json");
    return;
  }
  if (commandId.length() == 0 || commandId.length() > 64) {
    publishAcknowledgement("", false, "invalid_command_id");
    return;
  }

  const char *type = doc["type"] | "";
  const time_t now = time(nullptr);
  const int64_t issuedAt = doc["issuedAt"] | int64_t(0);
  if (issuedAt == 0 || now < 1700000000 || issuedAt > int64_t(now) + 30 ||
      int64_t(now) - issuedAt > Config::MQTT_COMMAND_MAX_AGE_SEC) {
    publishAcknowledgement(commandId, false, "stale_or_missing_timestamp");
    return;
  }
  const CommandResult *previous = findProcessedCommand(commandId);
  if (previous != nullptr) {
    publishAcknowledgement(commandId, previous->ok, previous->message, true);
    return;
  }

  bool ok = false;
  String message = "unknown_command";
  if (strcmp(type, "set_target") == 0) {
    if (doc["value"].is<float>() || doc["value"].is<int>()) {
      String error;
      ok = Controller::setTargetTemperature(doc["value"].as<float>(), error);
      message = ok ? "target_updated" : "target_out_of_range";
    } else message = "target_must_be_numeric";
  } else if (strcmp(type, "heater_enable") == 0) {
    if (doc["value"].is<bool>()) {
      Controller::setHeaterEnabled(doc["value"].as<bool>());
      ok = true;
      message = "heater_control_updated";
    } else message = "heater_value_must_be_boolean";
  } else if (strcmp(type, "reset_alarm") == 0) {
    Controller::clearAlarm();
    ok = true;
    message = "alarm_reset";
  } else if (strcmp(type, "calibrate_blank") == 0) {
    ok = Sensors::requestBlankCalibration();
    message = ok ? "blank_calibration_queued" : "blank_calibration_busy";
  } else if (strcmp(type, "reset_blank") == 0) {
    Sensors::resetBlankCalibration();
    ok = true;
    message = "blank_reset";
  } else if (strcmp(type, "calibrate_ph") == 0) {
    if (doc["value"].is<float>() || doc["value"].is<int>())
      ok = PhSensor::captureCalibrationPoint(doc["value"].as<float>(), message);
    else message = "ph_reference_must_be_numeric";
  } else if (strcmp(type, "reset_ph_calibration") == 0) {
    ok = PhSensor::resetCalibration(message);
  }
  rememberCommand(commandId, ok, message);
  publishAcknowledgement(commandId, ok, message);
}

void publishTelemetry() {
  StaticJsonDocument<1024> doc;
  doc["deviceId"] = MqttConfig::DEVICE_ID;
  doc["timestamp"] = int64_t(time(nullptr));
  doc["uptimeMs"] = millis();
  doc["tempValid"] = gState.tempValid;
  putFinite(doc, "ph", gState.ph);
  putFinite(doc, "phAdcMv", gState.phAdcMv);
  putFinite(doc, "phModuleMv", gState.phModuleMv);
  doc["phVoltageValid"] = gState.phVoltageValid;
  doc["phCalibrated"] = gState.phCalibrated;
  doc["phValid"] = gState.phValid;
  doc["phCalibrationPending"] = gState.phCalibrationPending;
  putFinite(doc, "phCalibrationReference", gState.phCalibrationReference);
  putFinite(doc, "lightFullCounts", gState.lightFullCounts);
  putFinite(doc, "lightIrCounts", gState.lightIrCounts);
  putFinite(doc, "darkCounts", gState.darkCounts);
  putFinite(doc, "lux", gState.lux);
  doc["calibrationRunning"] = gState.calibrationRunning;
  doc["calibrationSamples"] = gState.calibrationSamples;
  if (gState.tempValid) doc["tempC"] = gState.tempC;
  else doc["tempC"] = nullptr;
  if (gState.opticalValid) doc["lightCounts"] = gState.lightCounts;
  else doc["lightCounts"] = nullptr;
  if (isfinite(gState.blankCounts)) doc["blankCounts"] = gState.blankCounts;
  else doc["blankCounts"] = nullptr;
  if (isfinite(gState.odProxy)) doc["odProxy"] = gState.odProxy;
  else doc["odProxy"] = nullptr;
  if (isfinite(gState.slopePerMin)) doc["slopePerMin"] = gState.slopePerMin;
  else doc["slopePerMin"] = nullptr;
  doc["opticalValid"] = gState.opticalValid;
  doc["targetTempC"] = gState.targetTempC;
  doc["heaterEnabled"] = gState.heaterEnabled;
  doc["heaterOn"] = gState.heaterOn;
  doc["lysisAlarm"] = gState.lysisAlarm;
  char payload[1280];
  if (doc.overflowed() || measureJson(doc) >= sizeof(payload)) {
    Serial.println("# MQTT telemetry JSON capacity exceeded");
    return;
  }
  const size_t length = serializeJson(doc, payload, sizeof(payload));
  if (length > 0 && !mqttClient.publish(telemetryTopic.c_str(), payload, false))
    Serial.println("# MQTT telemetry publish failed");
}

void startTimeSync() {
  if (WiFi.status() != WL_CONNECTED || time(nullptr) >= 1700000000) return;
  const uint32_t nowMs = millis();
  if (timeSyncStarted && nowMs - lastTimeSyncAttemptMs < 60000) return;

  configTime(0, 0, MqttConfig::NTP_SERVER_1, MqttConfig::NTP_SERVER_2);
  lastTimeSyncAttemptMs = nowMs;
  timeSyncStarted = true;
  Serial.println("# NTP time sync requested for TLS certificate and command timestamp checks");
}

void tryConnect(uint32_t nowMs) {
  if (!mqttConfigured() || WiFi.status() != WL_CONNECTED ||
      (connectRetryScheduled && int32_t(nowMs - nextConnectAttemptMs) < 0)) return;
  if (time(nullptr) < 1700000000) return; // wait for a valid clock before certificate checks

  Serial.printf("# Connecting to MQTT broker %s:%u\n", MqttConfig::BROKER_HOST, MqttConfig::BROKER_PORT);
  bool connected;
  if (strlen(MqttConfig::USERNAME) > 0) {
    connected = mqttClient.connect(MqttConfig::DEVICE_ID, MqttConfig::USERNAME, MqttConfig::PASSWORD,
                                   availabilityTopic.c_str(), 1, true, "offline", true);
  } else {
    connected = mqttClient.connect(MqttConfig::DEVICE_ID, availabilityTopic.c_str(), 1, true, "offline");
  }
  if (connected) {
    retryDelayMs = 2000;
    connectRetryScheduled = false;
    mqttClient.publish(availabilityTopic.c_str(), "online", true);
    mqttClient.subscribe(commandTopic.c_str(), 1);
    lastPublishMs = nowMs - Config::MQTT_PUBLISH_PERIOD_MS;
    Serial.println("# MQTT connected; subscribed to command topic");
  } else {
    Serial.printf("# MQTT connect failed, state=%d\n", mqttClient.state());
    nextConnectAttemptMs = nowMs + retryDelayMs;
    connectRetryScheduled = true;
    retryDelayMs = retryDelayMs < 30000 ? retryDelayMs * 2 : 60000;
  }
}
}

namespace MqttManager {
void begin() {
  const String root = String("igem/fermenter/") + MqttConfig::DEVICE_ID;
  availabilityTopic = root + "/availability";
  telemetryTopic = root + "/telemetry";
  commandTopic = root + "/cmd";
  acknowledgementTopic = root + "/ack";
  if (!mqttConfigured()) {
    Serial.println("# MQTT disabled: set broker host and trusted root CA in mqtt_config.h");
    return;
  }
  tlsClient.setCACert(MqttConfig::ROOT_CA);
  tlsClient.setTimeout(3); // WiFiClientSecure uses seconds in this Arduino core
  tlsClient.setHandshakeTimeout(3);
  mqttClient.setServer(MqttConfig::BROKER_HOST, MqttConfig::BROKER_PORT);
  mqttClient.setCallback(onMqttMessage);
  if (!mqttClient.setBufferSize(2048)) {
    Serial.println("# MQTT disabled: packet buffer allocation failed");
    return;
  }
  mqttClient.setKeepAlive(30);
  mqttClient.setSocketTimeout(3);
  initialized = true;
}

void loop() {
  if (!initialized) return;
  startTimeSync();
  if (mqttClient.connected()) {
    mqttClient.loop();
    const uint32_t now = millis();
    if (now - lastPublishMs >= Config::MQTT_PUBLISH_PERIOD_MS) {
      lastPublishMs = now;
      publishTelemetry();
    }
  } else {
    tryConnect(millis());
  }
}

bool connected() {
  return mqttClient.connected();
}
}

