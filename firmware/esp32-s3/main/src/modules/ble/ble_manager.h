#pragma once
namespace FermenterBle {
void begin();
void loop();
void recordSample();
bool connected();
// Explicit operation only: erases BLE logs, not sensor calibration/NVS.
bool formatLogStorage();
}
