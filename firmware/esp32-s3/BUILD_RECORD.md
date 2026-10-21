# Wi-Fi 接口版构建记录

日期：2026-10-20（手机接口由 BLE 改为 Wi-Fi/HTTP）。来源：原发酵罐项目 `with-mqtt` 分支（基线提交 `ba06328`）。

## 最终构建结果

| 项目 | 配置 / 结果 |
|---|---|
| 工具 | Arduino IDE 随附 Arduino CLI，使用本机 IDE 配置和已安装用户库 |
| ESP32 开发板包 | Espressif esp32 3.3.8 |
| 开发板 | ESP32S3 Dev Module |
| Flash / 分区 | 8MB / default_8MB，应用容量3,342,336字节 |
| PSRAM | Disabled |
| USB | Hardware CDC and JTAG，CDC On Boot Disabled |
| 草图入口 | firmware/esp32-s3/main/main.ino |
| 结果 | 首轮完整构建通过；最终日志保护修改后的增量构建通过 |
| 程序空间 | **1,368,985 / 3,342,336 字节（40%）** |
| 静态RAM | **50,988 / 327,680 字节（15%）** |
| 静态分配后剩余RAM | 276,692字节；运行时 Wi-Fi、TLS、堆与栈仍会继续占用 |

Windows编译使用英文临时目录，规避中文路径的编译工具兼容问题；编译输入为发酵罐工作区中的临时适配副本。覆盖目标固件后逐文件核对SHA256，确认与最终编译源码一致。

本次改动涉及 `firmware` 与手机 App（移除 BLE 传输，改用 HTTP）。未烧录。没有实测设备连接/断线重连、历史数据落库回收、掉电恢复、传感器精度或温控效果。以上结果确认代码可构建，不等于整机联调已通过。

旧固件备份位于 `E:\大学\igem\发酵罐\output\app-integration-backup-20261020\firmware`，备份目录同时保存原文件SHA256清单。此次没有提交或推送目标项目的Git修改。
