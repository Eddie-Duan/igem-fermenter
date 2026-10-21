#include "./ble_manager.h"
#include "../../config/ble_config.h"
#include "./ble_log.h"
#include "./ble_protocol.h"
#include "../../shared/app_state.h"
#include "../control/control_manager.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <esp_mac.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <sys/time.h>
#include <time.h>
#include <atomic>

namespace {
BLECharacteristic *dataChar = nullptr, *statusChar = nullptr;
BLE2902 *dataSubscription = nullptr, *statusSubscription = nullptr;
QueueHandle_t commands = nullptr;
std::atomic<bool> linkUp{false}, queueOverflow{false};
std::atomic<uint32_t> session{0};
uint32_t observedSession = 0;
bool wasConnected = false, activeStream = false, syncing = false, waiting = false;
bool ackValid = false, statusPending = false, motorReady = false;
uint32_t cursor = 0, syncEnd = 0, waitingSeq = 0, lastAck = 0, ackAt = 0, statusDue = 0;
uint8_t retries = 0;
uint32_t lastRecordAt = 0, lastWarningAt = 0;
bool haveRecordTime = false, warned = false;
struct Command { uint32_t session; uint8_t length; uint8_t data[6]; };

bool subscribed() {
  return linkUp.load() && dataSubscription->getNotifications() && statusSubscription->getNotifications();
}
void status(const uint8_t *frame, size_t length) {
  if (!linkUp.load() || !statusSubscription->getNotifications()) return;
  statusChar->setValue(frame, length);
  statusChar->notify();
}
void error(uint8_t code) {
  uint8_t frame[] = {ST_ERROR, code};
  status(frame, sizeof(frame));
  Serial.printf("# BLE error=0x%02x\n", code);
}
void logStatus() {
  uint8_t frame[9] = {ST_LOG_STATUS};
  wrU32(frame + 1, BleLog::oldest());
  wrU32(frame + 5, BleLog::count());
  status(frame, sizeof(frame));
}
void stopStream() { activeStream = syncing = waiting = false; }
void warn(const char *message) {
  if (!warned || millis() - lastWarningAt >= BleConfig::RECORD_PERIOD_MS) {
    Serial.println(message);
    warned = true;
    lastWarningAt = millis();
  }
}
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override { ++session; linkUp.store(true); }
  void onDisconnect(BLEServer *) override { linkUp.store(false); ++session; }
};
class ControlCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    // BLE callbacks run on another task. All controls, log I/O and notify state
    // execute in loop(), never from this callback.
    const size_t length = characteristic->getLength();
    Command command{};
    command.session = session.load();
    command.length = length <= sizeof(command.data) ? length : 7;
    if (length && length <= sizeof(command.data)) memcpy(command.data, characteristic->getData(), length);
    if (xQueueSend(commands, &command, 0) != pdTRUE) queueOverflow.store(true);
  }
};

void applyControl(const uint8_t *frame) {
  const uint8_t flags = frame[1];
  const bool stirrer = flags & CTRL_FLAG_STIRRER;
  const bool heater = flags & CTRL_FLAG_HEATER;
  const uint16_t rpm = rdU16(frame + 2);
  const float target = rdU16(frame + 4) / 10.0f;
  if ((flags & ~(CTRL_FLAG_STIRRER | CTRL_FLAG_HEATER)) ||
      (stirrer && (!motorReady || rpm < BleConfig::STIRRER_MIN_RPM || rpm > BleConfig::STIRRER_MAX_RPM))) {
    // An OFF request remains effective even when another field is unsupported.
    if (!heater) Controller::setHeaterEnabled(false);
    error(ERR_INVALID_ARG);
    return;
  }
  String message;
  if (!Controller::setTargetTemperature(target, message)) {
    if (!heater) Controller::setHeaterEnabled(false);
    error(ERR_INVALID_ARG);
    Serial.println(String("# BLE rejected target: ") + message);
    return;
  }
  Controller::setHeaterEnabled(heater); // enables the existing guarded thermostat
  if (motorReady) {
    const uint32_t duty = stirrer ? map(rpm, BleConfig::STIRRER_MIN_RPM, BleConfig::STIRRER_MAX_RPM,
        BleConfig::STIRRER_MIN_DUTY, BleConfig::STIRRER_MAX_DUTY) : 0;
    ledcWrite(BleConfig::STIRRER_PIN, duty);
  }
  Serial.printf("# BLE control applied: heater_enabled=%u target=%.1f stirrer=%u requested_rpm=%u\n",
      heater, target, stirrer, rpm);
}

void process(const Command &c) {
  if (c.length == 0 || c.length > 6) { error(ERR_BAD_FRAME); return; }
  const uint8_t op = c.data[0];
  if (c.length != (op == CMD_SET_CONTROL ? 6 : 5)) { error(ERR_BAD_FRAME); return; }
  const uint32_t value = rdU32(c.data + 1);
  switch (op) {
    case CMD_SYNC_REQ: {
      if (!BleLog::ready()) { error(ERR_FLASH_FAILURE); return; }
      if (value > BleLog::next()) { error(ERR_BAD_SEQUENCE); return; }
      syncEnd = BleLog::next(); // snapshot boundary; new records follow as live data
      cursor = value < BleLog::oldest() ? BleLog::oldest() : value;
      // Re-send the predecessor as a duplicate so even a no-new-data sync has
      // an actual ACK proving the app has durably stored the COMMIT boundary.
      if (cursor > BleLog::oldest()) --cursor;
      syncing = activeStream = true;
      waiting = false;
      retries = 0;
      logStatus();
      break;
    }
    case CMD_ACK:
      if (waiting && value == waitingSeq) {
        lastAck = value;
        ackValid = true;
        cursor = value + 1;
        waiting = false;
        retries = 0;
      }
      break; // out-of-order/future ACKs never authorize reclaim
    case CMD_COMMIT:
      if (!ackValid || value > lastAck || value == UINT32_MAX) { error(ERR_BAD_SEQUENCE); return; }
      if (!BleLog::reclaim(value)) { error(ERR_FLASH_FAILURE); return; }
      logStatus();
      break;
    case CMD_SET_TIME: {
      if (value < 1704067200UL) { error(ERR_INVALID_ARG); return; }
      timeval tv{static_cast<time_t>(value), 0};
      if (settimeofday(&tv, nullptr) != 0) error(ERR_INVALID_ARG);
      break;
    }
    case CMD_SET_CONTROL: applyControl(c.data); break;
    default: error(ERR_INVALID_ARG);
  }
}

bool sendRecord(uint32_t seq) {
  uint8_t frame[RECORD_SIZE];
  if (!BleLog::read(seq, frame)) { error(ERR_FLASH_FAILURE); stopStream(); return false; }
  // Mark outstanding BEFORE notify: an ACK can arrive immediately on the BLE task.
  waitingSeq = seq;
  waiting = true;
  ackAt = millis();
  dataChar->setValue(frame, sizeof(frame));
  dataChar->notify();
  return true;
}
}

namespace FermenterBle {
void begin() {
  commands = xQueueCreate(32, sizeof(Command));
  if (!commands) { Serial.println("# BLE command queue allocation failed"); return; }
  BleLog::begin();
  if (BleConfig::STIRRER_ENABLED) {
    digitalWrite(BleConfig::STIRRER_PIN, LOW);
    pinMode(BleConfig::STIRRER_PIN, OUTPUT);
    motorReady = ledcAttach(BleConfig::STIRRER_PIN, BleConfig::STIRRER_PWM_HZ, BleConfig::STIRRER_PWM_BITS);
    if (motorReady) ledcWrite(BleConfig::STIRRER_PIN, 0);
  }
  BLEDevice::init(BLE_DEVICE_NAME);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(BLE_SERVICE_UUID);
  BLECharacteristic *info = service->createCharacteristic(BLE_CHAR_DEVICE_INFO, BLECharacteristic::PROPERTY_READ);
  uint8_t infoFrame[16] = {}, mac[6] = {};
  esp_read_mac(mac, ESP_MAC_BT);
  wrU32(infoFrame, FIRMWARE_VERSION);
  memcpy(infoFrame + 4, mac, sizeof(mac));
  wrU32(infoFrame + 12, LOG_CAPACITY);
  info->setValue(infoFrame, sizeof(infoFrame)); // battery remains 0: no battery ADC hardware
  dataChar = service->createCharacteristic(BLE_CHAR_SENSOR_DATA, BLECharacteristic::PROPERTY_NOTIFY);
  dataSubscription = new BLE2902();
  dataChar->addDescriptor(dataSubscription);
  statusChar = service->createCharacteristic(BLE_CHAR_SYNC_STATUS, BLECharacteristic::PROPERTY_NOTIFY);
  statusSubscription = new BLE2902();
  statusChar->addDescriptor(statusSubscription);
  BLECharacteristic *control = service->createCharacteristic(BLE_CHAR_SYNC_CONTROL, BLECharacteristic::PROPERTY_WRITE);
  control->setCallbacks(new ControlCallbacks());
  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.printf("# BLE ready: %s; app record period=120s; stirrer enabled=%u\n", BLE_DEVICE_NAME, motorReady);
}

void loop() {
  if (!commands || !dataChar) return;
  const bool up = linkUp.load();
  const uint32_t currentSession = session.load();
  if (currentSession != observedSession) {
    stopStream();
    ackValid = false;
    statusPending = up;
    statusDue = millis() + 800;
    observedSession = currentSession;
    if (motorReady) ledcWrite(BleConfig::STIRRER_PIN, 0);
    if (!up || wasConnected) BLEDevice::startAdvertising();
  }
  wasConnected = up;
  if (!up) return;
  if (queueOverflow.exchange(false)) { error(ERR_BAD_FRAME); stopStream(); }
  Command command;
  for (uint8_t i = 0; i < 16 && xQueueReceive(commands, &command, 0) == pdTRUE; ++i) {
    if (command.session == observedSession && command.session == session.load()) process(command);
    Controller::updateTemperatureControl();
  }
  if (statusPending && statusSubscription->getNotifications() && int32_t(millis() - statusDue) >= 0) {
    logStatus();
    statusPending = false;
  }
  if (!activeStream || !subscribed()) return;
  if (waiting) {
    if (millis() - ackAt >= BleConfig::ACK_TIMEOUT_MS) {
      if (retries++ < BleConfig::MAX_RETRIES) sendRecord(waitingSeq);
      else { error(ERR_BAD_SEQUENCE); stopStream(); }
    }
    return;
  }
  if (syncing && cursor >= syncEnd) {
    uint8_t frame[5] = {ST_SYNC_END};
    wrU32(frame + 1, syncEnd);
    status(frame, sizeof(frame));
    syncing = false;
    return; // keep SYNC_END separate from subsequent live notifications
  }
  if (cursor < BleLog::next()) sendRecord(cursor);
}

void recordSample() {
  if (haveRecordTime && millis() - lastRecordAt < BleConfig::RECORD_PERIOD_MS) return;
  // v1 app has no validity bit or null encoding. Never send fabricated zero values.
  if (!gState.tempValid || !gState.phValid || !gState.opticalValid || gState.calibrationRunning ||
      !isfinite(gState.tempC) || !isfinite(gState.ph) || !isfinite(gState.odProxy)) {
    warn("# BLE record deferred: need valid temperature, completed pH and optical blank calibration");
    return;
  }
  const float od = max(0.0f, gState.odProxy);
  if (gState.tempC < -327.68f || gState.tempC > 327.67f || od > 32.767f) {
    warn("# BLE record deferred: outside v1 fixed-point range");
    return;
  }
  const time_t t = time(nullptr);
  const uint32_t timestamp = t >= 1704067200 ? static_cast<uint32_t>(t) : 0;
  uint32_t seq;
  if (!BleLog::append(gState.tempC, gState.ph, od, timestamp, seq)) {
    warn("# BLE record not saved: filesystem unavailable, write failure or 2000-record capacity reached");
    return;
  }
  lastRecordAt = millis();
  haveRecordTime = true;
  Serial.printf("# BLE record saved seq=%lu timestamp=%lu\n", (unsigned long)seq, (unsigned long)timestamp);
}
bool connected() { return linkUp.load(); }
bool formatLogStorage() {
  if (gState.heaterEnabled || connected()) return false;
  stopStream();
  ackValid = false;
  haveRecordTime = false;
  return BleLog::format();
}
}
