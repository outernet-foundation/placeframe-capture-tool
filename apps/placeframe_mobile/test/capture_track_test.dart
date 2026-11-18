import 'package:flutter_test/flutter_test.dart';
import 'package:placeframe_mobile/capture_view.dart';
import 'package:placeframe_mobile/geo.dart';

Pose _at(double x, double y, double z) => Pose(Pose.identity.q, [x, y, z]);

void main() {
  test('distance walked adds steps, ignores standing still and odometry jumps', () {
    final t = CaptureTrack();
    for (var i = 0; i <= 10; i++) {
      t.addPose(_at(i * 0.1, 0, 0)); // 1 m in 10 cm steps
    }
    t.addPose(_at(1.005, 0, 0)); // jitter while standing: below the step threshold
    t.addPose(_at(6, 0, 0)); // a 5 m jump of the odometry
    t.addPose(_at(6, 0, 0.5)); // then 0.5 m more walking
    expect(t.distance, closeTo(1.5, 1e-9));
    expect(t.path.length, 13);
    expect(t.position, [6, 0, 0.5]);
  });
}
