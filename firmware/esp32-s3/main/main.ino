/*
 * ESP32-S3 智能发酵罐：Flutter BLE 适配版（真实传感器）
 * 在 Arduino IDE 中打开本文件，保留整个 firmware 文件夹及 src 子目录。
 * 开发板选择 ESP32S3 Dev Module；串口监视器使用 115200 baud。
 * 接线与采样参数：src/config/fermenter_config.h；MQTT 配置：src/config/mqtt_config.h。
 * 完整安装、标定与手机连接步骤见 ../README.md 与 ../APP_INTEGRATION.md。
 *
 * 库管理器依赖：
 * Adafruit TSL2591 Library 1.4.5 / Adafruit Unified Sensor 1.1.15
 * Adafruit BusIO 1.17.4 / DallasTemperature 4.0.x / OneWire 2.3.8
 * PubSubClient 2.8 / ArduinoJson 6.21.6（选择 6.x 版本）
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <SPIFFS.h>

#if !defined(ARDUINO_ARCH_ESP32) || !defined(CONFIG_IDF_TARGET_ESP32S3)
#error "Select ESP32S3 Dev Module from esp32 by Espressif Systems."
#endif

// 在入口列出依赖，便于 Arduino IDE 发现并解析各模块所需的库。
#include <Adafruit_TSL2591.h>
#include <Adafruit_Sensor.h>
#include <DallasTemperature.h>
#include <OneWire.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>

#include "./src/app/fermenter_app.h"

void setup() {
  FermenterApp::begin();
}

void loop() {
  FermenterApp::loop();
}
