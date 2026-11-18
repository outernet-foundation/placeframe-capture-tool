import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import 'ar_frames.dart';

// A capture on disk, in Placeframe's capture format (the same as the Unity capture tool and the Insta360 tools):
//   manifest.json, rig0/frames.csv (timestamp,tx,ty,tz,qx,qy,qz,qw: world-from-camera, OpenCV camera axes),
//   `rig0/camera0/<timestamp>.jpg`, and location.json with the best GPS fix seen while recording.
class CaptureSession {
  CaptureSession._(this.dir, this.id);

  final Directory dir;
  final String id;
  int frames = 0;
  // What the AR platform reported for every frame received, e.g. {"normal": 120, "limited EXCESSIVE_MOTION": 4}:
  // a capture with no good frames says why.
  final Map<String, int> tracking = {};
  int received = 0;
  String _lastState = '';
  Map<String, dynamic>? _camera;
  Position? _bestFix;
  IOSink? _poses;
  int? _lastTimestampMs;

  static Future<Directory> root() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/captures');
    await d.create(recursive: true);
    return d;
  }

  static Future<CaptureSession> start() async {
    final id = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final dir = Directory('${(await root()).path}/$id');
    await Directory('${dir.path}/rig0/camera0').create(recursive: true);
    final s = CaptureSession._(dir, id);
    s._poses = File('${dir.path}/rig0/frames.csv').openWrite()..writeln('timestamp,tx,ty,tz,qx,qy,qz,qw');
    return s;
  }

  Future<void> addFrame(ArFrame f) async {
    received++;
    final state = f.trackingOk ? 'normal' : '${f.tracking} ${f.trackingReason}'.trim();
    tracking[state] = (tracking[state] ?? 0) + 1;
    if (state != _lastState) {
      debugPrint('PF: capture tracking $state (frame $received, $frames kept so far)');
      _lastState = state;
    }
    if (!f.trackingOk) return; // poses during limited tracking are unreliable; skip them
    final ts = (f.timestamp * 1000).round();
    if (ts == _lastTimestampMs) return;
    _lastTimestampMs = ts;
    _camera ??= f.cameraConfig;
    await File('${dir.path}/rig0/camera0/$ts.jpg').writeAsBytes(f.jpeg);
    final p = f.worldFromCamera;
    _poses!.writeln('$ts,${p.t[0]},${p.t[1]},${p.t[2]},${p.q[0]},${p.q[1]},${p.q[2]},${p.q[3]}');
    frames++;
  }

  // "120 normal, 4 limited EXCESSIVE_MOTION": the tracking states of the frames received.
  String describeTracking() => tracking.entries.map((e) => '${e.value} ${e.key}').join(', ');

  void addFix(Position fix) {
    if (_bestFix == null || fix.accuracy < _bestFix!.accuracy) _bestFix = fix;
  }

  // Finishes the capture and writes it as a tar ready to upload.
  Future<File> finish(double intervalSeconds) async {
    await _poses!.close();
    if (_camera == null) {
      throw StateError(received == 0
          ? 'No camera frames arrived from the AR session'
          : 'No frames with good tracking were recorded: $received frames received, ${describeTracking()}');
    }
    await File('${dir.path}/manifest.json').writeAsString(jsonEncode({
      'axis_convention': 'OPENCV',
      'capture_interval_seconds': intervalSeconds,
      'rigs': [
        {
          'id': 'rig0',
          'cameras': [
            {
              'id': 'camera0',
              'ref_sensor': true,
              'rotation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
              'translation': {'x': 0.0, 'y': 0.0, 'z': 0.0},
              'camera_config': _camera,
            }
          ],
        }
      ],
    }));
    final fix = _bestFix;
    if (fix != null) {
      // The AR world is y-up and is kept as the capture's world (OPENCV convention changes camera axes only).
      await File('${dir.path}/location.json').writeAsString(jsonEncode({
        'latitude': fix.latitude,
        'longitude': fix.longitude,
        'altitude': fix.altitude,
        'horizontal_accuracy': fix.accuracy,
        'vertical_accuracy': fix.altitudeAccuracy,
        'map_up_axis': 'y',
        'source': 'placeframe_mobile (${Platform.operatingSystem})',
      }));
    }
    final tar = File('${dir.path}.tar');
    final encoder = TarFileEncoder()..create(tar.path);
    await encoder.addDirectory(dir, includeDirName: false);
    await encoder.close();
    return tar;
  }

  static Future<void> delete(String id) async {
    final root = (await CaptureSession.root()).path;
    for (final e in [Directory('$root/$id'), File('$root/$id.tar'), File('$root/$id.json')]) {
      if (await e.exists()) await e.delete(recursive: true);
    }
  }
}
