import 'dart:math' as math;

const _wgs84A = 6378137.0;
const _wgs84E2 = 6.69437999014e-3;

// ECEF (Earth-centred, Earth-fixed, metres) of a WGS84 latitude/longitude/height.
List<double> ecefFromGeodetic(double latitude, double longitude, double altitude) {
  final lat = latitude * math.pi / 180, lon = longitude * math.pi / 180;
  final n = _wgs84A / math.sqrt(1 - _wgs84E2 * math.pow(math.sin(lat), 2));
  return [
    (n + altitude) * math.cos(lat) * math.cos(lon),
    (n + altitude) * math.cos(lat) * math.sin(lon),
    (n * (1 - _wgs84E2) + altitude) * math.sin(lat),
  ];
}

// A rigid transform: rotation (unit quaternion x, y, z, w) and translation.
class Pose {
  const Pose(this.q, this.t);

  static const identity = Pose([0, 0, 0, 1], [0, 0, 0]);

  final List<double> q; // x, y, z, w
  final List<double> t;

  factory Pose.fromTransformJson(Map<String, dynamic> j) {
    final r = j['rotation'] as Map<String, dynamic>, p = j['translation'] as Map<String, dynamic>;
    double d(Map<String, dynamic> m, String k) => (m[k] as num).toDouble();
    return Pose([d(r, 'x'), d(r, 'y'), d(r, 'z'), d(r, 'w')], [d(p, 'x'), d(p, 'y'), d(p, 'z')]);
  }

  Map<String, dynamic> toTransformJson() => {
        'translation': {'x': t[0], 'y': t[1], 'z': t[2]},
        'rotation': {'x': q[0], 'y': q[1], 'z': q[2], 'w': q[3]},
      };

  // From a column-major 4x4 matrix (ARKit simd_float4x4 and ARCore Pose.toMatrix both use column-major).
  factory Pose.fromColumnMajor(List<double> m) {
    final r = [
      [m[0], m[4], m[8]],
      [m[1], m[5], m[9]],
      [m[2], m[6], m[10]],
    ];
    return Pose(_quatFromMatrix(r), [m[12], m[13], m[14]]);
  }

  // World-from-camera of an ARKit/ARCore camera (OpenGL axes: x right, y up, looking along -z) expressed with
  // OpenCV camera axes (x right, y down, looking along +z), as Placeframe's OPENCV axis convention expects.
  Pose withOpenCvCameraAxes() => Pose(_mul(q, const [1.0, 0.0, 0.0, 0.0]), t); // 180° about camera x

  Pose inverse() {
    final qi = [-q[0], -q[1], -q[2], q[3]];
    final ti = _rotate(qi, t);
    return Pose(qi, [-ti[0], -ti[1], -ti[2]]);
  }

  // this ∘ o: the transform applying o first, then this.
  Pose operator *(Pose o) {
    final r = _rotate(q, o.t);
    return Pose(_mul(q, o.q), [r[0] + t[0], r[1] + t[1], r[2] + t[2]]);
  }

  // The rotation as a row-major 3x3 matrix, for transforming many points.
  List<double> get rotationMatrix {
    final x = q[0], y = q[1], z = q[2], w = q[3];
    return [
      1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
      2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
      2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
    ];
  }

  // Rotation angle between the two orientations, radians.
  double angleTo(Pose o) {
    final d = (q[0] * o.q[0] + q[1] * o.q[1] + q[2] * o.q[2] + q[3] * o.q[3]).abs();
    return 2 * math.acos(math.min(1.0, d));
  }

  // The rigid motion that moves [from] the fraction [k] of the way to [to], rotating about from's position:
  // applied to from it gives from.t + k (to.t - from.t), with k of the rotation from→to.
  static Pose nudge(Pose from, Pose to, double k) {
    var r = _mul(to.q, [-from.q[0], -from.q[1], -from.q[2], from.q[3]]);
    if (r[3] < 0) r = [-r[0], -r[1], -r[2], -r[3]];
    final half = math.acos(math.min(1.0, r[3])), s = math.sin(half);
    final qk = s < 1e-9
        ? const [0.0, 0.0, 0.0, 1.0]
        : [r[0] / s * math.sin(k * half), r[1] / s * math.sin(k * half), r[2] / s * math.sin(k * half), math.cos(k * half)];
    final rf = _rotate(qk, from.t);
    return Pose(qk, [for (var i = 0; i < 3; i++) from.t[i] + k * (to.t[i] - from.t[i]) - rf[i]]);
  }

  double distanceTo(Pose o) =>
      math.sqrt(math.pow(t[0] - o.t[0], 2) + math.pow(t[1] - o.t[1], 2) + math.pow(t[2] - o.t[2], 2));

  static List<double> _mul(List<double> a, List<double> b) => [
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
      ];

  static List<double> _rotate(List<double> q, List<double> v) {
    final r = _mul(_mul(q, [v[0], v[1], v[2], 0]), [-q[0], -q[1], -q[2], q[3]]);
    return [r[0], r[1], r[2]];
  }

  static List<double> _quatFromMatrix(List<List<double>> r) {
    final tr = r[0][0] + r[1][1] + r[2][2];
    double x, y, z, w;
    if (tr > 0) {
      final s = math.sqrt(tr + 1) * 2;
      w = s / 4;
      x = (r[2][1] - r[1][2]) / s;
      y = (r[0][2] - r[2][0]) / s;
      z = (r[1][0] - r[0][1]) / s;
    } else if (r[0][0] > r[1][1] && r[0][0] > r[2][2]) {
      final s = math.sqrt(1 + r[0][0] - r[1][1] - r[2][2]) * 2;
      w = (r[2][1] - r[1][2]) / s;
      x = s / 4;
      y = (r[0][1] + r[1][0]) / s;
      z = (r[0][2] + r[2][0]) / s;
    } else if (r[1][1] > r[2][2]) {
      final s = math.sqrt(1 + r[1][1] - r[0][0] - r[2][2]) * 2;
      w = (r[0][2] - r[2][0]) / s;
      x = (r[0][1] + r[1][0]) / s;
      y = s / 4;
      z = (r[1][2] + r[2][1]) / s;
    } else {
      final s = math.sqrt(1 + r[2][2] - r[0][0] - r[1][1]) * 2;
      w = (r[1][0] - r[0][1]) / s;
      x = (r[0][2] + r[2][0]) / s;
      y = (r[1][2] + r[2][1]) / s;
      z = s / 4;
    }
    return [x, y, z, w];
  }
}
