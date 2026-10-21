#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Preferences.h>
#include <esp_system.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <sys/time.h>
#include "../../shared/app_state.h"
#include "../../config/mqtt_config.h"
#include "../../config/fermenter_config.h"
#include "./network_manager.h"
#include "../control/control_manager.h"
#include "../sensors/sensor_manager.h"
#include "../mqtt/mqtt_manager.h"
#include "../sensors/ph_sensor.h"
#include "../log/log_store.h"
#include "../log/record_format.h"

namespace {
WebServer server(80);
Preferences preferences;
String webPassword;
String setupApSsid;
bool stationWasConnected = false;
bool ntpStarted = false;

const char WEB_PAGE[] PROGMEM = R"rawliteral(
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>智能发酵罐</title><style>
body{font-family:system-ui,sans-serif;max-width:850px;margin:24px auto;padding:0 16px;background:#f4f7f8;color:#17212b}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px}.card{background:white;border:1px solid #d8e0e5;border-radius:12px;padding:16px}.v{font-size:1.5rem;font-weight:650;margin-top:6px}label{display:block;margin:10px 0 5px}input{font:inherit;padding:8px;border:1px solid #aab7c0;border-radius:7px}button{font:inherit;padding:9px 13px;border:0;border-radius:8px;background:#126b60;color:white;margin-top:8px}.note{color:#52636d;line-height:1.5;font-size:.93rem}
</style></head><body><h1>智能发酵罐</h1><p class="note">本地监控与操作台。光学值是相对趋势指标，不是已标定 OD600。</p>
<div class="grid"><section class="card">温度<div id="temp" class="v">--</div><p id="heat" class="note">加热 --</p></section>
<section class="card">pH<div id="ph" class="v">--</div><p id="phState" class="note">等待采样</p><p id="phVoltage" class="note"></p></section>
<section class="card">相对光学衰减<div id="od" class="v">--</div><p class="note">斜率 <span id="slope">--</span> /min</p></section>
<section class="card">光强 / 空白<div id="light" class="v">--</div><p id="blank" class="note">空白 --</p></section>
<section class="card">报警<div id="alarm" class="v">--</div><p id="net" class="note">网络 --</p></section></div>
<section class="card" style="margin-top:12px"><h2>温控</h2><p class="note">自动加热每次重启后默认关闭；传感器故障或达到软件过温上限时关闭加热。</p>
<form id="control"><label>目标温度 °C</label><input id="target" type="number" min="5" max="39" step="0.1" required><label><input id="enabled" type="checkbox"> 启用自动加热</label><button>保存控制设置</button></form>
<button id="cal">标定纯培养基空白</button> <button id="reset">复位报警</button></section>
<section class="card" style="margin-top:12px"><h2>pH 标定</h2><p class="note">将电极放入第一种缓冲液，等待至少一分钟且读数稳定后记录参考 pH。清洗后换另一种缓冲液，再记录第二点。请填写缓冲液标签上对应温度的实际 pH。</p>
<p id="phProgress" class="note"></p><form id="phCalibration"><label for="phRef">当前缓冲液的参考 pH</label><input id="phRef" type="number" min="0" max="14" step="0.01" value="7.00" required><button id="phCapture">记录第一个点</button></form><button id="phReset">清除 pH 标定</button></section>
<section class="card" style="margin-top:12px"><h2>路由器 Wi-Fi</h2><form id="wifi"><label>Wi-Fi 名称</label><input id="ssid" maxlength="32" required><label>Wi-Fi 密码</label><input id="pw" type="password" autocomplete="new-password"><button>保存并连接</button></form><p id="ips" class="note"></p></section>
<p id="message" class="note"></p><script>
const $=x=>document.getElementById(x),fmt=(n,d=2)=>n==null||!Number.isFinite(Number(n))?'--':Number(n).toFixed(d);
async function call(path,data){let r=await fetch(path,{method:data?'POST':'GET',headers:data?{'Content-Type':'application/x-www-form-urlencoded'}:{},body:data?new URLSearchParams(data):undefined});let t=await r.text(),j={};try{j=JSON.parse(t)}catch{}if(!r.ok)throw Error(j.error||t||r.status);return j}
async function act(path,data){try{$('message').textContent=(await call(path,data)).message||'完成';setTimeout(refresh,400)}catch(e){$('message').textContent='操作失败：'+e.message}}
async function refresh(){try{
  let s=await call('/api/status');
  $('temp').textContent=fmt(s.tempC)+' °C';
  $('heat').textContent='自动温控 '+(s.heaterEnabled?'已启用':'已关闭')+'；继电器 '+(s.heaterOn?'开启':'关闭');
  $('ph').textContent=fmt(s.ph,2);
  $('phState').textContent=!s.phCalibrated?'尚未完成两点标定':s.phValid?'已标定':'已标定，当前读数无效';
  $('phVoltage').textContent='模块信号 '+fmt(s.phModuleMv,0)+' mV';
  $('phProgress').textContent=s.phCalibrationPending?'已记录 pH '+fmt(s.phCalibrationReference,2)+'，请换另一种缓冲液后记录第二点':'等待记录第一种缓冲液；完整标定会断电保存。';
  $('phCapture').textContent=s.phCalibrationPending?'记录第二个点':'记录第一个点';
  $('od').textContent=fmt(s.odProxy,4);$('slope').textContent=fmt(s.slopePerMin,5);
  $('light').textContent=fmt(s.lightCounts,1);
  $('blank').textContent='空白 '+fmt(s.blankCounts,1)+(s.calibrationRunning?'（标定 '+s.calibrationSamples+'/10）':'');
  $('alarm').textContent=s.alarm?'下降趋势报警':'正常';
  $('net').textContent='MQTT '+(s.mqttConnected?'已连接':'未连接');
  if(!$('control').contains(document.activeElement)){$('target').value=s.targetTempC;$('enabled').checked=s.heaterEnabled;}
  $('ips').textContent='路由器 IP '+s.staIp+' | 设备热点 '+s.apIp;
}catch(e){$('message').textContent='状态读取失败：'+e.message}}
$('control').onsubmit=e=>{e.preventDefault();act('/api/control',{target:$('target').value,heater:$('enabled').checked?'1':'0'})};$('wifi').onsubmit=e=>{e.preventDefault();act('/api/wifi',{ssid:$('ssid').value,password:$('pw').value})};$('cal').onclick=()=>act('/api/calibrate',{});$('reset').onclick=()=>act('/api/reset',{});refresh();setInterval(refresh,2500);
$('phCalibration').onsubmit=e=>{e.preventDefault();act('/api/ph/calibrate',{reference:$('phRef').value})};$('phReset').onclick=()=>act('/api/ph/reset',{});
</script></body></html>
)rawliteral";

String makePassword() {
  static const char chars[] = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
  String password;
  password.reserve(16);
  for (uint8_t i = 0; i < 16; ++i) password += chars[esp_random() % (sizeof(chars) - 1)];
  return password;
}

bool authorize() {
  if (server.authenticate("admin", webPassword.c_str())) return true;
  server.requestAuthentication(BASIC_AUTH, "Fermenter S3");
  return false;
}

void sendJson(int code, const String &payload) {
  server.sendHeader("Cache-Control", "no-store");
  server.send(code, "application/json; charset=utf-8", payload);
}

String jsonFloat(float value, unsigned digits = 3) {
  return isfinite(value) ? String(value, digits) : String("null");
}

/// 解析表单里的无符号整数；缺省/非法/负数一律返回 false。
bool argumentUint(const char *name, uint32_t &value) {
  if (!server.hasArg(name)) return false;
  const String text = server.arg(name);
  if (text.length() == 0 || text.length() > 10) return false;
  char *end = nullptr;
  const unsigned long parsed = strtoul(text.c_str(), &end, 10);
  if (end == text.c_str() || *end != '\0') return false;
  value = static_cast<uint32_t>(parsed);
  return true;
}

/// 协议版本：App 用它确认固件提供 /api/readings 等同步接口。
constexpr uint8_t API_VERSION = 1;

String firmwareLabel() {
  return String((FIRMWARE_VERSION >> 16) & 0xFF) + "." +
         String((FIRMWARE_VERSION >> 8) & 0xFF) + "." +
         String(FIRMWARE_VERSION & 0xFF);
}

String deviceId() {
  String mac = WiFi.macAddress();
  mac.replace(":", "");
  return mac;
}

void handleStatus() {
  if (!authorize()) return;
  String body = "{";
  body.reserve(1536);
  body += "\"tempC\":" + jsonFloat(gState.tempC, 2);
  body += ",\"tempValid\":" + String(gState.tempValid ? "true" : "false");
  body += ",\"ph\":" + jsonFloat(gState.ph, 3);
  body += ",\"phAdcMv\":" + jsonFloat(gState.phAdcMv, 1);
  body += ",\"phModuleMv\":" + jsonFloat(gState.phModuleMv, 1);
  body += ",\"phVoltageValid\":" + String(gState.phVoltageValid ? "true" : "false");
  body += ",\"phCalibrated\":" + String(gState.phCalibrated ? "true" : "false");
  body += ",\"phValid\":" + String(gState.phValid ? "true" : "false");
  body += ",\"phCalibrationPending\":" + String(gState.phCalibrationPending ? "true" : "false");
  body += ",\"phCalibrationReference\":" + jsonFloat(gState.phCalibrationReference, 2);
  body += ",\"lightCounts\":" + jsonFloat(gState.lightCounts, 1);
  body += ",\"blankCounts\":" + jsonFloat(gState.blankCounts, 1);
  body += ",\"lightFullCounts\":" + jsonFloat(gState.lightFullCounts, 1);
  body += ",\"lightIrCounts\":" + jsonFloat(gState.lightIrCounts, 1);
  body += ",\"darkCounts\":" + jsonFloat(gState.darkCounts, 1);
  body += ",\"lux\":" + jsonFloat(gState.lux, 2);
  body += ",\"odProxy\":" + jsonFloat(gState.odProxy, 4);
  body += ",\"slopePerMin\":" + jsonFloat(gState.slopePerMin, 5);
  body += ",\"targetTempC\":" + String(gState.targetTempC, 1);
  body += ",\"heaterEnabled\":" + String(gState.heaterEnabled ? "true" : "false");
  body += ",\"heaterOn\":" + String(gState.heaterOn ? "true" : "false");
  body += ",\"alarm\":" + String(gState.lysisAlarm ? "true" : "false");
  body += ",\"opticalValid\":" + String(gState.opticalValid ? "true" : "false");
  body += ",\"calibrationRunning\":" + String(gState.calibrationRunning ? "true" : "false");
  body += ",\"calibrationSamples\":" + String(gState.calibrationSamples);
  body += ",\"stirrerSupported\":" + String(Controller::stirrerSupported() ? "true" : "false");
  body += ",\"stirrerOn\":" + String(Controller::stirrerOn() ? "true" : "false");
  body += ",\"stirrerRpm\":" + String(Controller::stirrerRpm());
  // 日志游标：App 据此判断还能同步哪一段序号。
  body += ",\"oldestSeq\":" + String(LogStore::oldest());
  body += ",\"nextSeq\":" + String(LogStore::next());
  body += ",\"recordCount\":" + String(LogStore::count());
  body += ",\"logCapacity\":" + String(LOG_CAPACITY);
  body += ",\"logReady\":" + String(LogStore::ready() ? "true" : "false");
  body += ",\"sampleIntervalS\":" + String(Config::RECORD_PERIOD_MS / 1000);
  body += ",\"apiVersion\":" + String(API_VERSION);
  body += ",\"firmware\":\"" + firmwareLabel() + "\"";
  body += ",\"deviceId\":\"" + deviceId() + "\"";
  body += ",\"mqttConnected\":" + String(MqttManager::connected() ? "true" : "false");
  body += ",\"wifiConnected\":" + String(WiFi.status() == WL_CONNECTED ? "true" : "false");
  body += ",\"staIp\":\"" + WiFi.localIP().toString() + "\"";
  body += ",\"apIp\":\"" + WiFi.softAPIP().toString() + "\"}";
  sendJson(200, body);
}

void handleControl() {
  if (!authorize()) return;
  if (!server.hasArg("target") || !server.hasArg("heater")) {
    sendJson(400, "{\"error\":\"缺少温度目标或加热状态\"}");
    return;
  }
  const String targetText = server.arg("target");
  char *end = nullptr;
  const float requestedTarget = strtof(targetText.c_str(), &end);
  String error;
  if (end == targetText.c_str() || *end != '\0') error = "目标温度格式无效";
  if (error.length() > 0 || !Controller::setTargetTemperature(requestedTarget, error)) {
    sendJson(400, "{\"error\":\"" + error + "\"}");
    return;
  }
  Controller::setHeaterEnabled(server.arg("heater") == "1");

  String warning;
  // 搅拌是可选字段：不传就不改动当前状态（网页的温控表单就不带它）。
  if (server.hasArg("stirrer")) {
    const bool wantStirrer = server.arg("stirrer") == "1";
    uint32_t rpm = 0;
    if (server.hasArg("rpm") && !argumentUint("rpm", rpm)) {
      sendJson(400, "{\"error\":\"转速格式无效\"}");
      return;
    }
    if (wantStirrer && !Controller::stirrerSupported()) {
      warning = "固件未启用搅拌输出（fermenter_config.h 的 STIRRER_ENABLED），已保存其余设置";
      Controller::setStirrer(false, 0);
    } else if (wantStirrer && (rpm < Config::STIRRER_MIN_RPM || rpm > Config::STIRRER_MAX_RPM)) {
      sendJson(400, "{\"error\":\"转速须在 100–300 rpm 之间\"}");
      return;
    } else {
      Controller::setStirrer(wantStirrer, static_cast<uint16_t>(rpm));
    }
  }

  String body = "{\"message\":\"控制设置已保存\"";
  body += ",\"stirrerSupported\":" + String(Controller::stirrerSupported() ? "true" : "false");
  body += ",\"stirrerOn\":" + String(Controller::stirrerOn() ? "true" : "false");
  body += ",\"stirrerRpm\":" + String(Controller::stirrerRpm());
  if (warning.length() > 0) body += ",\"warning\":\"" + warning + "\"";
  body += "}";
  sendJson(200, body);
}

void handleReset() {
  if (!authorize()) return;
  Controller::clearAlarm();
  sendJson(200, "{\"message\":\"报警已复位，趋势窗口已清空\"}");
}

void handleCalibration() {
  if (!authorize()) return;
  if (!Sensors::requestBlankCalibration()) {
    sendJson(409, "{\"error\":\"光学空白标定正在运行，请等待完成\"}");
    return;
  }
  sendJson(202, "{\"message\":\"空白标定已排队，请保持光路稳定\"}");
}

void handleBlankReset() {
  if (!authorize()) return;
  Sensors::resetBlankCalibration();
  sendJson(200, "{\"message\":\"光学空白已清除\"}");
}

void handlePhCalibration() {
  if (!authorize()) return;
  const String text = server.arg("reference");
  char *end = nullptr;
  const float reference = strtof(text.c_str(), &end);
  if (end == text.c_str() || *end != '\0') {
    sendJson(400, "{\"error\":\"请填写缓冲液的参考 pH\"}");
    return;
  }
  String message;
  const bool ok = PhSensor::captureCalibrationPoint(reference, message);
  sendJson(ok ? 200 : 400, String("{\"") + (ok ? "message" : "error") + "\":\"" + message + "\"}");
}

void handlePhReset() {
  if (!authorize()) return;
  String message;
  const bool ok = PhSensor::resetCalibration(message);
  sendJson(ok ? 200 : 500, String("{\"") + (ok ? "message" : "error") + "\":\"" + message + "\"}");
}

/// 按序号读取 flash 日志（含端点 since）。
/// 返回同一条记录解码后的 JSON 字段，App 用 seq 去重。
void handleReadings() {
  if (!authorize()) return;
  if (!LogStore::ready()) {
    sendJson(503, "{\"error\":\"flash 日志不可用，请检查串口或执行 LOG_FORMAT\"}");
    return;
  }
  const uint32_t oldest = LogStore::oldest();
  const uint32_t next = LogStore::next();
  uint32_t since = oldest;
  uint32_t requested = 0;
  if (argumentUint("since", requested)) since = requested;
  uint32_t limit = 60;
  if (argumentUint("limit", requested)) limit = requested;
  if (limit == 0) limit = 1;
  if (limit > 200) limit = 200; // 一次最多 200 条，避免单个响应过大
  if (since < oldest) since = oldest;
  if (since > next) since = next;
  const uint32_t available = next - since;
  const uint32_t take = available < limit ? available : limit;

  String body;
  body.reserve(take * 96 + 128);
  body += "{\"oldest\":" + String(oldest);
  body += ",\"next\":" + String(next);
  body += ",\"count\":" + String(next - oldest);
  body += ",\"since\":" + String(since);
  body += ",\"records\":[";
  LogRecord record;
  uint32_t written = 0;
  for (uint32_t seq = since; seq < next && written < take; ++seq) {
    if (!LogStore::read(seq, record)) break;
    if (written) body += ',';
    body += "{\"seq\":" + String(record.seq);
    body += ",\"timestamp\":" + String(record.timestamp);
    body += ",\"tempC\":" + String(record.tempC_x100 / 100.0f, 2);
    body += ",\"ph\":" + String(record.ph_x100 / 100.0f, 2);
    body += ",\"od\":" + String(record.od_x1000 / 1000.0f, 3);
    body += ",\"batteryMv\":" + String(record.batteryMv) + "}";
    ++written;
  }
  body += "],\"returned\":" + String(written);
  body += ",\"hasMore\":" + String(since + written < next ? "true" : "false");
  body += "}";
  sendJson(200, body);
}

/// App 确认已落库到 last 后回收该序号及以前的记录。
void handleReadingsCommit() {
  if (!authorize()) return;
  uint32_t last = 0;
  if (!argumentUint("last", last)) {
    sendJson(400, "{\"error\":\"缺少 last 参数\"}");
    return;
  }
  if (!LogStore::ready()) {
    sendJson(503, "{\"error\":\"flash 日志不可用\"}");
    return;
  }
  if (!LogStore::reclaim(last)) {
    sendJson(409, "{\"error\":\"回收失败：序号超出范围或日志不可写\"}");
    return;
  }
  String body = "{\"message\":\"已回收\"";
  body += ",\"oldest\":" + String(LogStore::oldest());
  body += ",\"next\":" + String(LogStore::next());
  body += ",\"count\":" + String(LogStore::count()) + "}";
  sendJson(200, body);
}

/// 手机用自身时钟校准设备（HTTP 版 SET_TIME）。
void handleTime() {
  if (!authorize()) return;
  uint32_t now = 0;
  if (!argumentUint("now", now) || now < 1704067200UL) {
    sendJson(400, "{\"error\":\"now 必须是当前 Unix 秒\"}");
    return;
  }
  timeval tv{};
  tv.tv_sec = static_cast<time_t>(now);
  tv.tv_usec = 0;
  if (settimeofday(&tv, nullptr) != 0) {
    sendJson(500, "{\"error\":\"设备拒绝设置时间\"}");
    return;
  }
  sendJson(200, "{\"message\":\"设备时间已校准\",\"unix\":" + String(now) + "}");
}

void handleWifiConfig() {
  if (!authorize()) return;
  if (!server.hasArg("ssid") || !server.hasArg("password")) {
    sendJson(400, "{\"error\":\"请提供 Wi-Fi 名称和密码字段\"}");
    return;
  }
  String ssid = server.arg("ssid");
  String password = server.arg("password");
  ssid.trim();
  if (ssid.length() == 0 || ssid.length() > 32 || (password.length() > 0 && password.length() < 8)) {
    sendJson(400, "{\"error\":\"Wi-Fi 名称无效；密码须为空或至少 8 个字符\"}");
    return;
  }
  preferences.putString("ssid", ssid);
  preferences.putString("wifipw", password);
  sendJson(200, "{\"message\":\"网络信息已保存，正在连接路由器\"}");
  WiFi.disconnect(false, false);
  WiFi.begin(ssid.c_str(), password.c_str());
  Serial.printf("# Wi-Fi connection requested for SSID: %s\n", ssid.c_str());
}

void reportStationState() {
  const bool connected = WiFi.status() == WL_CONNECTED;
  if (connected && !stationWasConnected) {
    Serial.print("# Router Wi-Fi connected; local address: http://");
    Serial.println(WiFi.localIP());
  } else if (!connected && stationWasConnected) {
    Serial.println("# Router Wi-Fi disconnected; setup hotspot is still available");
  }
  stationWasConnected = connected;
  // 时间戳来自 SNTP：连着路由器时自动校准，手机通过 /api/time 仍可覆盖。
  if (connected && !ntpStarted) {
    configTime(0, 0, MqttConfig::NTP_SERVER_1, MqttConfig::NTP_SERVER_2);
    ntpStarted = true;
    Serial.println("# NTP time sync started");
  }
}
}

namespace FermenterNetwork {
void begin() {
  preferences.begin("fermenter", false);
  webPassword = preferences.getString("webpass", "");
  if (webPassword.length() < 12) {
    webPassword = makePassword();
    preferences.putString("webpass", webPassword);
  }
  String mac = WiFi.macAddress();
  mac.replace(":", "");
  const String suffix = mac.length() >= 6 ? mac.substring(mac.length() - 6) : String("000000");
  setupApSsid = "Fermenter-S3-" + suffix;
  WiFi.setHostname("fermenter-s3");
  WiFi.mode(WIFI_AP_STA);
  WiFi.setAutoReconnect(true);
  const IPAddress apIp(192, 168, 4, 1);
  const IPAddress subnet(255, 255, 255, 0);
  WiFi.softAPConfig(apIp, apIp, subnet);
  if (!WiFi.softAP(setupApSsid.c_str(), webPassword.c_str(), 1, 0, 4))
    Serial.println("# ERROR: could not start the setup access point");

  const String ssid = preferences.getString("ssid", "");
  if (ssid.length() > 0) {
    const String password = preferences.getString("wifipw", "");
    WiFi.begin(ssid.c_str(), password.c_str());
    Serial.printf("# Connecting to saved Wi-Fi: %s\n", ssid.c_str());
  }

  server.on("/", HTTP_GET, []() {
    if (!authorize()) return;
    server.sendHeader("Cache-Control", "no-store");
    server.send_P(200, "text/html; charset=utf-8", WEB_PAGE);
  });
  server.on("/api/status", HTTP_GET, handleStatus);
  server.on("/api/readings", HTTP_GET, handleReadings);
  server.on("/api/readings/commit", HTTP_POST, handleReadingsCommit);
  server.on("/api/time", HTTP_POST, handleTime);
  server.on("/api/control", HTTP_POST, handleControl);
  server.on("/api/reset", HTTP_POST, handleReset);
  server.on("/api/calibrate", HTTP_POST, handleCalibration);
  server.on("/api/blank/reset", HTTP_POST, handleBlankReset);
  server.on("/api/ph/calibrate", HTTP_POST, handlePhCalibration);
  server.on("/api/ph/reset", HTTP_POST, handlePhReset);
  server.on("/api/wifi", HTTP_POST, handleWifiConfig);
  server.onNotFound([]() {
    if (!authorize()) return;
    sendJson(404, "{\"error\":\"未找到该页面\"}");
  });
  server.begin();
  Serial.printf("# Hotspot: SSID=%s password=%s; URL=http://192.168.4.1; web user=admin\n",
                setupApSsid.c_str(), webPassword.c_str());
}

void loop() {
  server.handleClient();
  reportStationState();
}

void resetCredentials() {
  preferences.remove("ssid");
  preferences.remove("wifipw");
  webPassword = makePassword();
  preferences.putString("webpass", webPassword);
  WiFi.disconnect(false, false);
  WiFi.softAPdisconnect(false);
  WiFi.mode(WIFI_AP_STA);
  const IPAddress apIp(192, 168, 4, 1);
  const IPAddress subnet(255, 255, 255, 0);
  WiFi.softAPConfig(apIp, apIp, subnet);
  WiFi.softAP(setupApSsid.c_str(), webPassword.c_str(), 1, 0, 4);
  stationWasConnected = false;
  Serial.printf("# Wi-Fi credentials cleared. AP=%s; password/web login=admin/%s\n",
                setupApSsid.c_str(), webPassword.c_str());
}
}

