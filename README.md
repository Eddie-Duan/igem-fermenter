# iGEM 发酵罐项目

两阶段发酵（增殖期浊度上升 / 裂解期浊度下降）的受控发酵罐：**在线 OD 监测 + 下降趋势判断 + 收蛋白报警**，配套温度控制、pH 检测、搅拌。

## 目录

- `mobile_app/`：Android 手机 App（Flutter）
- `firmware/esp32-s3/`：主控固件（Arduino 风格 `.ino`，采样 → flash 日志 → 手机通过 Wi-Fi 拉取）
- `.github/workflows/`：GitHub Actions 构建与校验

## App 功能（mobile_app）

- 创建/管理多个发酵批次（菌株、目标温度、仿真速度）
- 实时曲线：温度、pH、浊度(OD600) 时间曲线图
- **收获检测**：依据 wiki 两阶段模型，检测到浊度持续快速下降 → 提示「Harvest time」
- 控制面板：搅拌开关 + 转速（PWM 100–300 rpm）、加热开关 + 目标温度
- 手动录入读数、暂停/恢复/结束/重启、CSV 导出分享
- **设备连接**（首页右上角 Wi-Fi 入口）：填写 ESP32-S3 的地址与网页密码，把设备 flash 里的历史记录同步进批次、持续接收新记录、下发搅拌/加热控制；没有硬件时可用「演示设备」走同一套链路
- 界面全英文，风格与 esp32-medication-device 保持一致（Material 3，品牌色 `0xff147d79`）

## 设备通信

手机与设备在同一个局域网（或设备开的热点）上，通过设备本地 HTTP + JSON 接口通信：

- 设备始终开启配置热点 `192.168.4.1`（SSID `Fermenter-S3-XXXXXX`，密码见串口日志）
- 也可在设备网页里填路由器 SSID/密码，让设备和手机一起接入同一路由器
- 接口与字段见 `firmware/esp32-s3/APP_INTEGRATION.md`
- App 侧实现：`mobile_app/lib/device/`（HTTP 客户端、分页同步、假设备）

## 构建与校验

本机无需安装 Flutter SDK，校验走 GitHub Actions（pinned Flutter 3.47.4）：

- `flutter-check.yml`：push / PR 触发，`flutter analyze` + `flutter test` + 构建 debug APK（产物在 Actions artifact 中）

本地开发：

```bash
cd mobile_app
flutter pub get
flutter run
```

## 路线

- v1（当前）：仿真数据源 + 完整 App 流程 + Wi-Fi/HTTP 设备接口 + ESP32-S3 固件
- v2：接入真机（OD 光路、DS18B20、pH、加热 PTC、搅拌电机）——标定传感器系数、按实物调引脚，App 侧无需改动
