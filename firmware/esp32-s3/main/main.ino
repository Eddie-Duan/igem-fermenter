// iGEM 发酵罐 ESP32-S3 固件示例
//
// 与手机 App 的接口定义在 docs/ble-gatt.md 与 docs/ble-data-format.md，
// 字节级常量在 components/protocol/protocol.h。
//
// 运行逻辑很简单，全部在 loop() 里协作式推进，不用 RTOS 任务：
//   1. 每 SAMPLE_INTERVAL_S 秒采一次温度/pH/浊度/电池 → 追加到 flash 日志；
//   2. 手机连着且没在同步 → 顺手 Notify 一条，App 上的曲线就是实时的；
//   3. 手机发 SYNC_REQ → 按 ACK 节奏把 flash 里的记录逐条补发（见 ble.ino）。
//
// 断开连接不影响采样：数据继续写进 flash，下次连上补齐。
//
// 注意：time.ino 必须最先包含，其他模块要用它提供的 nowUnix()。
#include "../components/time/time.ino"
#include "../components/sensors/sensors.ino"
#include "../components/flash/flash.ino"
#include "../components/control/control.ino"
#include "../components/ble/ble.ino"
#include "../components/protocol/protocol.h"
#include <Arduino.h>

static uint32_t s_nextSampleMs = 0;

/// 采一条、写 flash、在线就顺手推一条。
static void sampleOnce()
{
    float tempC = 0, ph = 0, od = 0;
    uint16_t batteryMv = 0;
    sensorsRead(tempC, ph, od, batteryMv);

    // 用刚采到的温度跑一次加热控制（滞环在 control.ino 里）。
    controlTick(tempC);
    bleSetBatteryMv(batteryMv);

    uint32_t seq = 0;
    if (!flashAppend(tempC, ph, od, batteryMv, seq))
    {
        Serial.println("采样写入失败，本条丢弃");
        return;
    }

    Serial.printf("#%lu  %.2f °C  pH %.2f  OD %.3f  %u mV  (flash %lu 条)\n",
                  (unsigned long)seq, tempC, ph, od, (unsigned)batteryMv,
                  (unsigned long)flashCount());

    // 正在同步时不要抢着发：同步状态机会读到刚写进去的这条，顺序不会乱。
    if (bleDeviceConnected() && !bleIsDraining())
        bleNotifyLiveRecord(seq);
}

void setup()
{
    Serial.begin(115200);
    delay(300);
    Serial.println();
    Serial.println("=== iGEM 发酵罐 · ESP32-S3 固件 ===");

    // ---- 时钟：先恢复 NVS 里的最后已知时间，再等手机 SET_TIME 校准 ----
    restoreTimeFromNVS();
    printTime();

    // ---- 外设 ----
    sensorsInit();
    controlInit();

    // ---- flash 日志 ----
    if (!flashInit())
        Serial.println("flash 日志不可用，采样不会被保存！");

    // ---- BLE ----
    bleInit();

    Serial.printf("采样周期：%d 秒；flash 容量：%d 条；等手机连接…\n",
                  SAMPLE_INTERVAL_S, LOG_CAPACITY);
    Serial.println("串口输入 n 可立刻补采一条（调试用）");

    // 开机 2 秒后先采一条，手机一连上就有东西可同步。
    s_nextSampleMs = millis() + 2000;
}

void loop()
{
    // 蓝牙要每轮都跑：断线重广播、等 ACK 的状态机都在里面。
    bleTick();

    // 串口调试：按 n 立刻采一条，不用等两分钟。
    if (Serial.available())
    {
        char c = Serial.read();
        if (c == 'n' || c == 'N')
            sampleOnce();
    }

    if ((int32_t)(millis() - s_nextSampleMs) >= 0)
    {
        s_nextSampleMs = millis() + (uint32_t)SAMPLE_INTERVAL_S * 1000UL;
        sampleOnce();
    }

    delay(5);
}
