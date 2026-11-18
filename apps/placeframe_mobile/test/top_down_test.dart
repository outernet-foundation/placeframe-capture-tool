import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:placeframe_mobile/geo.dart';
import 'package:placeframe_mobile/top_down.dart';

Pose _at(double x, double z) => Pose(Pose.identity.q, [x, 0, z]);
Pose _yaw(double a, List<double> t) => Pose([0, math.sin(a / 2), 0, math.cos(a / 2)], t);

void main() {
  test('path points use the first alignment at or after their time; the map frame stays fixed', () {
    final m = TopDownModel();
    for (var i = 0; i < 10; i++) {
      m.addPose(_at(i.toDouble(), 0), i.toDouble());
    }
    final a1 = _yaw(0.1, [1, 0, 2]);
    expect(m.addAlignment(4.5, a1, [4, 0, 0]), isTrue); // first fix sets the display frame
    final display = m.displayFromMap!;
    // Odometry drifted by 0.3 m by the second fix: same place, refined alignment, no reset.
    final a2 = Pose(a1.q, [1.3, 0, 2]);
    expect(m.addAlignment(8.5, a2, [8, 0, 0]), isFalse);
    expect(identical(m.displayFromMap, display), isTrue);
    final path = m.displayPath.toList();
    // Points up to t=4.5 use a1: display = displayFromMap ∘ a1⁻¹ = identity.
    expect(path[3][0], closeTo(3, 1e-9));
    // Points after t=4.5 use a2: shifted by the drift correction (-0.3 m along the map's x, rotated into display).
    final expected = (display * a2.inverse() * _at(6, 0)).t;
    expect(path[6][0], closeTo(expected[0], 1e-9));
    expect(path[6][2], closeTo(expected[2], 1e-9));
  });

  test('a different alignment keeps the display frame and re-places the path before it', () {
    final m = TopDownModel();
    m.addPose(_at(0, 0), 0);
    m.addPose(_at(1, 0), 1);
    expect(m.addAlignment(0.5, _yaw(0, [0, 0, 0]), [0, 0, 0]), isTrue);
    final display = m.displayFromMap!;
    // The tracker corrects the alignment by 5 m: no new frame; points up to t=1.5 now use the corrected alignment.
    final corrected = _yaw(0.6, [5, 0, 0]);
    expect(m.addAlignment(1.5, corrected, [1, 0, 0]), isFalse);
    expect(identical(m.displayFromMap, display), isTrue);
    final expected = (display * corrected.inverse() * _at(1, 0)).t;
    expect(m.displayPath.toList()[1][0], closeTo(expected[0], 1e-9));
  });

  test('map points are drawn in the display frame and cut at the phone height', () {
    final m = TopDownModel();
    m.addPose(_at(0, 0), 0);
    m.addAlignment(0, Pose(Pose.identity.q, [0, 0, 0]), [0, 0, 0]);
    m.setMapPoints(Float32List.fromList([1, 0.5, 2, 3, 5, 4]), 0);
    expect(m.mapPointCount, 1);
    expect(m.mapPointsXZ!.toList(), [1, 2]);
  });
}
