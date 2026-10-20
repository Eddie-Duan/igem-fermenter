#include "./ble_log.h"
#include "../control/control_manager.h"
#include <SPIFFS.h>
#include <limits.h>

namespace {
constexpr size_t HEADER_SIZE = 24;
constexpr uint32_t LOG_MAGIC = 0x324c4246; // FBL2
const char *paths[] = {"/fermenter-ble-a.bin", "/fermenter-ble-b.bin"};
bool available = false;
uint8_t active = 0;
uint32_t generation = 0, first = 0, nextSeq = 0;
struct Candidate {
  bool headerValid = false;
  bool valid = false;
  bool tailDamaged = false;
  uint32_t generation = 0, first = 0, count = 0;
};

Candidate inspect(uint8_t index) {
  Candidate c;
  File f = SPIFFS.open(paths[index], FILE_READ);
  uint8_t header[HEADER_SIZE];
  if (!f || f.read(header, sizeof(header)) != sizeof(header) ||
      rdU32(header) != LOG_MAGIC || rdU16(header + 22) != crc16Ccitt(header, 22)) return c;
  c.headerValid = true;
  c.generation = rdU32(header + 4);
  c.first = rdU32(header + 8);
  const uint32_t seedCount = rdU32(header + 12);
  if (seedCount > LOG_CAPACITY) return c;
  uint8_t frame[RECORD_SIZE];
  LogRecord record;
  while (f.available() >= RECORD_SIZE && c.count < LOG_CAPACITY) {
    if (f.read(frame, sizeof(frame)) != sizeof(frame) || !recordDecode(frame, record) ||
        uint64_t(c.first) + c.count >= UINT32_MAX || record.seq != c.first + c.count) {
      c.tailDamaged = true;
      break;
    }
    ++c.count;
    Controller::updateTemperatureControl();
  }
  c.tailDamaged = c.tailDamaged || f.position() != f.size();
  // A rewrite is committed only if ALL seed records are durable and readable.
  c.valid = c.count >= seedCount && !c.tailDamaged;
  return c;
}

bool replaceLog(uint32_t keepFrom) {
  const uint8_t target = 1 - active;
  const uint32_t kept = nextSeq - keepFrom;
  if (generation == UINT32_MAX || kept > LOG_CAPACITY) return false;
  File out = SPIFFS.open(paths[target], FILE_WRITE);
  if (!out) return false;
  uint8_t header[HEADER_SIZE] = {};
  if (out.write(header, sizeof(header)) != sizeof(header)) return false;
  File in;
  if (kept) {
    in = SPIFFS.open(paths[active], FILE_READ);
    if (!in || !in.seek(HEADER_SIZE + (keepFrom - first) * RECORD_SIZE)) return false;
  }
  uint8_t frame[RECORD_SIZE];
  LogRecord r;
  for (uint32_t i = 0; i < kept; ++i) {
    if (in.read(frame, sizeof(frame)) != sizeof(frame) || !recordDecode(frame, r) ||
        r.seq != keepFrom + i || out.write(frame, sizeof(frame)) != sizeof(frame)) return false;
    Controller::updateTemperatureControl();
  }
  out.flush();
  wrU32(header, LOG_MAGIC);
  wrU32(header + 4, generation + 1);
  wrU32(header + 8, keepFrom);
  wrU32(header + 12, kept);
  wrU16(header + 22, crc16Ccitt(header, 22));
  // Header last: power loss during copying leaves the previous file authoritative.
  if (!out.seek(0) || out.write(header, sizeof(header)) != sizeof(header)) return false;
  out.flush();
  out.close();
  const Candidate saved = inspect(target);
  if (!saved.valid || saved.tailDamaged || saved.first != keepFrom || saved.count != kept) return false;
  active = target;
  generation = saved.generation;
  first = keepFrom;
  return true;
}
}

namespace BleLog {
bool begin() {
  available = false;
  // Never automatically format a damaged/unformatted filesystem.
  if (!SPIFFS.begin(false)) {
    Serial.println("# BLE log filesystem unavailable; with heating disabled use BLE_FORMAT once for a new board");
    return false;
  }
  const Candidate a = inspect(0), b = inspect(1);
  // Never roll back an already committed generation: that could reuse sequence
  // numbers that the phone has stored. Preserve damaged files for recovery.
  const Candidate latest = b.headerValid && (!a.headerValid || b.generation > a.generation) ? b : a;
  if (latest.headerValid && !latest.valid) {
    Serial.println("# BLE committed log damaged; refusing rollback or sequence reuse");
    return false;
  }
  if (!a.valid && !b.valid) {
    if (SPIFFS.exists(paths[0]) || SPIFFS.exists(paths[1])) {
      Serial.println("# BLE logs damaged; originals retained. Export/recover before BLE_FORMAT");
      return false;
    }
    active = 1;
    generation = first = nextSeq = 0;
    available = replaceLog(0);
  } else {
    active = b.valid && (!a.valid || b.generation > a.generation) ? 1 : 0;
    const Candidate c = active ? b : a;
    generation = c.generation;
    first = c.first;
    nextSeq = first + c.count;
    available = !c.tailDamaged || replaceLog(first);
  }
  Serial.printf("# BLE log ready=%u oldest=%lu next=%lu count=%lu\n", available,
      (unsigned long)first, (unsigned long)nextSeq, (unsigned long)count());
  return available;
}
bool format() {
  available = false;
  SPIFFS.end();
  if (!SPIFFS.format()) return false;
  return begin();
}
bool ready() { return available; }
uint32_t oldest() { return first; }
uint32_t next() { return nextSeq; }
uint32_t count() { return nextSeq - first; }
bool read(uint32_t seq, uint8_t *frame) {
  if (!available || seq < first || seq >= nextSeq) return false;
  File f = SPIFFS.open(paths[active], FILE_READ);
  LogRecord r;
  return f && f.seek(HEADER_SIZE + (seq - first) * RECORD_SIZE) &&
      f.read(frame, RECORD_SIZE) == RECORD_SIZE && recordDecode(frame, r) && r.seq == seq;
}
bool append(float temperature, float ph, float od, uint32_t timestamp, uint32_t &seq) {
  // Full log stops new records rather than overwriting unacknowledged history.
  if (!available || count() >= LOG_CAPACITY || nextSeq == UINT32_MAX) return false;
  const LogRecord r = makeRecord(nextSeq, timestamp, temperature, ph, od, 0);
  uint8_t frame[RECORD_SIZE];
  recordEncode(r, frame);
  File f = SPIFFS.open(paths[active], FILE_APPEND);
  if (!f || f.size() != HEADER_SIZE + count() * RECORD_SIZE) {
    available = false;
    return false;
  }
  if (f.write(frame, sizeof(frame)) != sizeof(frame)) {
    available = false;
    return false;
  }
  f.flush();
  f.close();
  seq = nextSeq++;
  return true;
}
bool reclaim(uint32_t lastSeq) {
  if (!available || lastSeq == UINT32_MAX || lastSeq >= nextSeq) return false;
  if (lastSeq < first) return true;
  return replaceLog(lastSeq + 1);
}
}
