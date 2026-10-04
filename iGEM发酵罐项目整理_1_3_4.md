# iGEM 发酵罐项目重点整理（项目1、3、4）

> 本文件整理自 iGEM 各队 Wiki 页面，针对**两阶段发酵**（增殖阶段浊度上升 / 表达产物阶段浊度下降）场景，重点收录带**浊度/OD 检测**且 pH、温度检测与控制较完整的项目。
>
> - **项目 1**：Vilnius-Lithuania 2024（立陶宛）—— 浊度+pH+温度全闭环，最匹配
> - **项目 3**：NAWI Graz 2017（奥地利格拉茨）—— 自带 OD 恒定系统（turbidostat）
> - **项目 4**：Sheffield 2022（英国谢菲尔德）—— 环形罐体 turbidostat，OD800 浊度检测
>
> 数据来源（各项目硬件页）：见文末"参考来源"。

---

## 目录

1. [项目 1 · Vilnius-Lithuania 2024](#项目-1-vilnius-lithuania-2024)
2. [项目 3 · NAWI Graz 2017](#项目-3-nawi-graz-2017)
3. [项目 4 · Sheffield 2022](#项目-4-sheffield-2022)
4. [三项目对比与对两阶段发酵的参考价值](#三项目对比与参考价值)
5. [参考来源](#参考来源)

---

## 项目 1 · Vilnius-Lithuania 2024

- **网址**：https://2024.igem.wiki/vilnius-lithuania/hardware/
- **控制器**：Arduino UNO R4 WiFi（带 WiFi，可远程监控）
- **核心特征**：明确采用**浊度传感器**（而非 OD 传感器）测量菌体生长；pH、温度、搅拌、加热全部具备，全自动化设计；**与本项目"增殖浊度升 / 表达浊度降"两阶段发酵最贴合**。
- **罐体**：1.5 L 玻璃罐 + 铝制顶盖（易加工、可拆开灭菌）。

### 1.1 具体元件清单

| # | 元件 | 型号/规格 | 参考单价(EUR) | 功能 |
|---|------|-----------|:---:|------|
| 1 | 主控板 | Arduino UNO R4 WiFi | 45.80 | 整体控制、WiFi 通信 |
| 2 | 扩展板 | Gravity: Screw Shield V2 for Arduino | 13.30 | 接线端子，固定传感器 |
| 3 | 杜邦线 | 母-母 ×20 | 3.80 | 电气连接 |
| 4 | 罐体 | 1.5 L 玻璃罐 | 4.00 | 反应容器 |
| 5 | pH 传感器 | Gravity: Analog Industrial pH Sensor | 86.30 | pH 检测 |
| 6 | 温度传感器 | MAX6675 + 热电偶线 | 13.10 | 温度检测 |
| 7 | 加热元件 | 陶瓷加热器（3D 打印机用）12V 40W | 3.90 | 温度过低时加热 |
| 8 | 继电器 | 1 通道继电器模块 5V 10A/250V | 2.90 | 开关加热器 |
| 9 | 电源 | GPX ZTD-1250 12V/5A DC | 9.57 | 供电 |
| 10 | 搅拌电机 | 25D×56L 227:1 12V 33RPM（Pololu 3233） | 17.10 | 驱动搅拌/曝气 |
| 11 | 电机驱动 | L298 H-Bridge 双电机驱动 | 6.00 | 驱动搅拌电机 |
| 12 | 搅拌桨 | 带塑料螺旋桨叶的搅拌器 | 7.26 | 混合与曝气 |
| 13 | 浊度传感器 | **Gravity: Analog Turbidity Sensor** | 16.60 | **浊度检测（关键）** |
| 14 | 联轴器 | Jaw Spider Shaft Coupling 5×8mm | 5.50 | 电机轴与搅拌轴连接 |
| 15 | Kapton 胶带 | 10mm Kapton Tape | 4.70 | 电气绝缘、遮光 |
| 16 | 硅酮密封胶 | MAKROFLEX SA102 无色 300ml | 4.79 | 顶盖防水密封 |
| 17 | 防水喷漆 | Maston Special 防水黑 0.5L | 10.61 | 搅拌轴/元件防水防锈 |
| 18 | 热缩管 | Wire heat shrink tubing | 0.97 | 线束绝缘保护 |

> **合计 256.20 EUR**（该队页面 Table 1 原文）。该队为降低门槛，特意不用价格昂贵的 OD 计，改用浊度传感器，并通过"浊度→OD 校准曲线"（y = mx + k）换算生长量（详见 1.3）。

### 1.2 组装结构图（wiki 原图）

**图 1-1 发酵罐主组件结构图**（来源：Vilnius-Lithuania 2024 Hardware 页面）

<img src="https://static.igem.wiki/teams/5246/webp/bioreactor-components.webp" alt="Vilnius-Lithuania 2024 发酵罐组件结构图" width="720" style="border:1px solid #d0d7de;border-radius:6px;" />

> 图示说明：铝制顶盖装有 **12V 直流电机**（驱动搅拌）、**Air 通气口 + 膜片(Membrane)**、**pH 传感器**、**温度传感器**、**PTC 加热器**、**浊度传感器**；罐体为 1.5 L 玻璃罐，底部为**浸没式曝气器(Submerged aerator)**。电子件单独装于独立电子盒。

### 1.3 组装与关键设计说明

1. **顶盖固定传感器**：所有传感器与电机固定在铝盖对应孔位，便于拆盖灭菌。
2. **灭菌流程**：罐体（底座）入高压灭菌锅；带电子件的顶盖用硅酮胶(16)密封防水后，整体浸入 70% 异丙醇消毒（该队已通过 LB 无菌测试验证此法有效）。
3. **浊度→OD 校准（关键）**：浊度传感器(13) 输出的是 NTU 浊度值，该队同时间点同时测浊度与 OD 做出校准曲线，代入 y = mx + k 换算成对应 OD，整个过程自动化。**这正适合你"增殖期浊度上升"的连续监测**。
4. **控制闭环**：
   - 温度低 → 继电器(8) 接通 PTC 加热器(7)（注意加热器与温度传感器需分开放置，避免相互干扰、也避免漏电）；
   - pH 偏离 → 通过泵/阀门调节（页面描述可调 pH）；
   - 浊度传感器(13) 实时反映菌体浓度，替代 OD 用于生长监测。
5. **搅拌+曝气**：电机(10)经联轴器(14)带动浸没式曝气器(12)，同时完成混匀与充氧。搅拌轴需用防水喷漆(17)/保护层防锈。

---

## 项目 3 · NAWI Graz 2017

- **网址**：https://2017.igem.org/Team:NAWI_Graz/Bioreactor
- **控制器**：2× Arduino Nano（一个测 OD，一个控制蠕动泵）
- **核心特征**：内置 **OD 维持系统（turbidostat）**——实时测 OD，当 OD 高于设定值（如 0.3）即补入新鲜无菌培养基稀释，维持浊度恒定。pH、温度、磁力搅拌齐备。
- **罐体**：500 mL 实验室瓶，GL 80 开口。

### 3.1 具体元件清单

| # | 元件 | 型号/规格 | 功能 |
|---|------|-----------|------|
| 1 | 罐体 | 500 mL 实验室瓶（GL 80 开口） | 反应容器，瓶盖打孔装金属螺纹 |
| 2 | pH 传感器 | DFRobot pH 传感器 | pH 检测 |
| 3 | 温度传感器 | 玻璃管内温度传感器（悬于蒸馏水） | 温度检测 |
| 4 | 蠕动泵 ×2 | 蠕动泵（补培养基 + 泵出废液） | 稀释/补料/排出 |
| 5 | H 桥模块 | H-bridge 模块 | 驱动蠕动泵 |
| 6 | 主控板 | 2× Arduino Nano | 测 OD / 控制泵 |
| 7 | OD 光源 | 约 600 nm LED | OD 检测光源 |
| 8 | OD 光敏 | TSL 235R 光敏传感器 | OD 检测接收 |
| 9 | 比色皿 | UV 比色皿（底部钻孔接管） | OD 测量腔 |
| 10 | 外壳 | 3D 打印 OD 腔外壳 + 白色遮光外壳 | 遮光、固定 |
| 11 | 搅拌 | 磁力搅拌 | 混匀 |
| 12 | 管路 | 硅胶管若干 | 液体输送 |
| 13 | 密封 | 双组份胶、绝缘胶带 | 密封、遮光 |

### 3.2 端口布置（瓶盖俯视 · wiki 原图）

**图 3-1 反应瓶瓶盖俯视图**（来源：NAWI Graz 2017 Bioreactor 页面）

<img src="https://static.igem.org/mediawiki/2017/c/c4/Reactortop.png" alt="NAWI Graz 2017 反应瓶瓶盖俯视图" width="520" style="border:1px solid #d0d7de;border-radius:6px;" />

> 图示说明：500 mL 实验室瓶 GL 80 开口，瓶盖打孔装入金属螺纹。端口包括 **温度传感器(Temperature sensor)**、**pH 传感器(pH sensor)**、Port1（补料入口）、Port2（玻璃管到底部泵出测 OD）、Port3（酸入口）、Port4（碱入口）、Port5（出口，深至瓶底）。

### 3.3 组装结构图（wiki 原图）

**图 3-2 OD 维持系统整体装置**（来源：NAWI Graz 2017 Bioreactor 页面）

<img src="https://static.igem.org/mediawiki/2017/thumb/6/6b/Od_maintenance_correct2.png/800px-Od_maintenance_correct2.png" alt="NAWI Graz 2017 OD 维持系统整体装置" width="720" style="border:1px solid #d0d7de;border-radius:6px;" />

**图 3-3 OD 检测腔装配图**（来源：NAWI Graz 2017 Bioreactor 页面）

<img src="https://static.igem.org/mediawiki/2017/thumb/6/62/Assembled_text.png/800px-Assembled_text.png" alt="NAWI Graz 2017 OD 检测腔装配图" width="520" style="border:1px solid #d0d7de;border-radius:6px;" />

> 图 3-2/3-3 说明：培养液经 Port2 泵入 UV 比色皿，**600nm LED** 透过比色皿，**TSL 235R 光敏传感器**接收光强计算 OD；当 OD 超设定值，蠕动泵补入新鲜无菌培养基稀释，实现 turbidostat 浊度恒定。

### 3.4 OD 维持系统（turbidostat）逻辑

- 培养液经 Port2 泵入 UV 比色皿，600nm LED 透过比色皿，TSL235R 接收光强 → 计算 OD。
- 当 OD > 设定值（如 0.3，实验表明该值荧光信号最佳）时，蠕动泵(4) 泵入约 5 mL 新鲜无菌培养基稀释，OD 回落。
- 两个 Arduino：一个负责 OD 采集，一个负责泵控制，通过 H 桥驱动。
- 该系统可在较长时间内把 OD 维持在目标值附近，正对应"增殖期浊度上升→反馈稀释"的闭环思路。

---

## 项目 4 · Sheffield 2022

- **网址**：https://2022.igem.wiki/sheffield/engineering
- **控制器**：Raspberry Pi Pico
- **核心特征**：**方形截面环形罐体（toroidal bioreactor）** turbidostat，用 **OD800 LED-光电晶体管对**测浊度（选 800nm 而非 600nm 以减小背景光干扰）。磁力搅拌、温度探头、蠕动泵补料。
- **罐体**：两个不同直径有机玻璃（perspex）圆筒同心套叠，3mm 壁厚、45mm 高、5mm 底板。

### 4.1 具体元件清单

| # | 元件 | 型号/规格 | 功能 |
|---|------|-----------|------|
| 1 | 外筒 | 有机玻璃圆筒（大直径），3mm 壁厚 | 环形罐体外壁 |
| 2 | 内筒 | 有机玻璃圆筒（小直径），3mm 壁厚 | 环形罐体内壁 |
| 3 | 底板 | 环形板（激光切割，带沟槽），5mm 厚 | 固定两筒、密封 |
| 4 | 顶盖 | 有机玻璃盖（带沟槽，留通气） | 密封、预留探头/进料孔 |
| 5 | 温度探头 | 温度探头 | 温度检测 |
| 6 | OD 光源 | **OD800 LED** | 浊度/OD 检测光源 |
| 7 | OD 接收 | 光电晶体管（phototransistor） | 浊度/OD 检测接收 |
| 8 | 搅拌 | 倒置伺服电机 + 叉形 horn + 磁球 | 磁力搅拌 |
| 9 | 蠕动泵 | 12V 蠕动泵 | 补入培养基 |
| 10 | 主控板 | Raspberry Pi Pico | 控制与数据 |
| 11 | 出流管 | 刚性管（倾斜插入，顶部对准 100ml 液位） | 稳定排出废液 |
| 12 | 管路 | 硅胶管 | 液体输送 |
| 13 | 密封/粘接 | 丙烯酸胶（acrylic cement）、激光切割件 | 组装密封 |

### 4.2 组装结构图（wiki 原图）

**图 4-1 环形罐体生物反应器整体**（来源：Sheffield 2022 Hardware 页面）

<img src="https://static.igem.wiki/teams/4451/wiki/engineering-journey/bioreactor.png" alt="Sheffield 2022 环形罐体生物反应器整体" width="680" style="border:1px solid #d0d7de;border-radius:6px;" />

**图 4-2 OD800 浊度传感器在罐体上的布置**（来源：Sheffield 2022 Hardware 页面）

<img src="https://static.igem.wiki/teams/4451/wiki/engineering-journey/od-sensor-bioreactor.png" alt="Sheffield 2022 OD800 浊度传感器布置" width="520" style="border:1px solid #d0d7de;border-radius:6px;" />

**图 4-3 磁力搅拌系统**（来源：Sheffield 2022 Hardware 页面）

<img src="https://static.igem.wiki/teams/4451/wiki/engineering-journey/stirring.png" alt="Sheffield 2022 磁力搅拌系统" width="520" style="border:1px solid #d0d7de;border-radius:6px;" />

**图 4-4 最终装配实物**（来源：Sheffield 2022 Hardware 页面）

<img src="https://static.igem.wiki/teams/4451/wiki/engineering-journey/final.jpg" alt="Sheffield 2022 最终装配实物图" width="680" style="border:1px solid #d0d7de;border-radius:6px;" />

> 图示说明：培养液在内外有机玻璃筒之间的环形带内流动；**OD800 LED-光电晶体管对**贯穿罐壁测浊度；**倒置伺服电机 + 叉形 horn + 磁球**实现磁力搅拌；**12V 蠕动泵**补入培养基，倾斜刚性出流管稳定排出废液（对准 100 mL 液位）。

### 4.3 关键设计说明

- **环形结构优点**：培养液在内外筒之间的环形带内流动，比常规方罐混合更均匀。
- **OD800 测量**：LED 与光电晶体管分别置于罐壁两侧，光穿过培养液；选 800nm 减小培养基背景散射干扰（相较于 600nm）。OD 测量是 turbidostat 正常工作的前提。
- **出流设计改进**：刚性管倾斜插入，管顶对准 100 mL 液位，靠重力稳定排出（从旧方案的 140mL+ 改进到 105–108mL），减少表面张力造成的批量突排与污染风险。
- **蠕动泵改进**：由 6V 改 12V 泵并直接接墙式适配器供电，避免面包板稳压器过热（曾达 120°C），泵速恢复正常。
- **磁力搅拌**：倒置伺服电机带动叉形 horn，horn 两端磁铁吸引罐内磁球随动，实现温和混匀。

---

## 三项目对比与参考价值

| 对比项 | 项目1 Vilnius-Lithuania 2024 | 项目3 NAWI Graz 2017 | 项目4 Sheffield 2022 |
|---|---|---|---|
| 浊度/OD 检测 | ✅ 浊度传感器(Gravity) | ✅ 600nm LED+TSL235R | ✅ OD800 LED+光电管 |
| pH 检测 | ✅ | ✅ | ⚠️ 未明确 |
| pH 控制 | ✅ | ✅(酸/碱口) | ⚠️ 未明确 |
| 温度检测 | ✅ MAX6675 热电偶 | ✅ | ✅ 温度探头 |
| 温度控制 | ✅ PTC 加热+继电器 | ⚠️ 温控有限 | ⚠️ 温控有限 |
| 搅拌 | ✅ 电机+桨(曝气) | ✅ 磁力搅拌 | ✅ 伺服+磁球 |
| 补料/泵 | —(未列蠕动泵) | ✅ 2×蠕动泵(turbidostat) | ✅ 12V 蠕动泵 |
| 控制器 | Arduino UNO R4 WiFi | 2×Arduino Nano | Raspberry Pi Pico |
| 罐体 | 1.5L 玻璃罐 | 500mL 实验室瓶 | 有机玻璃环形罐 |
| 成本参考 | ~165 EUR | 较低(未列) | 低(自制件多) |
| 对两阶段发酵参考 | ★★★★★ 全闭环最贴近 | ★★★★☆ 浊度恒定闭环 | ★★★☆☆ OD检测+环形混匀 |

**针对你的需求建议**：
- **增殖期（浊度上升）**：参考项目3 的 turbidostat 逻辑——实时测浊度，超标即补料稀释，把 OD 维持在设定区间；
- **表达期（浊度下降）**：参考项目1 的浊度传感器连续监测，判断产物表达阶段菌体浓度变化趋势，用于触发诱导/判断收获时机；
- **结构参考**：项目1 玻璃罐+铝盖方案最易复制；项目4 环形罐混匀均匀但自制加工门槛高。

---

## 参考来源

- Vilnius-Lithuania 2024 Hardware：https://2024.igem.wiki/vilnius-lithuania/hardware/
- NAWI Graz 2017 Bioreactor：https://2017.igem.org/Team:NAWI_Graz/Bioreactor
- Sheffield 2022 Engineering Success：https://2022.igem.wiki/sheffield/engineering
- （补充）ASU 2024 / Hopkins 2023 / NCKU Tainan 2018 / Cornell 2022 等项目概览见对话首轮整理表

---

*文档生成日期：2026-10-02。元件型号与价格为各队页面原文，未做换算，采购前请核对实时价格与兼容性。*
