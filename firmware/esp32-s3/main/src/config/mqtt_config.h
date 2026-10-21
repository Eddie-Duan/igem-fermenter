#pragma once
#include <Arduino.h>

// Fill these settings for your broker. Keep credentials private and never use
// setInsecure(): the root CA is required so the ESP32 verifies the broker.
namespace MqttConfig {
constexpr char DEVICE_ID[] = "fermenter-01";
constexpr char BROKER_HOST[] = "";       // e.g. mqtt.example.org (no scheme)
constexpr uint16_t BROKER_PORT = 8883;   // MQTT over TLS
constexpr char USERNAME[] = "";
constexpr char PASSWORD[] = "";
constexpr char NTP_SERVER_1[] = "pool.ntp.org";
constexpr char NTP_SERVER_2[] = "time.cloudflare.com";

// Paste the broker CA certificate chain's trusted root certificate here.
// Leave empty until configured; MQTT stays disabled instead of skipping TLS checks.
static const char ROOT_CA[] PROGMEM = R"CERT()CERT";
}

