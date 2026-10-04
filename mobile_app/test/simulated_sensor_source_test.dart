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
    // 状态化采集：poll 内部会累计温度。
    final source = SimulatedSensorSource(random: Random(1));
    final control = ControlState(
        stirrerOn: false, stirrerRpm: 200, heaterOn: true, targetTempC: 37);

    double polled(double hours) => source
        .poll(
          projectId: 1,
          seq: (hours * 30).round(),
          control: control,
          simSeconds: (hours * 3600).round(),
          dtSeconds: 120,
        )
        .temperatureC;

    // 加热 6 个仿真小时：应显著高于初始 24°C
    var last = polled(1);
    for (var h = 2.0; h <= 6.0; h += 1) {
      last = polled(h);
    }
    expect(last, greaterThan(30));

    // 关闭加热再晾 4 个小时：温度开始回落
    final off = control.copyWith(heaterOn: false);
    var cooling = last;
    for (var h = 7.0; h <= 10.0; h += 1) {
      cooling = source
          .poll(
            projectId: 1,
            seq: (h * 30).round(),
            control: off,
            simSeconds: (h * 3600).round(),
            dtSeconds: 120,
          )
          .temperatureC;
      expect(cooling, lessThan(37 + 0.5));
    }
    expect(cooling, lessThan(last));
  });

  test('poll produces monotonic sim time and valid ranges', () {
    final source = SimulatedSensorSource();
    final control = const ControlState.idle();
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