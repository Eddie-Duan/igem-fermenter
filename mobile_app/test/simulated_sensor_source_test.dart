import 'dart:math';

import 'package:fermenter_app/models/control_state.dart';
import 'package:fermenter_app/models/sensor_reading.dart';
import 'package:fermenter_app/services/simulated_sensor_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OD base curve: growth rises, plateau holds, lysis falls', () {
    expect(SimulatedSensorSource.odAt(0), lessThan(0.2));
    expect(
        SimulatedSensorSource.odAt(5), greaterThan(SimulatedSensorSource.odAt(3)));
    expect(SimulatedSensorSource.odAt(10), closeTo(1.25, 0.05));
    expect(SimulatedSensorSource.odAt(18), lessThan(0.45));
    expect(
        SimulatedSensorSource.odAt(18), lessThan(SimulatedSensorSource.odAt(12)));
  });

  test('pH drifts down during growth then recovers slightly', () {
    expect(SimulatedSensorSource.phAt(0), closeTo(7.0, 1e-9));
    expect(
        SimulatedSensorSource.phAt(9), lessThan(SimulatedSensorSource.phAt(0)));
    expect(SimulatedSensorSource.phAt(16),
        greaterThan(SimulatedSensorSource.phAt(11)));
    expect(SimulatedSensorSource.phAt(100), lessThanOrEqualTo(7.4));
  });

  test('heater drives temperature toward target, cooling pulls it back', () {
    // 温度是「累计式」积分：poll 每次只按 dtSeconds 推进一步，
    // 所以要像 Controller 那样按 120 秒步长反复采样，才能把温度推上去。
    const sampleSeconds = 120;
    final source = SimulatedSensorSource(random: Random(1));
    const heating = ControlState(
        stirrerOn: false, stirrerRpm: 200, heaterOn: true, targetTempC: 37);

    var seq = 0;
    double sample(int simSeconds, ControlState control) => source
        .poll(
          projectId: 1,
          seq: seq++,
          control: control,
          simSeconds: simSeconds,
          dtSeconds: sampleSeconds,
        )
        .temperatureC;

    // 加热 6 个仿真小时（3°C/h）：足以把初始 24°C 拉到目标 37°C
    var last = 0.0;
    for (var sim = sampleSeconds; sim <= 6 * 3600; sim += sampleSeconds) {
      last = sample(sim, heating);
    }
    expect(last, greaterThan(30));

    // 关闭加热再晾 4 个小时（1.5°C/h）：温度开始回落
    final coolingControl = heating.copyWith(heaterOn: false);
    var cooling = last;
    for (var sim = 6 * 3600 + sampleSeconds;
        sim <= 10 * 3600;
        sim += sampleSeconds) {
      cooling = sample(sim, coolingControl);
      expect(cooling, lessThan(37.5));
    }
    expect(cooling, lessThan(last));
  });

  test('poll produces monotonic sim time and valid ranges', () {
    final source = SimulatedSensorSource();
    const control = ControlState.idle();
    SensorReading? previous;
    for (var sim = 120; sim <= 1200; sim += 120) {
      final reading = source.poll(
        projectId: 7,
        seq: sim ~/ 120 - 1,
        control: control,
        simSeconds: sim,
        dtSeconds: 120,
      );
      expect(reading.simSeconds, sim);
      expect(reading.ph, inInclusiveRange(6.0, 7.4));
      expect(reading.od, greaterThanOrEqualTo(0));
      expect(reading.source, 'sim');
      previous = reading;
    }
    expect(previous, isNotNull);
  });
}