import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:placeframe_mobile/api.dart';
import 'package:placeframe_mobile/geo.dart';

Pose _pose(double yaw, List<double> t) => Pose([0, math.sin(yaw / 2), 0, math.cos(yaw / 2)], t);

void main() {
  test('a single-frame result gives the alignment that maps the camera odometry pose onto its map pose', () {
    final odomFromCamera = _pose(0.4, [1, 0.2, -3]);
    final mapFromCamera = _pose(-1.1, [5, 1.5, 2]);
    final tr = TrackedLocalization.fromSingleFrame(odomFromCamera, [
      Localization('weak', _pose(0, [0, 0, 0]), 0.3, 100, {}),
      Localization('best', mapFromCamera, 0.9, 100, {'num_inliers': 457}),
    ]);

    expect(tr.mapId, 'best');
    expect(tr.probability, 0.9);
    expect(tr.frameAgreed, isTrue);
    expect(tr.frameInliers, 457);
    final mapFromCameraAgain = tr.odomFromMap!.inverse() * odomFromCamera;
    for (var i = 0; i < 3; i++) {
      expect(mapFromCameraAgain.t[i], closeTo(mapFromCamera.t[i], 1e-9));
    }
    expect(mapFromCameraAgain.angleTo(mapFromCamera), closeTo(0, 1e-9));
  });

  test('no single-frame result: not localized', () {
    final tr = TrackedLocalization.fromSingleFrame(_pose(0, [0, 0, 0]), const []);
    expect(tr.mapId, isNull);
    expect(tr.probability, 0);
    expect(tr.frameAgreed, isFalse);
    expect(tr.odomFromMap, isNull);
  });
}
