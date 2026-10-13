// 设备时钟：手机通过 SET_TIME 帧校准，断电前把"最后已知时间"存进 NVS。
//
// 记录里的 timestamp 是 Unix 秒。没有校准过就写 0，App 会拿手机时间占位；
// 真正的时间轴用的是 seq × 采样周期，所以没校时也不影响曲线。
#include <Arduino.h>
#include <time.h>
#include <sys/time.h>
#include "nvs_flash.h"
#include "nvs.h"

// ===================== 对外接口前置声明 =====================
// （这些 .ino 文件是被 #include 拼进 main.ino 的，Arduino 不会自动生成原型）
void setManualTime(int year, int month, int day, int hour, int minute, int second);
bool setTimeFromUnix(uint32_t ts);
void saveTimeToNVS();
void restoreTimeFromNVS();
void printTime();
bool isTimeValid();
uint32_t nowUnix();

// ===================== 内部状态 =====================
static bool s_timeValid = false;

bool isTimeValid() { return s_timeValid; }

/// 当前 Unix 秒；未校时返回 0（记录里就用 0 表示"时间未知"）。
uint32_t nowUnix()
{
    if (!s_timeValid)
        return 0;
    return (uint32_t)time(nullptr);
}

static void applyTime(time_t t)
{
    struct timeval now = {};
    now.tv_sec = t;
    now.tv_usec = 0;
    settimeofday(&now, nullptr);
    s_timeValid = true;
}

/// 手动设一个时间，仅用于串口调试（正式路径是手机下发 SET_TIME）。
void setManualTime(int year, int month, int day, int hour, int minute, int second)
{
    struct tm timeinfo = {};
    timeinfo.tm_year = year - 1900;
    timeinfo.tm_mon = month - 1;
    timeinfo.tm_mday = day;
    timeinfo.tm_hour = hour;
    timeinfo.tm_min = minute;
    timeinfo.tm_sec = second;
    applyTime(mktime(&timeinfo));
}

/// SET_TIME 帧：0x03 + Unix 秒（uint32 小端）。
/// 2000-01-01 之前的时间戳一律当作没校好——手机时钟错乱时别把设备带偏。
bool setTimeFromUnix(uint32_t ts)
{
    if (ts < 946684800u)
    {
        Serial.println("SET_TIME: 时间戳早于 2000-01-01，忽略");
        return false;
    }

    applyTime((time_t)ts);
    saveTimeToNVS();
    Serial.print("时间已校准：");
    printTime();
    return true;
}

// ===================== NVS 持久化 =====================
// ESP32-S3 上电后 RTC 计时器会重置，所以每次校准都要落 NVS，
// 冷启动时恢复到"最后已知时间"（断电期间走时丢失，只能偏慢，不会倒退）。
static bool s_nvsReady = false;

static bool ensureNVSReady()
{
    if (s_nvsReady)
        return true;
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND)
    {
        nvs_flash_erase();
        err = nvs_flash_init();
    }
    if (err != ESP_OK)
    {
        Serial.printf("NVS 初始化失败: %d\n", err);
        return false;
    }
    s_nvsReady = true;
    return true;
}

void saveTimeToNVS()
{
    if (!ensureNVSReady() || !s_timeValid)
        return;

    nvs_handle_t handle;
    if (nvs_open("rtc", NVS_READWRITE, &handle) != ESP_OK)
        return;

    time_t now = time(nullptr);
    nvs_set_u32(handle, "tlo", (uint32_t)((uint64_t)now & 0xFFFFFFFFULL));
    nvs_set_u32(handle, "thi", (uint32_t)((uint64_t)now >> 32));
    nvs_set_u32(handle, "tvalid", 1);
    nvs_commit(handle);
    nvs_close(handle);
}

void restoreTimeFromNVS()
{
    s_timeValid = false;

    if (!ensureNVSReady())
        return;

    nvs_handle_t handle;
    if (nvs_open("rtc", NVS_READONLY, &handle) != ESP_OK)
        return;

    uint32_t hi = 0, lo = 0, valid = 0;
    nvs_get_u32(handle, "thi", &hi);
    nvs_get_u32(handle, "tlo", &lo);
    nvs_get_u32(handle, "tvalid", &valid);
    nvs_close(handle);

    if (!valid)
        return;

    applyTime((time_t)(((int64_t)hi << 32) | lo));
    Serial.println("时钟已从 NVS 恢复（断电期间走时丢失，可能偏慢，等手机校准）");
}

void printTime()
{
    if (!s_timeValid)
    {
        Serial.println("时间未校准（timestamp 会写 0）");
        return;
    }
    time_t now = time(nullptr);
    struct tm timeinfo;
    localtime_r(&now, &timeinfo);
    Serial.printf("%04d-%02d-%02d %02d:%02d:%02d\n",
                  timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
                  timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);
}
