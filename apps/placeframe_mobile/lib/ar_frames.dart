import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/services.dart';

import 'geo.dart';

// One camera frame from the platform's AR tracking (ARKit on iOS, ARCore on Android), no AR view involved.
class ArFrame {
  ArFrame(this.jpeg, this.width, this.height, this.fx, this.fy, this.cx, this.cy, this.worldFromCamera, this.timestamp,
      this.tracking,
      {this.trackingReason = '', this.landmarks = const []});

  factory ArFrame.fromMap(Map<dynamic, dynamic> m) {
    final pose = (m['pose'] as List<dynamic>).map((v) => (v as num).toDouble()).toList();
    double d(String k) => (m[k] as num).toDouble();
    return ArFrame(m['jpeg'] as Uint8List, (m['width'] as num).toInt(), (m['height'] as num).toInt(), d('fx'), d('fy'),
        d('cx'), d('cy'), Pose.fromColumnMajor(pose).withOpenCvCameraAxes(), d('timestamp'), m['tracking'] as String,
        trackingReason: (m['tracking_reason'] as String?) ?? '',
        landmarks: ((m['landmarks'] as List<dynamic>?) ?? const []).map((v) => (v as num).toDouble()).toList());
  }

  final Uint8List jpeg; // the camera image as the sensor delivers it (not rotated to the screen)
  final int width, height;
  final double fx, fy, cx, cy; // intrinsics of this image, pixels
  final Pose worldFromCamera; // AR world (y up, metres) from camera, OpenCV camera axes
  final double timestamp; // seconds, platform clock
  final String tracking; // "normal" | "limited" | "not_available"
  final String trackingReason; // why tracking is not normal (e.g. EXCESSIVE_MOTION); empty when it is
  final List<double> landmarks; // the AR platform's current 3D feature points: x, y, z per point, AR world (y up)

  bool get trackingOk => tracking == 'normal';

  // Which way the sensor image must be turned so the scene is upright, from where gravity's "up" points in the
  // image. Placeframe's features are not rotation invariant and maps are built from upright images, so a phone
  // held in portrait (sensor image sideways) only localizes when the server is told to turn the image.
  String get orientation {
    final r = worldFromCamera.rotationMatrix;
    final upX = r[3], upY = r[4]; // world +y in camera axes (x right, y down)
    if (upY.abs() >= upX.abs()) return upY < 0 ? 'TOP_LEFT' : 'BOTTOM_RIGHT';
    return upX > 0 ? 'LEFT_BOTTOM' : 'RIGHT_TOP';
  }

  // The camera the server localizes (the image turned upright) from this camera: a rotation about the optical axis.
  // Composing the returned map-from-camera with it gives the pose of this (sensor) camera.
  Pose get uprightFromCamera => switch (orientation) {
        'RIGHT_TOP' => const Pose([0, 0, math.sqrt1_2, math.sqrt1_2], [0, 0, 0]),
        'LEFT_BOTTOM' => const Pose([0, 0, -math.sqrt1_2, math.sqrt1_2], [0, 0, 0]),
        'BOTTOM_RIGHT' => const Pose([0, 0, 1, 0], [0, 0, 0]),
        _ => const Pose([0, 0, 0, 1], [0, 0, 0]),
      };

  // Placeframe camera_config for this frame: the sensor image and intrinsics, with the turn the server applies.
  Map<String, dynamic> get cameraConfig => {
        'width': width,
        'height': height,
        'orientation': orientation,
        'fx': fx,
        'fy': fy,
        'cx': cx,
        'cy': cy,
      };
}

// The device pose without an image: AR world (y up, metres) from camera, OpenCV camera axes.
class ArPose {
  ArPose(this.worldFromCamera, this.timestamp, this.tracking, {this.trackingReason = ''});

  factory ArPose.fromMap(Map<dynamic, dynamic> m) => ArPose(
      Pose.fromColumnMajor((m['pose'] as List<dynamic>).map((v) => (v as num).toDouble()).toList()).withOpenCvCameraAxes(),
      (m['timestamp'] as num).toDouble(),
      m['tracking'] as String,
      trackingReason: (m['tracking_reason'] as String?) ?? '');

  final Pose worldFromCamera;
  final double timestamp;
  final String tracking;
  final String trackingReason;

  bool get trackingOk => tracking == 'normal';
}

// Platform channel to the native AR session. Frames arrive at most every [intervalSeconds].
class ArFrames {
  static const _methods = MethodChannel('placeframe/ar');
  static const _events = EventChannel('placeframe/ar/frames');

  static Stream<Map<dynamic, dynamic>>? _eventMaps;

  static Future<void> start({required double intervalSeconds, int jpegQuality = 90}) =>
      _methods.invokeMethod('start', {'interval': intervalSeconds, 'quality': jpegQuality});

  static Future<void> stop() => _methods.invokeMethod('stop');

  static Future<bool> available() async => (await _methods.invokeMethod<bool>('available')) ?? false;

  static Stream<Map<dynamic, dynamic>> get _all =>
      _eventMaps ??= _events.receiveBroadcastStream().map((e) => e as Map<dynamic, dynamic>);

  // Camera images with their pose, at most every intervalSeconds.
  static Stream<ArFrame> get frames => _all.where((m) => m['jpeg'] != null).map(ArFrame.fromMap);

  // Every pose the platform reports: with each image, and pose-only events in between (Android: 10 Hz).
  static Stream<ArPose> get poses => _all.map(ArPose.fromMap);
}
