// flash 日志：追加式存储采样记录，按 ACK/COMMIT 回收。
//
// 存储形态：SPIFFS 上一个定长记录文件 `/log.bin`，每条 20 字节（就是 BLE 的
// Notify 帧本身，含 magic/版本/CRC）。因为 seq 连续，第 n 条记录的偏移就是
// `(seq - oldest_seq) * 20`，同步时不需要索引表。
//
// 两个游标存在 NVS 里：
//   oldest_seq —— 文件里第一条记录的序号
//   next_seq   —— 下一条要分配的序号
// 掉电后按文件内容与 NVS 交叉校验，两者对不上时**以文件为准**重新推算。
#include <Arduino.h>
#include <SPIFFS.h>
#include "nvs_flash.h"
#include "nvs.h"
#include "../protocol/protocol.h"

// ===================== 对外接口前置声明 =====================
bool flashInit();
uint32_t flashOldestSeq();
uint32_t flashNextSeq();
uint32_t flashCount();
uint32_t flashCapacity();
bool flashAppend(float tempC, float ph, float od, uint16_t batteryMv, uint32_t &outSeq);
bool flashRead(uint32_t seq, uint8_t *out);
bool flashReclaim(uint32_t lastSeq);
uint32_t nowUnix();

// ===================== 内部状态 =====================
static const char *LOG_PATH = "/log.bin";
static const char *TMP_PATH = "/log.tmp";

static uint32_t s_oldestSeq = 0;
static uint32_t s_nextSeq = 0;
static bool s_metaReady = false;

uint32_t flashOldestSeq() { return s_oldestSeq; }
uint32_t flashNextSeq() { return s_nextSeq; }
uint32_t flashCount() { return s_nextSeq - s_oldestSeq; }
uint32_t flashCapacity() { return LOG_CAPACITY; }

// ===================== NVS 里的两个游标 =====================
static bool ensureNVS()
{
    if (s_metaReady)
        return true;
    // time.ino 可能已经初始化过 NVS，失败再重试一次也没有副作用。
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
    s_metaReady = true;
    return true;
}

static void saveLogMeta()
{
    if (!ensureNVS())
        return;
    nvs_handle_t handle;
    if (nvs_open("log", NVS_READWRITE, &handle) != ESP_OK)
        return;
    nvs_set_u32(handle, "oldest", s_oldestSeq);
    nvs_set_u32(handle, "next", s_nextSeq);
    nvs_commit(handle);
    nvs_close(handle);
}

static bool loadLogMeta(uint32_t &oldest, uint32_t &next)
{
    if (!ensureNVS())
        return false;
    nvs_handle_t handle;
    if (nvs_open("log", NVS_READONLY, &handle) != ESP_OK)
        return false;
    esp_err_t a = nvs_get_u32(handle, "oldest", &oldest);
    esp_err_t b = nvs_get_u32(handle, "next", &next);
    nvs_close(handle);
    return a == ESP_OK && b == ESP_OK;
}

// ===================== 初始化 =====================
/// 读文件里第 index 条记录的 seq；文件没有这条记录时返回 false。
static bool seqAt(uint32_t index, uint32_t &seq)
{
    File file = SPIFFS.open(LOG_PATH, FILE_READ);
    if (!file)
        return false;
    bool ok = file.seek(index * RECORD_SIZE);
    uint8_t buf[RECORD_SIZE];
    LogRecord record;
    if (ok && file.read(buf, RECORD_SIZE) == RECORD_SIZE && recordDecode(buf, record))
    {
        seq = record.seq;
        ok = true;
    }
    else
    {
        ok = false;
    }
    file.close();
    return ok;
}

bool flashInit()
{
    if (!SPIFFS.begin(true))
    {
        Serial.println("SPIFFS 挂载失败");
        return false;
    }

    uint32_t oldest = 0, next = 0;
    bool haveMeta = loadLogMeta(oldest, next);

    File file = SPIFFS.open(LOG_PATH, FILE_READ);
    uint32_t count = file ? file.size() / RECORD_SIZE : 0;
    if (file)
        file.close();

    uint32_t firstSeq = 0, lastSeq = 0;
    // 文件自洽 = 首条可读、末条可读、且条数与序号跨度一致（序号必须连续，
    // 否则"第 n 条偏移 = (seq - oldest) × 20"这条公式就不成立了）。
    bool fileConsistent = count > 0 && seqAt(0, firstSeq) &&
                          seqAt(count - 1, lastSeq) &&
                          lastSeq + 1 - firstSeq == count;

    if (count == 0)
    {
        // 空日志：序号接着 meta 往上，不回退（回退会和 App 已有的最高序号撞车）。
        s_oldestSeq = haveMeta ? next : 0;
        s_nextSeq = s_oldestSeq;
    }
    else if (fileConsistent && haveMeta && firstSeq == oldest && lastSeq + 1 == next)
    {
        s_oldestSeq = oldest;
        s_nextSeq = next;
    }
    else if (fileConsistent)
    {
        // 文件自洽、只是 meta 丢了或过期：按文件重推，序号保持不变。
        s_oldestSeq = firstSeq;
        s_nextSeq = lastSeq + 1;
        Serial.printf("日志元数据不可用，按文件重推：oldest=%lu next=%lu\n",
                      (unsigned long)s_oldestSeq, (unsigned long)s_nextSeq);
        saveLogMeta();
    }
    else
    {
        // 文件本身有坏块或断档：偏移公式不再成立，继续读只会吐出一堆
        // CRC 不过的帧。直接清空，序号从"能读到的最大序号 + 1"往后排，
        // App 那边的游标仍然有效（只会少一段设备侧历史，不会错位）。
        uint32_t restart = haveMeta ? next : lastSeq + 1;
        Serial.printf("日志文件损坏，清空重来（新序号起点 %lu）\n",
                      (unsigned long)restart);
        SPIFFS.remove(LOG_PATH);
        s_oldestSeq = restart;
        s_nextSeq = restart;
        saveLogMeta();
    }

    Serial.printf("flash 日志就绪：%lu 条（seq %lu…%lu），容量 %d\n",
                  (unsigned long)flashCount(), (unsigned long)s_oldestSeq,
                  (unsigned long)s_nextSeq, LOG_CAPACITY);
    return true;
}

// ===================== 重写（回收 / 丢最旧） =====================
// 保留 seq >= keepFromSeq 的记录，并且最多从最前面丢掉 maxDrop 条
// （maxDrop < 0 表示不限）。SPIFFS 没有"从中间删一段"的能力，
// 只能整体重写到临时文件再替换 —— 2000 条 = 40 KB，几毫秒的事。
static bool flashRewrite(uint32_t keepFromSeq, int32_t maxDrop)
{
    File in = SPIFFS.open(LOG_PATH, FILE_READ);
    if (!in)
    {
        Serial.println("打开日志失败，跳过重写");
        return false;
    }

    File out = SPIFFS.open(TMP_PATH, FILE_WRITE);
    if (!out)
    {
        in.close();
        Serial.println("打开临时文件失败，跳过重写");
        return false;
    }

    uint8_t buf[RECORD_SIZE];
    uint32_t dropped = 0;
    uint32_t kept = 0;
    uint32_t firstKeptSeq = 0;
    bool failed = false;

    while (in.available() >= RECORD_SIZE)
    {
        if (in.read(buf, RECORD_SIZE) != RECORD_SIZE)
            break;
        LogRecord record;
        if (!recordDecode(buf, record))
            continue; // 坏记录直接丢掉（CRC 已经判定它不可信）

        bool drop = record.seq < keepFromSeq ||
                    (maxDrop >= 0 && (int32_t)dropped < maxDrop);
        if (drop)
        {
            dropped++;
            continue;
        }

        if (out.write(buf, RECORD_SIZE) != RECORD_SIZE)
        {
            failed = true;
            break;
        }
        if (kept == 0)
            firstKeptSeq = record.seq;
        kept++;
    }

    in.close();
    out.close();

    if (failed)
    {
        SPIFFS.remove(TMP_PATH);
        Serial.println("重写日志失败，保留原文件");
        return false;
    }

    SPIFFS.remove(LOG_PATH);
    if (!SPIFFS.rename(TMP_PATH, LOG_PATH))
    {
        Serial.println("替换日志文件失败");
        return false;
    }

    // 一条不剩时 oldest 推进到 next：此时 count = 0，偏移公式依然成立。
    s_oldestSeq = kept > 0 ? firstKeptSeq : s_nextSeq;
    saveLogMeta();
    Serial.printf("日志重写完成：丢掉 %lu 条，保留 %lu 条\n",
                  (unsigned long)dropped, (unsigned long)kept);
    return true;
}

/// COMMIT：手机已确认落库到 lastSeq，回收它及以前的记录。
bool flashReclaim(uint32_t lastSeq)
{
    if (lastSeq == 0xFFFFFFFFu)
    {
        // 手机侧"什么都没确认"时的防呆：不允许清空整段日志。
        Serial.println("COMMIT 参数异常，忽略");
        return false;
    }
    if (flashCount() == 0 || lastSeq + 1 <= s_oldestSeq)
        return true; // 没有可回收的
    return flashRewrite(lastSeq + 1, -1);
}

// ===================== 追加与读取 =====================
bool flashAppend(float tempC, float ph, float od, uint16_t batteryMv, uint32_t &outSeq)
{
    // 满了就丢最旧的一条：新数据比旧数据重要，App 那边已经有旧数据的副本。
    if (flashCount() >= LOG_CAPACITY && !flashRewrite(0, 1))
        return false;

    LogRecord record = makeRecord(s_nextSeq, nowUnix(), tempC, ph, od, batteryMv);
    uint8_t buf[RECORD_SIZE];
    recordEncode(record, buf);

    File file = SPIFFS.open(LOG_PATH, FILE_APPEND);
    if (!file)
    {
        Serial.println("打开日志失败，采样丢失");
        return false;
    }
    size_t written = file.write(buf, RECORD_SIZE);
    file.close();
    if (written != RECORD_SIZE)
    {
        Serial.println("写日志失败，采样丢失");
        return false;
    }

    if (flashCount() == 0)
        s_oldestSeq = s_nextSeq;
    outSeq = s_nextSeq;
    s_nextSeq++;
    saveLogMeta();
    return true;
}

/// 读第 seq 条记录的原始 20 字节（已确认 magic/版本/CRC 都对）。
bool flashRead(uint32_t seq, uint8_t *out)
{
    if (seq < s_oldestSeq || seq >= s_nextSeq)
        return false;

    File file = SPIFFS.open(LOG_PATH, FILE_READ);
    if (!file)
        return false;

    bool ok = false;
    if (file.seek((seq - s_oldestSeq) * RECORD_SIZE) &&
        file.read(out, RECORD_SIZE) == RECORD_SIZE)
    {
        LogRecord record;
        ok = recordDecode(out, record) && record.seq == seq;
    }
    file.close();
    return ok;
}
