# iGEM 发酵罐项目

两阶段发酵（增殖期浊度上升 / 裂解期浊度下降）的受控发酵罐：**在线 OD 监测 + 下降趋势判断 + 收蛋白报警**，配套温度控制、pH 检测、搅拌。

## 目录

- `发酵罐方案.md` / `iGEM发酵罐项目整理_1_3_4.md`：硬件方案与参考队伍调研（Vilnius-Lithuania 2024 等）
- `mobile_app/`：Android / iOS 手机 App（Flutter）
- `.github/workflows/`：GitHub Actions 构建与校验

## App 功能（mobile_app）

- 创建/管理多个发酵批次（菌株、目标温度、仿真速度）
- 实时曲线：温度、pH、浊度(OD600) 时间曲线图
- **收获检测**：依据 wiki 两阶段模型，检测到浊度持续快速下降 → 提示「Harvest time」
- 控制面板：搅拌开关 + 转速（PWM 100–300 rpm）、加热开关 + 目标温度（当前为仿真数据源，硬件接入点已抽象为 `SensorSource` 接口）
- 手动录入读数、暂停/恢复/结束/重启、CSV 导出分享
- 界面全英文，风格与 esp32-medication-device 保持一致（Material 3，品牌色 `0xff147d79`）

## 构建与校验

本机无需安装 Flutter SDK，校验走 GitHub Actions（pinned Flutter 3.47.4）：

- `flutter-check.yml`：push / PR 触发，`flutter analyze` + `flutter test` + 构建 debug APK（产物在 Actions artifact 中）
- `ios-check.yml`：手动触发（macOS runner）

本地开发：

```bash
cd mobile_app
flutter pub get
flutter run
```

## 路线

- v1（当前）：仿真数据源 + 完整 App 流程
- v2：接入 ESP32-S3 硬件（OD 光路、DS18B20、pH、加热 PTC、搅拌电机），替换 `SensorSource` 实现