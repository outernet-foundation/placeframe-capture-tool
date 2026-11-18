import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'config.dart';
import 'geo.dart';

class MapInfo {
  MapInfo(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get name => (json['name'] as String?) ?? id.substring(0, 8);
  bool get active => json['active'] == true;
  String get createdAt => (json['created_at'] as String?) ?? '';
  // Where the map is listed in the map picker ("a/b"), from the optional map-updater; empty: top level.
  String folder = '';
  // Placed on the globe (from the capture's GPS); unplaced maps keep their position at the Earth's centre.
  bool get placed => ['position_x', 'position_y', 'position_z'].any((k) => ((json[k] as num?) ?? 0) != 0);
  String get reconstructionId => json['reconstruction_id'] as String;
}

// The server's tracked estimate for a localization session (POST /localize/track): the most probable place after
// the latest frame, with the alignment that turns any later odometry pose into a map pose.
class TrackedLocalization {
  TrackedLocalization(this.json);

  // From a single-frame result (POST /localize, for servers without /localize/track): the frame's best match gives
  // the alignment (odometry pose of the camera × its map pose inverted), and its confidence stands in for the
  // tracker's probability.
  factory TrackedLocalization.fromSingleFrame(Pose odomFromCamera, List<Localization> found) {
    if (found.isEmpty) {
      return TrackedLocalization(
          {'probability': 0.0, 'fixes': 0, 'hypotheses': 0, 'unknown': 1.0, 'frame_candidates': 0, 'frame_agreed': false});
    }
    final best = found.reduce((a, b) => a.confidence >= b.confidence ? a : b);
    return TrackedLocalization({
      'map_id': best.mapId,
      'probability': best.confidence,
      'fixes': 1,
      'hypotheses': found.length,
      'unknown': 1 - best.confidence,
      'odometry_from_map_transform': (odomFromCamera * best.mapFromCamera.inverse()).toTransformJson(),
      'frame_candidates': found.length,
      'frame_agreed': true,
      'frame_confidence': best.confidence,
      'frame_inliers': best.metrics['num_inliers'] as int?,
      'frame_source': 'single frame',
    });
  }

  final Map<String, dynamic> json;
  String? get mapId => json['map_id'] as String?;
  double get probability => (json['probability'] as num).toDouble();
  double? get sigmaM => (json['sigma_m'] as num?)?.toDouble();
  int get fixes => json['fixes'] as int;
  int get hypotheses => json['hypotheses'] as int;
  double get unknown => (json['unknown'] as num).toDouble();
  Pose? get odomFromMap => _pose('odometry_from_map_transform');
  int get frameCandidates => json['frame_candidates'] as int;
  bool get frameAgreed => json['frame_agreed'] as bool;
  double? get frameConfidence => (json['frame_confidence'] as num?)?.toDouble();
  int? get frameInliers => json['frame_inliers'] as int?;
  String? get frameSource => json['frame_source'] as String?;

  Pose? _pose(String key) {
    final j = json[key] as Map<String, dynamic>?;
    return j == null ? null : Pose.fromTransformJson(j);
  }
}

class Localization {
  Localization(this.mapId, this.mapFromCamera, this.confidence, this.latencyMs, this.metrics);
  final String mapId;
  final Pose mapFromCamera; // OpenCV camera axes (x right, y down, z forward) in the map's frame
  final double confidence;
  final int latencyMs;
  final Map<String, dynamic> metrics;
}

// The Placeframe API calls this app uses (same endpoints as the Unity client and the Python tools).
class PlaceframeApi {
  PlaceframeApi(this.config, this.auth);

  final Config config;
  final Auth auth;
  final http.Client _client = http.Client();

  Future<Map<String, String>> _headers() async => {'Authorization': 'Bearer ${await auth.token()}'};

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse('${config.serverUrl}$path').replace(queryParameters: query);

  Future<dynamic> _get(String path, [Map<String, String>? query]) async {
    final r = await _client.get(_uri(path, query), headers: await _headers());
    return _check(r);
  }

  Future<dynamic> _postJson(String path, Map<String, dynamic> body) async {
    final r = await _client.post(_uri(path),
        headers: {...await _headers(), 'Content-Type': 'application/json'}, body: jsonEncode(body));
    return _check(r);
  }

  dynamic _check(http.Response r) {
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  // All maps, or (with a location) the maps with a camera within [radiusMeters] of it.
  Future<List<MapInfo>> maps({double? latitude, double? longitude, double altitude = 0, double? radiusMeters}) async {
    Map<String, String>? query;
    if (latitude != null && longitude != null) {
      final p = ecefFromGeodetic(latitude, longitude, altitude);
      query = {
        'position_x': '${p[0]}',
        'position_y': '${p[1]}',
        'position_z': '${p[2]}',
        'radius': '${radiusMeters ?? config.mapRadiusMeters}',
      };
    }
    final list = await _get('/localization-maps', query) as List<dynamic>;
    final maps = list.map((m) => MapInfo(m as Map<String, dynamic>)).toList();
    final folders = await _folders();
    for (final m in maps) {
      m.folder = folders[m.id] ?? '';
    }
    return maps;
  }

  // Map folders from the optional map-updater (see Config.mapperUrl); none when it is unset or unreachable.
  Future<Map<String, String>> _folders() async {
    if (config.mapperUrl.isEmpty) return {};
    try {
      final r = await _client.get(Uri.parse('${config.mapperUrl}/maps'), headers: await _headers());
      if (r.statusCode != 200) return {};
      return {
        for (final m in (jsonDecode(r.body) as List<dynamic>).cast<Map<String, dynamic>>())
          if (m['id'] is String) m['id'] as String: (m['folder'] as String?) ?? ''
      };
    } catch (_) {
      return {};
    }
  }

  // A reconstruction's 3D points in the map frame (OpenCV axes): x, y, z per point, at most [limit] points (evenly
  // spaced through the list). The response is a little-endian uint32 count, then float32 positions, then colours.
  Future<Float32List?> mapPoints(String reconstructionId, {int limit = 80000}) async {
    final r = await _client.get(_uri('/reconstructions/$reconstructionId/points', {'axis_convention': 'OPENCV'}),
        headers: await _headers());
    if (r.statusCode != 200 || r.bodyBytes.length < 4) return null;
    final b = ByteData.sublistView(r.bodyBytes);
    final count = b.getUint32(0, Endian.little);
    if (r.bodyBytes.length < 4 + count * 12) return null;
    final n = count < limit ? count : limit;
    final out = <double>[];
    for (var k = 0; k < n; k++) {
      final o = 4 + (k * count ~/ n) * 12; // evenly spaced through the list
      out..add(b.getFloat32(o, Endian.little))..add(b.getFloat32(o + 4, Endian.little))..add(b.getFloat32(o + 8, Endian.little));
    }
    return Float32List.fromList(out);
  }

  // One frame of a tracked session: the image, its camera and its odometry pose (OpenCV camera axes, sensor image
  // orientation; the server turns the image upright and accounts for it).
  Future<TrackedLocalization> localizeTracked(Uint8List jpeg, Map<String, dynamic> cameraConfig, List<String> mapIds,
      String sessionId, Pose odomFromCamera) async {
    final req = http.MultipartRequest('POST', _uri('/localize/track'))
      ..headers.addAll(await _headers())
      ..fields['map_ids'] = jsonEncode(mapIds)
      ..fields['camera_config'] = jsonEncode(cameraConfig)
      ..fields['session_id'] = sessionId
      ..fields['odometry_from_camera'] = jsonEncode(odomFromCamera.toTransformJson())
      ..files.add(http.MultipartFile.fromBytes('image', jpeg, filename: 'frame.jpg'));
    final r = await http.Response.fromStream(await _client.send(req));
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
    return TrackedLocalization(jsonDecode(r.body) as Map<String, dynamic>);
  }

  // [uprightFromCamera]: the turn the server applied to the image (see camera_config orientation); the returned poses
  // are of the turned camera, so composing with it gives the pose of the camera that took the image.
  Future<List<Localization>> localize(Uint8List jpeg, Map<String, dynamic> cameraConfig, List<String> mapIds,
      {Pose uprightFromCamera = const Pose([0, 0, 0, 1], [0, 0, 0])}) async {
    final t = Stopwatch()..start();
    final req = http.MultipartRequest('POST', _uri('/localize'))
      ..headers.addAll(await _headers())
      ..fields['map_ids'] = jsonEncode(mapIds)
      ..fields['camera_config'] = jsonEncode(cameraConfig)
      ..fields['axis_convention'] = 'OPENCV'
      ..files.add(http.MultipartFile.fromBytes('image', jpeg, filename: 'frame.jpg'));
    final r = await http.Response.fromStream(await _client.send(req));
    final latency = t.elapsedMilliseconds;
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
    final list = (jsonDecode(r.body) as List<dynamic>).cast<Map<String, dynamic>>();
    return list.map((m) {
      final tr = m['camera_from_map_transform'] as Map<String, dynamic>;
      final metrics = (m['metrics'] as Map<String, dynamic>?) ?? {};
      return Localization(m['id'] as String, Pose.fromTransformJson(tr).inverse() * uprightFromCamera,
          ((metrics['confidence_loose'] as num?) ?? 0).toDouble(), latency, metrics);
    }).toList();
  }

  // Uploads a capture tar; returns the capture session id.
  Future<String> uploadCapture(File tar, String name, DateTime recordedAt) async {
    final req = http.MultipartRequest('POST', _uri('/capture_sessions'))
      ..headers.addAll(await _headers())
      ..fields['device_type'] = 'ARFoundation'
      ..fields['name'] = name
      ..fields['recorded_at'] = recordedAt.toUtc().toIso8601String()
      ..files.add(await http.MultipartFile.fromPath('data', tar.path, filename: 'capture.tar'));
    final r = await http.Response.fromStream(await _client.send(req));
    return (_check(r) as Map<String, dynamic>)['id'] as String;
  }

  Future<Map<String, dynamic>> createReconstruction(String captureId, Map<String, dynamic> options) async =>
      await _postJson('/reconstructions', {
        'create': {'capture_session_id': captureId},
        'options': options,
      }) as Map<String, dynamic>;

  // Top-down slices of a map from the map-updater (Config.mapperUrl): grayscale histogram images of its points every
  // `step` metres of height (see the map-updater's mapper/slices.py). Null without a map-updater.
  Future<Map<String, dynamic>?> mapSlices(String mapId) async {
    if (config.mapperUrl.isEmpty) return null;
    final r = await _client.get(Uri.parse('${config.mapperUrl}/maps/$mapId/slices'), headers: await _headers());
    return r.statusCode == 200 ? jsonDecode(r.body) as Map<String, dynamic> : null;
  }

  // One slice image (PNG), or null.
  Future<Uint8List?> mapSliceImage(String mapId, int k) async {
    final r = await _client.get(Uri.parse('${config.mapperUrl}/maps/$mapId/slices/$k.png'), headers: await _headers());
    return r.statusCode == 200 ? r.bodyBytes : null;
  }

  // Asks the map-updater (Config.mapperUrl) to merge an uploaded capture into an existing map; returns its job id.
  Future<String> mergeIntoMap(String captureId, String mapId, String label) async {
    final r = await _client.post(Uri.parse('${config.mapperUrl}/phone-merges'),
        headers: {...await _headers(), 'Content-Type': 'application/json'},
        body: jsonEncode({'capture_session_id': captureId, 'map_id': mapId, 'name': label}));
    return (_check(r) as Map<String, dynamic>)['job_id'] as String;
  }

  // A map-updater job: state ("queued", "running", "succeeded", "failed"), stage, and the new map when done.
  Future<Map<String, dynamic>?> mergeJob(String jobId) async {
    final r = await _client.get(Uri.parse('${config.mapperUrl}/jobs'), headers: await _headers());
    final jobs = (_check(r) as List<dynamic>).cast<Map<String, dynamic>>();
    return jobs.where((j) => j['id'] == jobId || j['job_id'] == jobId).firstOrNull;
  }

  Future<Map<String, dynamic>> reconstruction(String id) async =>
      await _get('/reconstructions/$id') as Map<String, dynamic>;

  // Creates a map from a finished reconstruction. No placement is sent: the server places it from the capture's
  // location.json when the capture carried one.
  Future<MapInfo> createMap(String reconstructionId, String name) async => MapInfo(await _postJson('/localization-maps', {
        'reconstruction_id': reconstructionId,
        'name': name,
        'position_x': 0.0, 'position_y': 0.0, 'position_z': 0.0,
        'rotation_x': 0.0, 'rotation_y': 0.0, 'rotation_z': 0.0, 'rotation_w': 1.0,
        'color': 0,
        'active': true,
      }) as Map<String, dynamic>);
}

class ApiException implements Exception {
  ApiException(this.status, this.body);
  final int status;
  final String body;
  // The server's explanation ("detail"), or the raw body.
  String get detail {
    try {
      final d = (jsonDecode(body) as Map<String, dynamic>)['detail'];
      if (d is String) return d;
    } catch (_) {}
    return body.isEmpty ? 'HTTP $status' : body;
  }

  @override
  String toString() {
    try {
      final detail = (jsonDecode(body) as Map<String, dynamic>)['detail'];
      if (detail != null) return 'HTTP $status: $detail';
    } catch (_) {}
    return 'HTTP $status';
  }
}
