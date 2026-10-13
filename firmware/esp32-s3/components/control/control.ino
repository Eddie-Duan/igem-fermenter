// 执行器：搅拌电机（PWM 调速）+ 加热片（继电器/固态继电器通断）。
//
// App 通过 SET_CONTROL 下发 flags/rpm/target_c_x10，这里落到引脚上。
// 温度控制用带滞环的通断（bang-bang）：目标 ±0.3 °C 之间不动作，
// 避免继电器在目标点附近疯狂开关。要更稳就换成 PID，接口不用动。
#include <Arduino.h>
#include "../protocol/protocol.h"

// ===================== 引脚 =====================
#define PIN_STIRRER 5 // 电机驱动 MOSFET 的栅极（PWM）
#define PIN_HEATER 6  // 固态继电器控制脚（HIGH = 加热）

// 搅拌 PWM：20 kHz 超出可听范围，8 位分辨率。
#define STIRRER_PWM_FREQ 20000
#define STIRRER_PWM_BITS 8

// 电机启动电压：占空比低于这个值时直流电机只会嗡嗡响不转。
#define STIRRER_MIN_DUTY 60

// 温度滞环（°C）。
#define HEATER_HYSTERESIS 0.3f

// ===================== 对外接口前置声明 =====================
bool controlInit();
void controlApply(bool stirrerOn, uint16_t rpm, bool heaterOn, float targetC);
void controlTick(float tempC);
bool controlStirrerOn();
uint16_t controlRpm();
bool controlHeaterOn();
float controlTargetC();

// ===================== 内部状态 =====================
static bool s_stirrerOn = false;
static uint16_t s_rpm = 0;
static bool s_heaterOn = false;   // App 是否允许加热
static bool s_heaterEngaged = false; // 继电器当前实际状态
static float s_targetC = 30.0f;

bool controlStirrerOn() { return s_stirrerOn; }
uint16_t controlRpm() { return s_rpm; }
bool controlHeaterOn() { return s_heaterOn; }
float controlTargetC() { return s_targetC; }

/// 转速 → 占空比：100–300 rpm 线性映射到 MIN_DUTY–255。
static uint8_t dutyForRpm(uint16_t rpm)
{
    const float minRpm = 100.0f, maxRpm = 300.0f;
    float value = (float)rpm;
    if (value < minRpm)
        value = minRpm;
    if (value > maxRpm)
        value = maxRpm;
    float ratio = (value - minRpm) / (maxRpm - minRpm);
    return (uint8_t)(STIRRER_MIN_DUTY + ratio * (255 - STIRRER_MIN_DUTY));
}

bool controlInit()
{
    pinMode(PIN_HEATER, OUTPUT);
    digitalWrite(PIN_HEATER, LOW);

    // ESP32 Arduino core 3.x：ledcAttach(pin, freq, resolution)。
    // core 2.x 请改成 ledcSetup(channel, freq, bits) + ledcAttachPin(pin, channel)。
    ledcAttach(PIN_STIRRER, STIRRER_PWM_FREQ, STIRRER_PWM_BITS);
    ledcWrite(PIN_STIRRER, 0);

    Serial.println("执行器就绪（搅拌 PWM + 加热继电器）");
    return true;
}

/// 应用 App 下发的控制状态。
void controlApply(bool stirrerOn, uint16_t rpm, bool heaterOn, float targetC)
{
    s_stirrerOn = stirrerOn;
    s_rpm = rpm;
    s_heaterOn = heaterOn;
    s_targetC = targetC;

    ledcWrite(PIN_STIRRER, stirrerOn ? dutyForRpm(rpm) : 0);

    // 关掉加热时立刻断开，不等滞环。
    if (!heaterOn && s_heaterEngaged)
    {
        s_heaterEngaged = false;
        digitalWrite(PIN_HEATER, LOW);
    }

    Serial.printf("控制更新：搅拌 %s %u rpm（duty %u），加热 %s → %.1f °C\n",
                  stirrerOn ? "开" : "关", (unsigned)rpm,
                  (unsigned)(stirrerOn ? dutyForRpm(rpm) : 0),
                  heaterOn ? "开" : "关", targetC);
}

/// 每个采样周期调一次：按当前温度和滞环决定继电器通断。
void controlTick(float tempC)
{
    if (!s_heaterOn)
        return;

    bool want = s_heaterEngaged;
    if (tempC < s_targetC - HEATER_HYSTERESIS)
        want = true;
    else if (tempC > s_targetC + HEATER_HYSTERESIS)
        want = false;

    if (want != s_heaterEngaged)
    {
        s_heaterEngaged = want;
        digitalWrite(PIN_HEATER, want ? HIGH : LOW);
        Serial.printf("加热 %s（%.2f °C / 目标 %.1f °C）\n",
                      want ? "开" : "关", tempC, s_targetC);
    }
}
