import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'ar_frames.dart';
import 'geo.dart';

// What the capture screen shows while recording: the odometry path, the AR platform's 3D landmarks, the distance
// walked and the current position (AR world: metres, y up; the top-down view is the x/z plane).
class CaptureTrack {
  final List<List<double>> path = []; // x, y, z of the camera, at the pose rate, while tracking is normal
  final List<List<double>> landmarks = []; // x, y, z
  double distance = 0; // metres walked (sum of steps along the path)
  ArFrame? lastFrame;

  static const _maxLandmarks = 30000, _minStep = 0.02;

  void addPose(Pose worldFromCamera) {
    final p = worldFromCamera.t;
    if (path.isNotEmpty) {
      final q = path.last;
      final step = math.sqrt(math.pow(p[0] - q[0], 2) + math.pow(p[1] - q[1], 2) + math.pow(p[2] - q[2], 2));
      if (step < _minStep) return; // standing still: no new point (and no noise added to the distance)
      if (step < 2) distance += step; // a jump of the odometry is not walking
    }
    path.add([p[0], p[1], p[2]]);
  }

  void addFrame(ArFrame f) {
    lastFrame = f;
    final l = f.landmarks;
    for (var i = 0; i + 2 < l.length; i += 3) {
      if (landmarks.length >= _maxLandmarks) landmarks.removeAt(0);
      landmarks.add([l[i], l[i + 1], l[i + 2]]);
    }
  }

  List<double>? get position => path.isEmpty ? null : path.last;
}

// The top-down view: landmarks near the phone's height (grey), the path (blue) and the phone with its heading.
class CaptureTopDown extends CustomPainter {
  CaptureTopDown(this.track, this.heading, this.revision);
  final CaptureTrack track;
  final Pose? heading; // the latest camera pose, for the heading arrow
  final int revision; // repaint when it changes

  static const _slice = 1.2; // metres above/below the phone shown

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF15191E));
    final pos = track.position;
    if (pos == null) return;
    final xs = [...track.path.map((p) => p[0])], zs = [...track.path.map((p) => p[2])];
    final near = track.landmarks.where((l) => (l[1] - pos[1]).abs() <= _slice).toList();
    xs.addAll(near.map((l) => l[0]));
    zs.addAll(near.map((l) => l[2]));
    final minX = xs.reduce(math.min), maxX = xs.reduce(math.max), minZ = zs.reduce(math.min), maxZ = zs.reduce(math.max);
    final span = math.max(4.0, math.max(maxX - minX, maxZ - minZ) * 1.1); // at least 4 m across
    final scale = math.min(size.width, size.height) / span;
    final cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2;
    Offset at(double x, double z) => Offset(size.width / 2 + (x - cx) * scale, size.height / 2 + (z - cz) * scale);

    final dots = Paint()..color = const Color(0xFF8A929E);
    for (final l in near) {
      canvas.drawCircle(at(l[0], l[2]), 1.2, dots);
    }
    if (track.path.length > 1) {
      final line = Path()..moveTo(at(track.path.first[0], track.path.first[2]).dx, at(track.path.first[0], track.path.first[2]).dy);
      for (final p in track.path.skip(1)) {
        final o = at(p[0], p[2]);
        line.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(line, Paint()
        ..color = const Color(0xFF4CC2FF)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke);
    }
    final me = at(pos[0], pos[2]);
    final h = heading;
    if (h != null) {
      final r = h.rotationMatrix; // camera z (forward) in the world
      final fx = r[2], fz = r[8], n = math.sqrt(fx * fx + fz * fz);
      if (n > 1e-6) {
        canvas.drawLine(me, me + Offset(fx / n, fz / n) * 18, Paint()
          ..color = Colors.white
          ..strokeWidth = 3);
      }
    }
    canvas.drawCircle(me, 6, Paint()..color = Colors.white);
    final tp = TextPainter(
        text: TextSpan(text: '${span.toStringAsFixed(1)} m across', style: const TextStyle(color: Color(0xFF8A929E), fontSize: 11)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(6, size.height - tp.height - 4));
  }

  @override
  bool shouldRepaint(CaptureTopDown old) => old.revision != revision;
}
