// BLE GATT Server：设备信息、记录 Notify、指令写入、同步状态。
//
// 字节级格式全在 ../protocol/protocol.h，本文件只负责"什么时候发哪一帧"。
// 同步的核心规则只有一条：**手机 ACK 过哪条，设备才敢回收哪条**
// （回收动作由手机发 COMMIT 触发，见 flash.ino 的 flashReclaim）。
//
// 发送采用状态机而不是阻塞等待：loop() 要同时跑采样和蓝牙，
// 卡在 delay 里等 ACK 会让采样整段丢掉。
#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_mac.h>
#include "../protocol/protocol.h"

// 等 ACK 的时限：超时就当作手机暂时不可用，结束本轮，记录留在 flash 里下次重发。
#define ACK_TIMEOUT_MS 5000UL
// 连接后延迟这么久再推 LOG_STATUS，让手机有时间完成服务发现和 CCCD 订阅。
#define LOG_STATUS_DELAY_MS 800UL

// ===================== 对外接口前置声明 =====================
bool bleInit();
void bleTick();
void bleNotifyLiveRecord(uint32_t seq);
void bleSetBatteryMv(uint16_t mv);
bool bleDeviceConnected();
bool bleIsDraining();
// 来自其他模块
uint32_t flashOldestSeq();
uint32_t flashNextSeq();
uint32_t flashCount();
bool flashRead(uint32_t seq, uint8_t *out);
bool flashReclaim(uint32_t lastSeq);
bool setTimeFromUnix(uint32_t ts);
void controlApply(bool stirrerOn, uint16_t rpm, bool heaterOn, float targetC);
bool controlStirrerOn();
uint16_t controlRpm();
bool controlHeaterOn();
float controlTargetC();

// ===================== 内部状态 =====================
static BLEServer *s_server = nullptr;
static BLECharacteristic *s_infoChar = nullptr;
static BLECharacteristic *s_dataChar = nullptr;
static BLECharacteristic *s_controlChar = nullptr;
static BLECharacteristic *s_statusChar = nullptr;

static volatile bool s_connected = false;
static bool s_oldConnected = false;

static uint16_t s_batteryMv = 0;

// 同步状态机
enum DrainState
{
    DRAIN_IDLE,
    DRAIN_SENDING,
    DRAIN_WAIT_ACK,
};
static DrainState s_drain = DRAIN_IDLE;
static uint32_t s_cursor = 0;      // 下一条要发的 seq
static uint32_t s_waitingSeq = 0;  // 已经发出去、正等 ACK 的那条
static uint32_t s_ackSeq = 0;      // 手机确认到的最大 seq
static uint32_t s_ackDeadline = 0; // 等 ACK 的截止时刻

static bool s_logStatusPending = false;
static uint32_t s_logStatusDueMs = 0;

bool bleIsDraining() { return s_drain != DRAIN_IDLE; }

bool bleDeviceConnected() { return s_connected; }
void bleSetBatteryMv(uint16_t mv) { s_batteryMv = mv; }

// ===================== 状态帧 =====================
static void notifyStatus(const uint8_t *payload, size_t length)
{
    if (!s_connected)
        return;
    s_statusChar->setValue((uint8_t *)payload, length);
    s_statusChar->notify();
}

static void bleNotifySyncEnd(uint32_t nextSeq)
{
    uint8_t frame[5];
    frame[0] = ST_SYNC_END;
    wrU32(frame + 1, nextSeq);
    notifyStatus(frame, sizeof(frame));
    Serial.printf("SYNC_END(next_seq=%lu)\n", (unsigned long)nextSeq);
}

static void bleNotifyError(uint8_t code)
{
    uint8_t frame[2] = {ST_ERROR, code};
    notifyStatus(frame, sizeof(frame));
    Serial.printf("ERROR(code=0x%02X)\n", code);
}

void bleNotifyLogStatus()
{
    uint8_t frame[9];
    frame[0] = ST_LOG_STATUS;
    wrU32(frame + 1, flashOldestSeq());
    wrU32(frame + 5, flashCount());
    notifyStatus(frame, sizeof(frame));
    Serial.printf("LOG_STATUS(oldest=%lu count=%lu)\n",
                  (unsigned long)flashOldestSeq(), (unsigned long)flashCount());
}

/// 把 flash 里的第 seq 条记录 Notify 出去（原始 20 字节，手机直接解）。
void bleNotifyLiveRecord(uint32_t seq)
{
    if (!s_connected)
        return;
    uint8_t frame[RECORD_SIZE];
    if (!flashRead(seq, frame))
        return;
    s_dataChar->setValue(frame, RECORD_SIZE);
    s_dataChar->notify();
}

// ===================== 设备信息 =====================
/// 16 字节：固件版本(u32) + MAC(6) + 电池 mV(u16) + 日志容量(u32)。
static void refreshDeviceInfo()
{
    uint8_t frame[16];
    uint8_t mac[6] = {0};
    // 用蓝牙 MAC：App 侧显示设备标识，也是去重键 `device_id + seq` 的来源。
    // 每台板子的 MAC 都不一样，且每次上电保持不变。
    esp_read_mac(mac, ESP_MAC_BT);

    wrU32(frame, FIRMWARE_VERSION);
    memcpy(frame + 4, mac, 6);
    wrU16(frame + 10, s_batteryMv);
    wrU32(frame + 12, flashCapacity());
    s_infoChar->setValue(frame, sizeof(frame));
}

// ===================== 回调 =====================
class ServerCallbacks : public BLEServerCallbacks
{
    void onConnect(BLEServer *server) override
    {
        s_connected = true;
        s_drain = DRAIN_IDLE;
        Serial.println("手机已连接，等它订阅特征值");

        // 订阅完成后通知的 CCCD 还没写过来，直接 notify 会被丢掉；
        // 所以先记一个待办，过 LOG_STATUS_DELAY_MS 再发（见 bleTick）。
        s_logStatusPending = true;
        s_logStatusDueMs = millis() + LOG_STATUS_DELAY_MS;
    }

    void onDisconnect(BLEServer *server) override
    {
        s_connected = false;
        s_drain = DRAIN_IDLE;
        Serial.println("手机已断开，继续采样写 flash");
    }
};

class InfoCallbacks : public BLECharacteristicCallbacks
{
    // 手机每次 Read 之前刷新一遍，保证电池电压是当前的。
    void onRead(BLECharacteristic *characteristic) override
    {
        refreshDeviceInfo();
    }
};

class ControlCallbacks : public BLECharacteristicCallbacks
{
    void onWrite(BLECharacteristic *characteristic) override
    {
        // 用 getData()/getLength() 而不是 getValue()：指令里会出现 0x00 字节
        // （时间戳低位），String 虽然能带住长度，但读原始缓冲更不容易出错。
        const uint8_t *data = characteristic->getData();
        size_t length = characteristic->getLength();
        if (data == nullptr || length == 0)
            return;

        switch (data[0])
        {
        case CMD_SYNC_REQ:
        {
            if (length != 5)
            {
                bleNotifyError(ERR_BAD_FRAME);
                return;
            }
            uint32_t nextSeq = rdU32(data + 1);
            if (nextSeq > flashNextSeq())
            {
                // 手机要的序号超出设备现有范围（比如设备日志被清过）：
                // 明确报错，别假装同步成功。
                Serial.printf("SYNC_REQ(%lu) 超出范围（设备 next=%lu）\n",
                              (unsigned long)nextSeq, (unsigned long)flashNextSeq());
                bleNotifyError(ERR_BAD_SEQUENCE);
                return;
            }
            // 已经被回收的旧序号：从现有的最旧一条开始给。
            s_cursor = nextSeq < flashOldestSeq() ? flashOldestSeq() : nextSeq;
            s_ackSeq = s_cursor; // 起点以下视为已确认，不然状态机会立刻超时
            s_drain = DRAIN_SENDING;
            // 顺手把存储状态再推一次，App 不用等同步跑完就知道还剩多少。
            bleNotifyLogStatus();
            Serial.printf("收到 SYNC_REQ，从 seq=%lu 开始发\n", (unsigned long)s_cursor);
            break;
        }
        case CMD_ACK:
        {
            if (length != 5)
            {
                bleNotifyError(ERR_BAD_FRAME);
                return;
            }
            uint32_t seq = rdU32(data + 1);
            if (seq > s_ackSeq)
                s_ackSeq = seq;
            break;
        }
        case CMD_SET_TIME:
        {
            if (length != 5 || !setTimeFromUnix(rdU32(data + 1)))
                bleNotifyError(ERR_INVALID_ARG);
            break;
        }
        case CMD_COMMIT:
        {
            if (length != 5)
            {
                bleNotifyError(ERR_BAD_FRAME);
                return;
            }
            uint32_t lastSeq = rdU32(data + 1);
            // 只有手机确认过的部分才允许回收；手机给的数超过 ACK 水位就按水位来。
            if (lastSeq > s_ackSeq)
                lastSeq = s_ackSeq;
            if (!flashReclaim(lastSeq))
                bleNotifyError(ERR_FLASH_FAILURE);
            bleNotifyLogStatus();
            break;
        }
        case CMD_SET_CONTROL:
        {
            if (length != 6)
            {
                bleNotifyError(ERR_BAD_FRAME);
                return;
            }
            uint8_t flags = data[1];
            uint16_t rpm = rdU16(data + 2);
            float targetC = rdU16(data + 4) / 10.0f;
            controlApply((flags & CTRL_FLAG_STIRRER) != 0, rpm,
                         (flags & CTRL_FLAG_HEATER) != 0, targetC);
            break;
        }
        default:
            Serial.printf("未知指令 0x%02X（长度 %u）\n", data[0], (unsigned)length);
            bleNotifyError(ERR_INVALID_ARG);
            break;
        }
    }
};

// ===================== 初始化 =====================
bool bleInit()
{
    BLEDevice::init(BLE_DEVICE_NAME);
    s_server = BLEDevice::createServer();
    s_server->setCallbacks(new ServerCallbacks());

    BLEService *service = s_server->createService(BLE_SERVICE_UUID);

    s_infoChar = service->createCharacteristic(
        BLE_CHAR_DEVICE_INFO, BLECharacteristic::PROPERTY_READ);
    s_infoChar->setCallbacks(new InfoCallbacks());

    s_dataChar = service->createCharacteristic(
        BLE_CHAR_SENSOR_DATA, BLECharacteristic::PROPERTY_NOTIFY);
    s_dataChar->addDescriptor(new BLE2902()); // Notify 必须有 CCCD

    s_controlChar = service->createCharacteristic(
        BLE_CHAR_SYNC_CONTROL, BLECharacteristic::PROPERTY_WRITE);
    s_controlChar->setCallbacks(new ControlCallbacks());

    s_statusChar = service->createCharacteristic(
        BLE_CHAR_SYNC_STATUS, BLECharacteristic::PROPERTY_NOTIFY);
    s_statusChar->addDescriptor(new BLE2902());

    service->start();

    BLEAdvertising *advertising = BLEDevice::getAdvertising();
    advertising->addServiceUUID(BLE_SERVICE_UUID);
    advertising->setScanResponse(true);
    // 让手机扫描时能立刻按服务 UUID 过滤出这台设备。
    BLEDevice::startAdvertising();

    Serial.printf("BLE 就绪，广播名 %s\n", BLE_DEVICE_NAME);
    return true;
}

// ===================== 每个循环调一次 =====================
void bleTick()
{
    // ---- 断开后重新广播，否则手机再也搜不到 ----
    if (!s_connected && s_oldConnected)
    {
        delay(50);
        BLEDevice::startAdvertising();
        s_oldConnected = false;
        Serial.println("重新开始广播");
    }
    if (s_connected && !s_oldConnected)
        s_oldConnected = true;

    // ---- 连接后补推一次存储状态 ----
    if (s_logStatusPending && s_connected &&
        (int32_t)(millis() - s_logStatusDueMs) >= 0)
    {
        s_logStatusPending = false;
        bleNotifyLogStatus();
    }

    // ---- 同步状态机 ----
    if (s_drain == DRAIN_WAIT_ACK)
    {
        if (s_ackSeq >= s_waitingSeq)
        {
            s_cursor = s_waitingSeq + 1;
            s_drain = DRAIN_SENDING;
        }
        else if ((int32_t)(millis() - s_ackDeadline) >= 0)
        {
            // 手机没确认：这条不推进游标，留在 flash 里等下次同步重发。
            Serial.printf("等 ACK 超时（seq=%lu），本轮结束\n",
                          (unsigned long)s_waitingSeq);
            bleNotifySyncEnd(s_cursor);
            s_drain = DRAIN_IDLE;
        }
    }

    if (s_drain == DRAIN_SENDING)
    {
        if (!s_connected)
        {
            s_drain = DRAIN_IDLE;
            return;
        }

        // 每轮都重新问一遍：采样刚写进来的记录（甚至本轮之后新增的）
        // 都能在这次同步里发出去，不必等下一轮。
        uint32_t oldest = flashOldestSeq();
        if (s_cursor < oldest)
            s_cursor = oldest;
        if (s_cursor >= flashNextSeq())
        {
            bleNotifySyncEnd(s_cursor);
            s_drain = DRAIN_IDLE;
            return;
        }

        uint8_t frame[RECORD_SIZE];
        if (!flashRead(s_cursor, frame))
        {
            // 读不出来就别发了：手机收到坏帧也不会 ACK，只会把整轮拖死。
            Serial.printf("读取 seq=%lu 失败，结束本轮\n", (unsigned long)s_cursor);
            bleNotifyError(ERR_FLASH_FAILURE);
            bleNotifySyncEnd(s_cursor);
            s_drain = DRAIN_IDLE;
            return;
        }

        s_dataChar->setValue(frame, RECORD_SIZE);
        s_dataChar->notify();
        s_waitingSeq = s_cursor;
        s_ackDeadline = millis() + ACK_TIMEOUT_MS;
        s_drain = DRAIN_WAIT_ACK;
    }
}
