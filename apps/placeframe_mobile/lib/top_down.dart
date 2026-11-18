import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'geo.dart';

// What the localize screen draws from above. Until the first confident localization: the raw odometry path (AR
// world, y up). After it, everything is drawn in a display frame fixed to the map (the map seen with the odometry's
// gravity-up axis at that first fix), so the map stays still and the path moves onto it: each odometry point is
// placed with the map alignment from the next confident localization after it (the alignment that corrected the
// drift accumulated up to then), the latest alignment for points after the last one. Only what lies within
// ±sliceHalfHeight of the phone is drawn, so other floors don't show.
class TopDownModel {
  final List<List<double>> path = []; // odometry x, y, z
  final List<double> pathTimes = []; // seconds, AR clock
  final Set<int> pathBreaks = {}; // path indices that start a new piece: the odometry jumped (re-anchored) there
  final List<List<double>> _fixes = []; // odometry positions of frames that agreed with the confident place
  final List<double> _fixTimes = [];
  final List<double> _alignmentTimes = [];
  final List<Pose> _displayFromOdom = []; // per confident localization: display-from-map ∘ map-from-odometry
  Pose? displayFromMap; // fixed once the first confident localization arrives
  Pose? current; // odometry from camera, OpenCV axes
  double currentTime = 0;
  Float32List? mapPointsXZ; // display x, z of map points within ±sliceHalfHeight of the phone
  int mapPointCount = 0;
  // Or, from a map-updater, the map as top-down histogram images (slices): the two around the phone's height in the
  // map, blended by [sliceBlend] (0 = only [sliceLower]). [sliceMeta]: their grid (x0, z0, cell metres per pixel).
  Map<String, dynamic>? sliceMeta;
  ui.Image? sliceLower, sliceUpper;
  double sliceBlend = 0, sliceMapY = 0;

  // The phone's position in the map frame (needs the display frame, i.e. a confident localization).
  List<double>? get mapPosition {
    final f = displayFromMap, cur = currentDisplay;
    return f == null || cur == null ? null : (f.inverse() * cur).t;
  }
  double pathLength = 0; // metres moved

  static const sliceHalfHeight = 1.0;
  static const _minStep = 0.05;
  // Odometry moving faster than anyone walks re-anchored itself (ARCore corrects its world frame after relocalizing):
  // the path is not connected across it.
  static const _odometryJumpMetres = 1.0, _odometryJumpSpeed = 3.0;

  bool get registered => displayFromMap != null;

  void addPose(Pose worldFromCamera, double time) {
    current = worldFromCamera;
    currentTime = time;
    final p = worldFromCamera.t;
    if (path.isNotEmpty) {
      final step = Pose(Pose.identity.q, path.last).distanceTo(worldFromCamera);
      if (step < _minStep) return;
      final dt = math.max(time - pathTimes.last, 0.05);
      if (step > _odometryJumpMetres && step / dt > _odometryJumpSpeed) {
        pathBreaks.add(path.length);
      } else {
        pathLength += step;
      }
    }
    path.add(p);
    pathTimes.add(time);
  }

  // A confident localization's map alignment (odometry-from-map) at [time]. Returns true when the display frame
  // was (re)set, so the map points need cutting again.
  // The display frame is set once, at the first fix, and never changes: the map keeps its orientation. When the
  // alignment changes (drift corrected, or a different place), the path before it is re-placed with the new
  // alignment (each point uses the first alignment at or after its time), so it snaps back onto the map.
  bool addAlignment(double time, Pose odomFromMap, List<double> at) {
    final reset = displayFromMap == null;
    if (reset) displayFromMap = odomFromMap;
    _alignmentTimes.add(time);
    _displayFromOdom.add(displayFromMap! * odomFromMap.inverse());
    return reset;
  }

  void addFix(double time, List<double> odomPosition) {
    _fixes.add(odomPosition);
    _fixTimes.add(time);
  }

  Pose? get currentDisplay {
    final c = current;
    if (c == null) return null;
    return _displayFromOdom.isEmpty ? c : _displayFromOdom.last * c;
  }

  Iterable<List<double>> get displayPath => _display(path, pathTimes);

  Iterable<List<double>> get displayFixes => _display(_fixes, _fixTimes);

  // Display positions of odometry positions recorded at increasing [times]: each with the first alignment at or
  // after its time (both lists are in time order, so one pass).
  Iterable<List<double>> _display(List<List<double>> points, List<double> times) sync* {
    if (_displayFromOdom.isEmpty) {
      yield* points;
      return;
    }
    final matrices = [for (final a in _displayFromOdom) (a.rotationMatrix, a.t)];
    var j = 0;
    for (var i = 0; i < points.length; i++) {
      while (j < _alignmentTimes.length - 1 && _alignmentTimes[j] < times[i]) {
        j++;
      }
      final (r, t) = matrices[j];
      final p = points[i];
      yield [
        r[0] * p[0] + r[1] * p[1] + r[2] * p[2] + t[0],
        r[3] * p[0] + r[4] * p[1] + r[5] * p[2] + t[1],
        r[6] * p[0] + r[7] * p[1] + r[8] * p[2] + t[2],
      ];
    }
  }

  void reset() {
    path.clear();
    pathTimes.clear();
    pathBreaks.clear();
    _fixes.clear();
    _fixTimes.clear();
    _alignmentTimes.clear();
    _displayFromOdom.clear();
    displayFromMap = null;
    current = null;
    pathLength = 0;
    mapPointsXZ = null;
    mapPointCount = 0;
    sliceMeta = null;
    sliceLower = sliceUpper = null;
    sliceBlend = 0;
  }

  // Map points (x, y, z in the map frame) in the display frame; only the slice around [height] (display y) is kept.
  void setMapPoints(Float32List xyz, double height) {
    final f = displayFromMap;
    if (f == null) return;
    final r = f.rotationMatrix, t = f.t;
    final out = Float32List(xyz.length ~/ 3 * 2);
    var n = 0;
    for (var i = 0; i + 2 < xyz.length; i += 3) {
      final x = xyz[i], y = xyz[i + 1], z = xyz[i + 2];
      final oy = r[3] * x + r[4] * y + r[5] * z + t[1];
      if ((oy - height).abs() > sliceHalfHeight) continue;
      out[n++] = r[0] * x + r[1] * y + r[2] * z + t[0];
      out[n++] = r[6] * x + r[7] * y + r[8] * z + t[2];
    }
    mapPointsXZ = Float32List.sublistView(out, 0, n);
    mapPointCount = n ~/ 2;
  }
}

class TopDownView extends StatelessWidget {
  const TopDownView({super.key, required this.model, required this.revision});
  final TopDownModel model;
  final int revision; // changes whenever the model does, so the painter repaints

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: 1,
          child: CustomPaint(painter: _TopDownPainter(model, revision), child: const SizedBox.expand()),
        ),
      );
}

class _TopDownPainter extends CustomPainter {
  _TopDownPainter(this.m, this.revision);
  final TopDownModel m;
  final int revision;

  static const _span = 14.0; // metres across the view; the view follows the phone and never rotates

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF15191E));
    final cur = m.currentDisplay;
    if (cur == null) {
      _label(canvas, size, 'Waiting for AR tracking…');
      return;
    }
    // Centred on the phone at a fixed scale: the map only translates as the phone moves.
    bool inSlice(List<double> p) => (p[1] - cur.t[1]).abs() <= TopDownModel.sliceHalfHeight;
    final path3 = m.displayPath.toList();
    final scale = size.shortestSide / _span;
    final cx = cur.t[0], cz = cur.t[2];
    Offset s(double x, double z) => Offset(size.width / 2 + (x - cx) * scale, size.height / 2 + (z - cz) * scale);

    _drawSlices(canvas, size, scale, cx, cz);
    final pts = m.sliceMeta == null ? m.mapPointsXZ : null;
    if (pts != null && pts.isNotEmpty) {
      final screen = Float32List(pts.length);
      for (var i = 0; i < pts.length; i += 2) {
        screen[i] = size.width / 2 + (pts[i] - cx) * scale;
        screen[i + 1] = size.height / 2 + (pts[i + 1] - cz) * scale;
      }
      canvas.drawRawPoints(ui.PointMode.points, screen,
          Paint()
            ..color = const Color(0x99B0BEC5)
            ..strokeWidth = 1.5);
    }
    _scaleBar(canvas, size, scale);

    // The path, broken wherever it leaves the height slice (stairs to another floor).
    final path = Path();
    var drawing = false;
    for (final (i, p) in path3.indexed) {
      if (!inSlice(p) || m.pathBreaks.contains(i)) {
        drawing = false;
      }
      if (!inSlice(p)) {
        drawing = false;
        continue;
      }
      final q = s(p[0], p[2]);
      drawing ? path.lineTo(q.dx, q.dy) : path.moveTo(q.dx, q.dy);
      drawing = true;
    }
    {
      canvas.drawPath(path, Paint()
        ..color = const Color(0xFF42A5F5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5);
    }
    for (final p in m.displayFixes.where(inSlice)) {
      canvas.drawCircle(s(p[0], p[2]), 5, Paint()..color = const Color(0xFF66BB6A));
    }
    // The phone: a dot with its viewing direction (the camera's +z axis, projected onto the floor).
    final here = s(cur.t[0], cur.t[2]);
    final r = cur.rotationMatrix;
    final dir = Offset(r[2], r[8]);
    if (dir.distance > 1e-3) {
      canvas.drawLine(here, here + dir / dir.distance * 22, Paint()
        ..color = Colors.white
        ..strokeWidth = 3);
    }
    canvas.drawCircle(here, 6, Paint()..color = Colors.white);
  }

  // The two map slices around the phone's height, blended. A slice pixel (u, v) is the map cell at
  // x = x0 + (u + ½) cell, z = z0 + (v + ½) cell (at the phone's map height); the display frame turns and shifts
  // the map's x/z plane, so one affine transform takes the image to the screen.
  void _drawSlices(Canvas canvas, Size size, double scale, double cx, double cz) {
    final meta = m.sliceMeta, f = m.displayFromMap;
    if (meta == null || f == null) return;
    final c = (meta['cell'] as num).toDouble(), x0 = (meta['x0'] as num).toDouble(), z0 = (meta['z0'] as num).toDouble();
    final r = f.rotationMatrix, t = f.t, y = m.sliceMapY;
    final a = scale * r[0] * c, b = scale * r[2] * c, d = scale * r[6] * c, e = scale * r[8] * c;
    final tx = size.width / 2 + scale * (r[0] * (x0 + c / 2) + r[2] * (z0 + c / 2) + r[1] * y + t[0] - cx);
    final ty = size.height / 2 + scale * (r[6] * (x0 + c / 2) + r[8] * (z0 + c / 2) + r[7] * y + t[2] - cz);
    canvas.save();
    canvas.transform(Float64List.fromList([a, d, 0, 0, b, e, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1]));
    void draw(ui.Image? img, double weight) {
      if (img == null || weight <= 0.01) return;
      canvas.drawImage(img, Offset.zero, Paint()
        ..filterQuality = FilterQuality.low
        ..blendMode = BlendMode.plus // the weighted sum of the two slices, over the background
        ..colorFilter = ColorFilter.mode(const Color(0xFFB0BEC5).withValues(alpha: weight), BlendMode.modulate));
    }

    draw(m.sliceLower, 1 - m.sliceBlend);
    draw(m.sliceUpper, m.sliceBlend);
    canvas.restore();
  }

  void _label(Canvas canvas, Size size, String text) => _text(canvas, text, Offset(12, size.height / 2 - 8));

  void _scaleBar(Canvas canvas, Size size, double scale) {
    final metres = scale * 1.0 > 40 ? 1.0 : (scale * 5 > 40 ? 5.0 : 10.0);
    final y = size.height - 14, x0 = 12.0, x1 = x0 + metres * scale;
    canvas.drawLine(Offset(x0, y), Offset(x1, y), Paint()
      ..color = Colors.white70
      ..strokeWidth = 2);
    _text(canvas, '${metres.round()} m', Offset(x1 + 6, y - 8));
  }

  void _text(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
        text: TextSpan(text: text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_TopDownPainter old) => old.revision != revision;
}
