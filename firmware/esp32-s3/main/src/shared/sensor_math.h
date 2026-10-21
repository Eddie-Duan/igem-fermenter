#pragma once
#include <math.h>
#include <stdint.h>

// Hardware-independent calculations shared by sensor acquisition and native tests.
namespace SensorMath {
constexpr uint16_t TSL_SATURATION = 36863;
constexpr float MIN_LIGHT_COUNTS = 30.0f;

struct PhCalibration {
  float slopePerMv = NAN;
  float offset = NAN;
};

inline bool calibrationValid(const PhCalibration &cal) {
  return isfinite(cal.slopePerMv) && fabsf(cal.slopePerMv) > 0.000001f &&
         isfinite(cal.offset);
}

// Accept either polarity: analog pH boards do not all have the same transfer curve.
inline bool calibrate(float ph1, float mv1, float ph2, float mv2,
                      PhCalibration &result) {
  if (!isfinite(ph1) || !isfinite(ph2) || !isfinite(mv1) || !isfinite(mv2) ||
      ph1 < 0.0f || ph1 > 14.0f || ph2 < 0.0f || ph2 > 14.0f ||
      mv1 <= 0.0f || mv2 <= 0.0f || fabsf(ph2 - ph1) < 0.5f ||
      fabsf(mv2 - mv1) < 50.0f) return false;
  PhCalibration candidate;
  candidate.slopePerMv = (ph2 - ph1) / (mv2 - mv1);
  candidate.offset = ph1 - candidate.slopePerMv * mv1;
  if (!calibrationValid(candidate)) return false;
  result = candidate;
  return true;
}

inline float phFromMillivolts(float moduleMv, const PhCalibration &cal) {
  if (!calibrationValid(cal) || !isfinite(moduleMv) || moduleMv <= 0.0f) return NAN;
  const float value = cal.slopePerMv * moduleMv + cal.offset;
  return isfinite(value) && value >= 0.0f && value <= 14.0f ? value : NAN;
}

inline bool frameUsable(uint16_t full, uint16_t ir, uint16_t saturation = TSL_SATURATION) {
  return full < saturation && ir < saturation;
}

inline float transmittedCounts(float dark, float lit, float minimum = MIN_LIGHT_COUNTS) {
  if (!isfinite(dark) || !isfinite(lit) || dark < 0.0f || lit < 0.0f ||
      !isfinite(minimum) || minimum <= 0.0f || lit - dark < minimum) return NAN;
  return lit - dark;
}

inline float relativeAbsorbance(float counts, float blank, float minimum = MIN_LIGHT_COUNTS) {
  if (!isfinite(counts) || !isfinite(blank) ||
      !isfinite(minimum) || minimum <= 0.0f || counts < minimum || blank < minimum) return NAN;
  return -log10f(counts / blank);
}
}

struct PhReading {
  float adcMv = NAN;
  float moduleMv = NAN;
  float ph = NAN;
  bool voltageValid = false;
};

struct LightReading {
  uint16_t full = 0;
  uint16_t ir = 0;
  uint16_t darkFull = 0;
  float lux = NAN;
  float counts = NAN;
  float odProxy = NAN;
  bool valid = false;
};
