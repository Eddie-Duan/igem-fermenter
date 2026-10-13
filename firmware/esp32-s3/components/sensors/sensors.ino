// 传感器：DS18B20 温度、PH-4502C 模拟 pH、TSL2591 浊度（OD600 近似）、电池电压。
//
// 引脚见 README.md。三个读数都做了简单的一阶平滑（EMA），
// 因为 App 那边的曲线是"趋势判断"（峰值 → 下降 = 收获信号），
// 单点噪声会让收获检测提前触发。
//
// ⚠️ pH 与 OD 的换算系数是**示例值**，必须按自己的电极/光路标定后再用，
// 见 README「标定」一节。
#include <Arduino.h>
#include <Wire.h>
#include <OneWire.h>
#include <DallasTemperature.h>
#include <Adafruit_TSL2591.h>
#include "../protocol/protocol.h"

// ===================== 引脚 =====================
#define PIN_PH 1        // ADC1_CH0：PH-4502C 的 Po
#define PIN_BATTERY 2   // ADC1_CH1：电池分压中点
#define PIN_ONEWIRE 4   // DS18B20 数据线（需要 4.7 kΩ 上拉到 3V3）
#define PIN_I2C_SDA 8   // TSL2591
#define PIN_I2C_SCL 9

// 电池分压比：R1 上、R2 下，中点接 PIN_BATTERY。100k/100k → 倍率 2。
#define BATTERY_DIVIDER 2.0f

// ===================== 标定系数（示例值，务必自己标一遍）=====================
// pH：两点标定。用 pH 7.00 和 pH 4.00 的缓冲液各测一次，算出斜率。
#define PH_MV_AT_7 1500.0f      // pH 7.00 时 Po 脚的毫伏读数
#define PH_MV_PER_PH 59.16f     // 每 1 个 pH 单位对应的毫伏（25 °C 理论值）

// OD600：用"空白培养基"的原始计数做基准，OD = K × log10(blank / raw)。
#define OD_BLANK_RAW 3800.0f
#define OD_K 1.0f

// EMA 平滑系数（0…1，越大越跟手）。
#define EMA_ALPHA 0.35f

// ===================== 对外接口前置声明 =====================
bool sensorsInit();
bool sensorsRead(float &tempC, float &ph, float &od, uint16_t &batteryMv);

// ===================== 内部状态 =====================
static OneWire s_oneWire(PIN_ONEWIRE);
static DallasTemperature s_tempSensor(&s_oneWire);
static Adafruit_TSL2591 s_light(2591);

static bool s_lightReady = false;
static bool s_tempReady = false;
static bool s_emaReady = false;
static float s_emaTemp = 0, s_emaPh = 0, s_emaOd = 0;

bool sensorsInit()
{
    // ---- DS18B20 ----
    s_tempSensor.begin();
    s_tempReady = s_tempSensor.getDeviceCount() > 0;
    if (s_tempReady)
        s_tempSensor.setResolution(12); // 0.0625 °C，转换约 750 ms
    Serial.printf("DS18B20：%s\n", s_tempReady ? "就绪" : "没有找到（检查 4.7k 上拉）");

    // ---- TSL2591 ----
    Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
    s_lightReady = s_light.begin(&Wire);
    if (s_lightReady)
    {
        s_light.setGain(TSL2591_GAIN_MED);
        s_light.setTiming(TSL2591_INTEGRATIONTIME_300MS);
        Serial.println("TSL2591：就绪");
    }
    else
    {
        Serial.println("TSL2591：没有找到（检查 I2C 接线与地址 0x29）");
    }

    // ---- ADC ----
    analogReadResolution(12);
    // 11 dB 衰减 → 约 0…3.1 V 量程；pH 变送器输出不要超过 3.1 V。
    analogSetPinAttenuation(PIN_PH, ADC_11db);
    analogSetPinAttenuation(PIN_BATTERY, ADC_11db);
    return true;
}

/// 读一次温度（°C）。传感器缺失时返回上一次的值（首帧返回 25）。
static float readTemperature()
{
    if (!s_tempReady)
        return s_emaReady ? s_emaTemp : 25.0f;

    s_tempSensor.requestTemperatures();
    float value = s_tempSensor.getTempCByIndex(0);
    // DEVICE_DISCONNECTED_C (-127) 表示读失败，别把它当成真实温度。
    if (value <= -100.0f || value > 100.0f)
        return s_emaReady ? s_emaTemp : 25.0f;
    return value;
}

/// 读一次 pH（由变送器毫伏换算）。
static float readPh()
{
    float mv = analogReadMilliVolts(PIN_PH);
    float value = 7.0f + (PH_MV_AT_7 - mv) / PH_MV_PER_PH;
    // 允许的物理范围之外一律当噪声丢掉。
    if (value < 0.0f || value > 14.0f)
        return s_emaReady ? s_emaPh : 7.0f;
    return value;
}

/// 读一次 OD600（由透光计数换算的近似值）。
static float readOd()
{
    if (!s_lightReady)
        return s_emaReady ? s_emaOd : 0.0f;

    float raw = (float)s_light.getLuminosity(TSL2591_FULLSPECTRUM);
    if (raw <= 1.0f)
        return s_emaReady ? s_emaOd : 0.0f; // 全黑或被遮挡：当无效值

    float od = OD_K * log10f(OD_BLANK_RAW / raw);
    if (od < 0.0f)
        od = 0.0f; // 比空白还透亮（稀释了）也按 0 处理
    return od;
}

static uint16_t readBatteryMv()
{
    float mv = analogReadMilliVolts(PIN_BATTERY) * BATTERY_DIVIDER;
    return clampToUint16(mv);
}

bool sensorsRead(float &tempC, float &ph, float &od, uint16_t &batteryMv)
{
    float rawTemp = readTemperature();
    float rawPh = readPh();
    float rawOd = readOd();

    if (!s_emaReady)
    {
        s_emaTemp = rawTemp;
        s_emaPh = rawPh;
        s_emaOd = rawOd;
        s_emaReady = true;
    }
    else
    {
        s_emaTemp += EMA_ALPHA * (rawTemp - s_emaTemp);
        s_emaPh += EMA_ALPHA * (rawPh - s_emaPh);
        s_emaOd += EMA_ALPHA * (rawOd - s_emaOd);
    }

    tempC = s_emaTemp;
    ph = s_emaPh;
    od = s_emaOd;
    batteryMv = readBatteryMv();
    // 单个传感器缺失不算失败：缺的那路会用上一次的值继续跑。
    return true;
}
