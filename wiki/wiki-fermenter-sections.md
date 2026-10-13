<!-- ===================================================================
 发酵罐 wiki 章节（次要 device，各一小节；长度对齐去年 wiki 尺度）
   A 节 → Software 页，接在 Part II 之后
   B 节 → User Manual 页，接在 AeroEase 之后
 · 正文英文，可直接粘贴。
 · 以 > **📷 / 📊 INSERT ...** 开头的灰底行是插图/插表说明，贴前删掉。
 · <...> 是待填内容。图号在本节内从 1 重新开始。
=================================================================== -->

# A. Software 页新增小节

> **位置**：插在 `Part II. Bioinformatics for Club Cell Target Selection` 之后。
> **⚠️ 同时改开头那段**：现在写的是 "two distinct areas"，加发酵罐后改成 three areas，整句替换为：
> > Software and computational analysis support three areas of our work: an Android companion app for the SonoAir device, a bioinformatics project that uses public lung data to guide the selection of a Club cell surface target, and a second app that operates our secondary device, a two-phase fermenter. The two apps focus on device operation and the user experience; the bioinformatics project supports biological research and experimental design.

---

## Part III. Fermenter Control App (Secondary Device)

### Project Background

Our secondary device is a two-phase culture vessel: the culture grows and turbidity rises, then the cells lyse to release the product and turbidity falls. The harvest window is the moment that fall begins — something a conventional bench-top fermenter does not report.

The companion app, written in Flutter and running on Android and iOS, provides that function — online OD600 monitoring with a falling-trend detector — alongside the usual temperature, pH and stirring controls. It currently runs against a built-in simulator of the two-phase process, so the whole workflow can be demonstrated without hardware; the ESP32-S3 firmware will later take the simulator's place behind the same interface.

### Overall System Design

The software consists of six cooperating modules:

> **📊 INSERT — Table 1. Fermenter app modules.**

| Module | Role in the app |
| --- | --- |
| Sensor source | Temperature, pH and OD600 readings; the simulator today, the ESP32-S3 link later. |
| Batch controller | Advances the batch clock, polls the sensor, stores readings, recomputes the harvest verdict and the phase. |
| Local database | Batch and reading history stored on the phone (SQLite). |
| Harvest detector | Sliding-window trend test on the OD600 series. |
| User interface | Batch list, live time course, phase badge, harvest banner, controls. |
| CSV export | Exports a batch's history to CSV and opens the system share sheet. |

The sensor source is a single interface, so the simulator, the test doubles and the future hardware link are interchangeable.

> **📷 INSERT — Software Figure 1. Fermenter software architecture.**
> 一张 draw.io 图即可：`SimulatedSensorSource (v1)` 与 `ESP32-S3 link (v2)` 用虚线各连到 `SensorSource` 接口 → `FermenterController` →（SQLite / HarvestDetector / UI）→ `CSV export`。
> 图注：*One sensor interface, two implementations.*

### Turbidity-Based Harvest Detection

A single low OD reading does not prove lysis: OD also falls when cells sediment, when bubbles cross the light path, or when a sample is drawn. The detector therefore flags the harvest window only when three conditions are met at once:

> **📊 INSERT — Table 2. Harvest detection criteria.**

| Parameter | Value | Purpose |
| --- | --- | --- |
| Regression window | 5 readings | Smooths sensor noise. |
| Sustained windows | 3 consecutive | Rejects single dips. |
| Minimum peak OD600 | 0.4 | Confirms growth occurred. |
| Slope threshold | −0.0015 OD per interval | Separates lysis from drift. |
| Drop below peak | 4 % | Confirms the culture is past its peak. |

When all three are met, the app shows a **"Harvest time!"** banner reporting the peak and current OD, with a *Mark as harvested* action. The same OD series sets the phase shown on screen: early growth, exponential growth, stationary/peak, lysis or finished.

### App Interface and User Workflow

A batch is created with a name, a strain, a target temperature and a time scale. Inside a batch the screen shows a live time course for temperature, pH and OD600, a phase badge, the harvest banner, and controls for the stirrer (100–300 rpm) and the heater (on/off with a target temperature). Readings are recorded every 120 simulated seconds, and manual readings can also be added. A built-in sample batch generates one complete fermentation cycle, and any batch's history can be exported to CSV.

> **📷 INSERT — Software Figure 2. App screens (2–4 张并排).**
> (a) Home — 批次列表；(b) Batch detail — 实时曲线 + 阶段徽章 + Harvest time! 横幅；(c) Controls — Stirrer / Heater；(d) 可选 CSV。
> 图注：*Flutter renders with simulated data; the interface uses English labels.*

### Software Testing

Our CI pipeline pins a specific Flutter release, then runs `flutter analyze`, `flutter test` and an Android debug build on every change; a separate workflow does the same on macOS for iOS. The suite contains 25 tests across 6 files.

> **📊 INSERT — Table 3. Software validation.**（数字从最近一次 CI 日志抄，别照抄占位符）

| Check | Result |
| --- | --- |
| Static analysis (`flutter analyze`) | `<fill in>` — error- and warning-free |
| Unit and widget tests (25) | `<passed> / 25` |
| Android debug build | `<fill in>` |

These results cover synthetic data only, and they do not show that the thresholds carry over to a real culture, whose light path still needs its own OD calibration. The next step is a hardware session that compares the recorded curve with offline spectrophotometer readings.

### Open-Source Reproduction

The source code, setup instructions and CI configuration are available in our repository: https://github.com/Eddie-Duan/igem-fermenter

---

# B. User Manual 页新增小节

> **位置**：接在现有 AeroEase manual 之后。
> **⚠️**：硬件仍在搭建中，下面按目标流程写；硬件跑通后把 status 句改成实测结果或删掉。

---

## Fermenter

The fermenter is our team's secondary device: a 1.5 L stirred vessel for two-phase cultures, with online OD600, temperature and pH monitoring, plus active heating and stirring. It signals **when the culture has entered lysis and the protein is ready to harvest**. *Status: the device is still a prototype and the app runs on a built-in simulator, so the readings shown below are simulated.*

> **📷 INSERT — Manual Fig. 1. Overall guide to using the fermenter.**
> 一张带编号的整体图（对照 AeroEase 的 Fig.1）：① 罐体 ② 盖+硅胶塞 ③ 搅拌电机与穿盖搅拌轴 ④ 温度探头 ⑤ pH 电极 ⑥ 取样口 ⑦ 加热片 ⑧ 电子盒/电源 ⑨ 手机界面小图。
> 图注：*Fig.1 The overall guide to using the fermenter.*

### Preparation

1. Connect the 12 V supply and autoclave the glass vessel. The pH electrode, optics and electronics cannot be autoclaved, so disinfect them chemically.
2. Check the light path (fixed distance, shielded, clean) and calibrate pH against 4.0 and 7.0 buffers.
3. Fit the lid — stirrer shaft through the seal, then the temperature probe, pH electrode and sampling port — keeping the shaft coaxial.
4. Add medium, inoculate through the sampling port, and stand the vessel upright on a level surface.

### Starting a Batch

1. Select **New batch**; enter a name and strain, and set the target temperature.
2. Switch the **stirrer** (100–200 rpm) and the **heater** on, and switch the heater off once the target temperature is reached — the vessel has no cooling.
3. Keep the phone connected: readings are recorded continuously, and batches continue to run in the background.

### Harvest

1. Wait for the **"Harvest time!"** banner, and check that the fall is not caused by sedimentation, bubbles or a recent sample.
2. Tap **Mark as harvested** and collect the culture; export the batch as **CSV** if you need the raw time course.

> **📷 INSERT — Manual Fig. 2. Harvest alert.**（与 A 节 Software Figure 2 同一批截图，不必重截）
> 图注：*Fig.2 The alert appears only after a sustained fall from the recorded peak.*

### Cleaning and Storage

1. Detach the lid assembly, stirrer shaft and propeller, and rinse the wetted parts with warm water.
2. Wipe the lid, electrodes and electronics with a damp cloth only, and keep the pH electrode in its storage solution. Air-dry everything before storing the vessel upright with the lid fitted.

> **📊 INSERT — Manual Table 1. Troubleshooting.**

| Symptom | Cause | Action |
| --- | --- | --- |
| OD600 flat or noisy mid-run | Dirty, unshielded light path, or bubbles | Clean and re-shield it; lower the stirrer speed. |
| No harvest alert although the culture has lysed | Peak OD600 below 0.4, or the fall not sustained | Check the OD calibration and re-tune the thresholds. |
| pH drifts over a long run | Ageing or uncalibrated electrode | Recalibrate with pH 4.0 and 7.0 buffers. |

### Safety

- Check after every run that the electronics side is dry, and disconnect the power if it is damp.
- Do not touch the heater during operation, and never run it with an empty vessel.
- Use the fermenter only for its intended cultures in a supervised laboratory: it is a prototype, not a certified instrument.

---

<!-- 写稿依据（不要贴进 wiki）
 · 判据/模型：docs/发酵罐方案.md；mobile_app/lib/services/harvest_detector.dart
 · 采样、批次、控制：services/fermenter_controller.dart、models/control_state.dart
 · CSV：services/csv_export_service.dart ｜ 测试 25 例 / 6 文件
 · CI：.github/workflows/flutter-check.yml、ios-check.yml
 字数对照（去年 wiki）：Software 页 2134 词（Part I 1253 / Part II 816）；User Manual 全页 513 词
-->
