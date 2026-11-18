import 'dart:math' as math;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api.dart';
import 'ar_frames.dart';
import 'auth.dart';
import 'capture.dart';
import 'config.dart';
import 'geo.dart';
import 'capture_view.dart';
import 'map_picker.dart';
import 'top_down.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await Config.load();
  final auth = Auth(config);
  if (Config.testPassword.isNotEmpty && config.serverUrl.isNotEmpty) {
    try {
      await auth.login(config.username, Config.testPassword);
      debugPrint('PF: auto-login ok as ${config.username}');
    } catch (e) {
      debugPrint('PF: auto-login failed: $e');
    }
  }
  runApp(PlaceframeApp(config: config, auth: auth, api: PlaceframeApi(config, auth)));
}

class PlaceframeApp extends StatefulWidget {
  const PlaceframeApp({super.key, required this.config, required this.auth, required this.api});
  final Config config;
  final Auth auth;
  final PlaceframeApi api;

  @override
  State<PlaceframeApp> createState() => _PlaceframeAppState();
}

class _PlaceframeAppState extends State<PlaceframeApp> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Placeframe',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4CC2FF), brightness: Brightness.dark)),
      home: !widget.auth.loggedIn
          ? LoginScreen(config: widget.config, auth: widget.auth, onLoggedIn: () => setState(() {}))
          : Scaffold(
              appBar: AppBar(title: Text(['Localize', 'Capture', 'Settings'][_tab])),
              body: IndexedStack(index: _tab, children: [
                LocalizeScreen(config: widget.config, api: widget.api),
                CaptureScreen(config: widget.config, api: widget.api),
                SettingsScreen(config: widget.config, auth: widget.auth, onLogout: () => setState(() {})),
              ]),
              bottomNavigationBar: NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.my_location), label: 'Localize'),
                  NavigationDestination(icon: Icon(Icons.videocam), label: 'Capture'),
                  NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
                ],
              ),
            ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ login

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.config, required this.auth, required this.onLoggedIn});
  final Config config;
  final Auth auth;
  final VoidCallback onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final _server = TextEditingController(text: widget.config.serverUrl);
  late final _user = TextEditingController(text: widget.config.username);
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.config.serverUrl = _server.text;
    try {
      await widget.auth.login(_user.text, _password.text);
      widget.onLoggedIn();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Placeframe')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          TextField(
              controller: _server,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Server URL', hintText: 'https://your-placeframe-host')),
          TextField(controller: _user, decoration: const InputDecoration(labelText: 'Username')),
          TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => _login()),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _login, child: Text(_busy ? 'Logging in…' : 'Log in')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        ]),
      );
}

// ------------------------------------------------------------------------------------------------ localize

class LocalizeScreen extends StatefulWidget {
  // How often a localized phone is queried while its localizations agree (the adaptive rate; shown in Settings).
  static const trackingIntervalSeconds = 5.0;

  const LocalizeScreen({super.key, required this.config, required this.api});
  final Config config;
  final PlaceframeApi api;

  @override
  State<LocalizeScreen> createState() => _LocalizeScreenState();
}

class _LocalizeScreenState extends State<LocalizeScreen> {
  List<MapInfo> _maps = [];
  final Set<String> _selected = {};
  bool _nearby = Config.defaultMap.isEmpty, _loadingMaps = false, _running = false, _inFlight = false;
  bool _serverTracks = true; // false once the server answers /localize/track with 404 (single-frame mode)
  // Adaptive query rate: once the place is confirmed and queries keep agreeing, odometry carries the pose and a
  // query every _trackingInterval keeps it registered; any disagreement or odometry jump goes back to every frame.
  // On a recorded 5-minute walk this sent 4x fewer queries than one per second with the same accuracy.
  bool _lastQueryAgreed = false;
  double _lastSentAt = -1e9; // AR clock seconds
  static const _trackingInterval = LocalizeScreen.trackingIntervalSeconds, _trackingProbability = 0.95;
  // Frames come from the AR session at most this often; which of them are sent is decided above (adaptive rate).
  static const _frameIntervalSeconds = 0.5;
  static const _odometryJumpMetres = 1.0, _odometryJumpSpeed = 3.0;
  Position? _fix;
  String? _status;
  Localization? _last;
  ArFrame? _lastFrame;
  int _attempts = 0, _successes = 0;
  StreamSubscription<ArFrame>? _sub;
  StreamSubscription<ArPose>? _poseSub;
  final _view = TopDownModel();
  int _viewRevision = 0;
  final Map<String, Float32List?> _mapPoints = {}; // map id -> points (null: none available)
  // With a map-updater: the map as top-down slices (see TopDownModel.sliceMeta), not points.
  final Map<String, Map<String, dynamic>?> _slicesMeta = {}; // map id -> slice description (null: none)
  final Map<String, ui.Image?> _sliceImages = {}; // "map id/k" -> decoded slice (null while loading or missing)
  TrackedLocalization? _tracked; // the server's estimate after the latest frame
  String _sessionId = ''; // one tracking session per start: odometry restarts with the AR session
  static const _showProbability = 0.8; // draw the place and its map points from this probability
  double? _sliceHeight; // phone height the shown map-point slice was cut at
  final _ui = ValueNotifier<int>(0); // bumped on every change; the full-screen localizing page listens
  DateTime? _startedAt, _lastLocalizedAt;
  String? _lastReason, _lastOrientation;
  int? _lastLatencyMs, _lastBytes;
  ArPose? _lastPose;
  int _poses = 0;
  final List<String> _log = []; // recent outcomes, newest first

  @override
  void initState() {
    super.initState();
    _loadMaps();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _loadMaps() async {
    setState(() {
      _loadingMaps = true;
      _status = null;
    });
    try {
      if (_nearby) {
        _fix = await currentFix();
        _maps = _fix == null
            ? []
            : await widget.api.maps(latitude: _fix!.latitude, longitude: _fix!.longitude, altitude: _fix!.altitude);
        if (_fix == null) _status = 'No location: allow location access, or show all maps';
      } else {
        _maps = await widget.api.maps();
      }
      if (_nearby) _maps = _maps.where((m) => m.placed).toList(); // maps created without GPS have no place
      _maps.sort((a, b) => b.createdAt.compareTo(a.createdAt)); // the most recently built (merged) first
      _selected.retainAll(_maps.map((m) => m.id));
      // The maps selected last time (kept on the phone); the default map only before anything was ever selected.
      final saved = widget.config.selectedMaps;
      if (_selected.isEmpty && saved != null) _selected.addAll(saved.where((id) => _maps.any((m) => m.id == id)));
      if (_selected.isEmpty && saved == null && Config.defaultMap.isNotEmpty) {
        // The newest matching map: a rebuilt map keeps its predecessor's name with a suffix.
        final matches = _maps.where((m) => m.active && m.name.contains(Config.defaultMap)).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        _selected.addAll(matches.map((m) => m.id).take(1));
      }
      if (_selected.isEmpty) _selected.addAll(_maps.where((m) => m.active).map((m) => m.id).take(_nearby ? 4 : 1));
      debugPrint('PF: ${_maps.length} maps: ${_maps.map((m) => '${m.name}${m.active ? '' : ' (inactive)'}').join(' | ')}');
      debugPrint('PF: selected ${_maps.where((m) => _selected.contains(m.id)).map((m) => m.name).join(', ')}');
    } catch (e) {
      _status = '$e';
    } finally {
      if (mounted) setState(() => _loadingMaps = false);
    }
  }

  Future<void> _start() async {
    if (_selected.isEmpty) return setState(() => _status = 'Select at least one map');
    if (!await cameraAllowed()) return setState(() => _status = 'Camera permission is needed');
    _attempts = _successes = _poses = 0;
    _last = _lastPose = null;
    _lastReason = _lastOrientation = null;
    _lastLatencyMs = _lastBytes = null;
    _startedAt = DateTime.now();
    _lastLocalizedAt = null;
    _log.clear();
    _view.reset();
    _tracked = null;
    _lastQueryAgreed = false;
    _lastSentAt = -1e9;
    _sessionId = List.generate(16, (_) => math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _serverTracks = true;
    _sliceHeight = null;
    try {
      await ArFrames.start(intervalSeconds: _frameIntervalSeconds);
    } catch (e) {
      return setState(() => _status = 'AR tracking unavailable: $e');
    }
    _sub = ArFrames.frames.listen(_onFrame);
    _poseSub = ArFrames.poses.listen(_onPose);
    setState(() {
      _running = true;
      _status = 'Point the camera at the mapped space…';
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: _runPage));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await _stop(); // the page was closed (stop button or back)
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    await _poseSub?.cancel();
    _sub = null;
    _poseSub = null;
    if (_running) await ArFrames.stop();
    if (mounted) setState(() => _running = false);
  }

  void _changed() {
    _ui.value++;
    if (mounted) setState(() {});
  }

  void _onPose(ArPose p) {
    final previous = _lastPose;
    // Tracking regained: ARCore may have re-anchored its world while it was lost.
    if (previous != null && previous.tracking != 'normal' && p.tracking == 'normal') _lastQueryAgreed = false;
    if (previous != null && previous.tracking == 'normal' && p.tracking == 'normal') {
      final step = p.worldFromCamera.distanceTo(previous.worldFromCamera);
      final dt = math.max(p.timestamp - previous.timestamp, 0.05);
      // The odometry re-anchored itself: the map alignment changed, so query at once.
      if (step > _odometryJumpMetres && step / dt > _odometryJumpSpeed) _lastQueryAgreed = false;
    }
    _lastPose = p;
    _poses++;
    if (p.tracking != 'normal') return _changed();
    _view.addPose(p.worldFromCamera, p.timestamp);
    _updateSlices();
    final h = _view.currentDisplay!.t[1];
    if (_view.registered && (_sliceHeight == null || (h - _sliceHeight!).abs() > 0.25)) _cutMapSlice();
    _viewRevision++;
    _changed(); // the map pose shown is the server's alignment applied to this odometry pose: updated at 10 Hz
  }

  Future<void> _onFrame(ArFrame f) async {
    _lastFrame = f;
    if (!f.trackingOk) {
      _status = 'Waiting for AR tracking: move the phone slowly'; // the server needs the odometry pose
      return _changed();
    }
    if (_inFlight) return; // one request at a time; later frames are newer anyway
    if (_trackingMode && f.timestamp - _lastSentAt < _trackingInterval) return;
    _lastSentAt = f.timestamp;
    _inFlight = true;
    _attempts++;
    _lastOrientation = f.orientation;
    _lastBytes = f.jpeg.length;
    final t = Stopwatch()..start();
    try {
      final tr = await _localize(f);
      _onTracked(f, tr);
      _lastQueryAgreed = tr.frameAgreed;
    } catch (e) {
      _lastQueryAgreed = false;
      _status = 'Error';
      _lastReason = e is ApiException ? e.detail : '$e';
      debugPrint('PF: frame ${f.orientation}: error: $_lastReason');
    } finally {
      _inFlight = false;
      _lastLatencyMs = t.elapsedMilliseconds;
      final time = DateTime.now().toIso8601String().substring(11, 19);
      _log.insert(0, '$time ${'${_lastLatencyMs}ms'.padLeft(6)}  ${_lastReason ?? ''}');
      if (_log.length > 12) _log.removeLast();
      _changed();
    }
  }

  // Tracked localization when the server offers it (POST /localize/track); otherwise single-frame localization
  // (POST /localize), whose best match per frame gives the alignment. A 404 from /localize/track switches this
  // session to single frames.
  Future<TrackedLocalization> _localize(ArFrame f) async {
    if (_serverTracks) {
      try {
        return await widget.api.localizeTracked(f.jpeg, f.cameraConfig, _selected.toList(), _sessionId, f.worldFromCamera);
      } on ApiException catch (e) {
        if (e.status != 404 && e.status != 405) rethrow;
        _serverTracks = false;
        debugPrint('PF: the server has no /localize/track: single-frame localization');
      }
    }
    try {
      final found =
          await widget.api.localize(f.jpeg, f.cameraConfig, _selected.toList(), uprightFromCamera: f.uprightFromCamera);
      return TrackedLocalization.fromSingleFrame(f.worldFromCamera, found);
    } on ApiException catch (e) {
      if (e.status != 422) rethrow; // 422: no localization in this frame
      return TrackedLocalization.fromSingleFrame(f.worldFromCamera, const []);
    }
  }

  void _onTracked(ArFrame f, TrackedLocalization tr) {
    _tracked = tr;
    final align = tr.odomFromMap;
    if (tr.probability >= _showProbability && align != null) {
      // The display frame follows the map; a reset (first fix or a different place) needs the map points re-cut.
      if (_view.addAlignment(f.timestamp, align, f.worldFromCamera.t)) _sliceHeight = null;
      if (tr.frameAgreed) _view.addFix(f.timestamp, f.worldFromCamera.t);
    }
    if (tr.frameAgreed) {
      _successes++;
      _lastLocalizedAt = DateTime.now();
    }
    final pct = '${(100 * tr.probability).round()}%';
    _status = tr.probability >= _showProbability
        ? 'Localized · $pct'
        : tr.mapId != null
            ? 'Localizing… $pct'
            : 'Not localized';
    final c = tr.frameConfidence;
    _lastReason = '${tr.frameCandidates} candidates · '
        '${tr.frameAgreed ? 'agreed (${tr.frameSource}, conf ${c!.toStringAsFixed(2)}, ${tr.frameInliers} inliers)' : 'none agreed'}'
        ' → $pct';
    debugPrint('PF: tracked ${f.orientation} $_lastReason hyps=${tr.hypotheses} sigma=${tr.sigmaM?.toStringAsFixed(2)}');
    final mapId = tr.mapId;
    if (mapId != null && widget.config.mapperUrl.isNotEmpty && !_slicesMeta.containsKey(mapId)) {
      _slicesMeta[mapId] = null;
      final t = Stopwatch()..start();
      widget.api.mapSlices(mapId).then((meta) {
        _slicesMeta[mapId] = meta;
        debugPrint('PF: map slices ${mapId.substring(0, 8)}: ${meta?['levels']} levels, '
            '${meta?['width']}x${meta?['height']} px, ${t.elapsedMilliseconds} ms');
        _updateSlices();
      }, onError: (Object e) => debugPrint('PF: map slices unavailable: $e'));
    }
    if (mapId != null && widget.config.mapperUrl.isEmpty && !_mapPoints.containsKey(mapId)) {
      _mapPoints[mapId] = null;
      final map = _maps.where((m) => m.id == mapId).firstOrNull;
      (map == null ? Future<Float32List?>.value(null) : widget.api.mapPoints(map.reconstructionId)).then((pts) {
        _mapPoints[mapId] = pts;
        debugPrint('PF: map points ${mapId.substring(0, 8)}: ${(pts?.length ?? 0) ~/ 3}');
        _cutMapSlice();
        _changed();
      }, onError: (Object e) => debugPrint('PF: map points unavailable: $e'));
    }
    _cutMapSlice();
  }

  bool get _trackingMode => _lastQueryAgreed && (_tracked?.probability ?? 0) >= _trackingProbability;

  Pose? get _confidentAlignment {
    final tr = _tracked;
    return tr != null && tr.probability >= _showProbability ? tr.odomFromMap : null;
  }

  // The two slices around the phone's height in the localized map, blended by distance (slice k is at
  // y = y0 + k * step). The slices within _preloadSlices of them are loaded ahead, so moving up or down shows the
  // next one at once; a slice not loaded yet is replaced by the nearest loaded one (never black), and decoded slices
  // more than _keepSlices away are freed (~1 MB each).
  static const _preloadSlices = 2, _keepSlices = 6;

  void _updateSlices() {
    final mapId = _tracked?.mapId, meta = mapId == null ? null : _slicesMeta[mapId];
    final here = _view.mapPosition;
    if (meta == null || here == null) return;
    final levels = (meta['levels'] as num).toInt();
    final level = ((here[1] - (meta['y0'] as num)) / (meta['step'] as num)).clamp(0.0, levels - 1.0);
    final k0 = level.floor(), k1 = math.min(k0 + 1, levels - 1);
    for (var k = math.max(0, k0 - _preloadSlices); k <= math.min(levels - 1, k1 + _preloadSlices); k++) {
      _slice(mapId!, k);
    }
    _freeSlices(mapId!, k0);
    final lower = _sliceImages['$mapId/$k0'], upper = _sliceImages['$mapId/$k1'];
    var blend = level - k0;
    ui.Image? a = lower, b = upper;
    if (a == null && b == null) {
      a = _nearestSlice(mapId, k0, levels); // nothing here yet: the closest slice loaded, rather than nothing
      blend = 0;
    } else if (a == null) {
      blend = 1;
    } else if (b == null) {
      blend = 0;
    }
    _view
      ..sliceMeta = meta
      ..sliceMapY = here[1]
      ..sliceBlend = blend
      ..sliceLower = a
      ..sliceUpper = b;
  }

  ui.Image? _nearestSlice(String mapId, int k, int levels) {
    for (var d = 1; d < levels; d++) {
      final img = _sliceImages['$mapId/${k - d}'] ?? _sliceImages['$mapId/${k + d}'];
      if (img != null) return img;
    }
    return null;
  }

  void _freeSlices(String mapId, int around) {
    final far = _sliceImages.keys.where((key) {
      final i = key.lastIndexOf('/');
      return key.substring(0, i) != mapId || (int.parse(key.substring(i + 1)) - around).abs() > _keepSlices;
    }).toList();
    for (final key in far) {
      _sliceImages.remove(key)?.dispose();
    }
  }

  ui.Image? _slice(String mapId, int k) {
    final key = '$mapId/$k';
    if (_sliceImages.containsKey(key)) return _sliceImages[key];
    _sliceImages[key] = null; // loading
    final t = Stopwatch()..start();
    widget.api.mapSliceImage(mapId, k).then((png) async {
      if (png == null) {
        _sliceImages.remove(key); // try again later
        return;
      }
      final frame = await (await ui.instantiateImageCodec(png)).getNextFrame();
      if (!_sliceImages.containsKey(key)) return frame.image.dispose(); // freed while loading
      _sliceImages[key] = frame.image;
      debugPrint('PF: map slice $k: ${png.length ~/ 1000} KB, ${t.elapsedMilliseconds} ms');
      _updateSlices();
      _viewRevision++;
      _changed();
    }, onError: (Object e) {
      _sliceImages.remove(key);
      debugPrint('PF: map slice $k unavailable: $e');
    });
    return null;
  }

  // The map points of the localized map, in the view's map-fixed display frame, cut at the phone's height.
  void _cutMapSlice() {
    final cur = _view.currentDisplay, mapId = _tracked?.mapId;
    final pts = !_view.registered || mapId == null ? null : _mapPoints[mapId];
    if (pts == null || cur == null) {
      _view.mapPointsXZ = null;
      _view.mapPointCount = 0;
      return;
    }
    _sliceHeight = cur.t[1];
    _view.setMapPoints(pts, _sliceHeight!);
    _viewRevision++;
  }

  // The full-screen page while localizing: the top-down view and verbose stats for debugging.
  Widget _runPage(BuildContext context) {
    String mapName(String id) => _maps.where((m) => m.id == id).map((m) => m.name).firstOrNull ?? id.substring(0, 8);
    String age(DateTime? t) => t == null ? '-' : '${DateTime.now().difference(t).inSeconds} s ago';
    String v3(List<double> v) => v.map((x) => x.toStringAsFixed(2)).join(', ');
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, // one way out: Stop (or the system back gesture)
        // The map it localized in; before that, which map(s) it is searching.
        title: ValueListenableBuilder<int>(
          valueListenable: _ui,
          builder: (context, _, _) {
            final id = _tracked?.mapId;
            final n = _selected.length;
            return Text(
                id != null
                    ? 'Localizing · ${mapName(id)}'
                    : 'Localizing · searching ${n == 1 ? mapName(_selected.first) : '$n maps'}',
                overflow: TextOverflow.ellipsis);
          },
        ),
        actions: [
          TextButton.icon(icon: const Icon(Icons.stop), label: const Text('Stop'), onPressed: () => Navigator.of(context).pop()),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _ui,
        builder: (context, _, _) {
          final pose = _lastPose, tr = _tracked, align = _confidentAlignment;
          final ok = align != null;
          final mapPose = align == null || pose == null ? null : align.inverse() * pose.worldFromCamera;
          final rows = <(String, String)>[
            ('Tracking', '${pose?.tracking ?? '-'} · $_poses poses · path ${_view.pathLength.toStringAsFixed(1)} m'),
            ('Odometry', pose == null ? '-' : v3(pose.worldFromCamera.t)),
            ('Probability', tr == null ? '-' : '${(100 * tr.probability).toStringAsFixed(1)}% this is the right place'
                ' · ±${tr.sigmaM?.toStringAsFixed(2) ?? '-'} m · ${tr.fixes} fixes'),
            ('Places tracked', tr == null ? '-' : '${tr.hypotheses} · elsewhere ${(100 * tr.unknown).toStringAsFixed(0)}%'),
            ('Query rate', _trackingMode ? 'tracking: every ${_trackingInterval.round()} s (odometry carries the pose)'
                : 'searching: every frame'),
            ('Frames', '$_successes agreed / $_attempts sent'
                '${_attempts > 0 ? ' (${(100 * _successes / _attempts).round()}%)' : ''} · ${_inFlight ? 'request in flight' : 'idle'}'),
            ('Last frame', tr == null ? '-' : '${tr.frameCandidates} candidate poses · ${tr.frameAgreed ? 'one agreed' : 'none agreed'}'),
            ('Localization conf.', tr?.frameConfidence == null ? '-'
                : '${(100 * tr!.frameConfidence!).toStringAsFixed(0)}% · ${tr.frameInliers} inliers · ${tr.frameSource}'),
            ('Last request', '${_lastOrientation ?? '-'} · ${_lastBytes == null ? '-' : '${(_lastBytes! / 1024).round()} KB'}'
                ' · ${_lastLatencyMs ?? '-'} ms'),
            ('Last agreed', '${tr?.mapId == null ? '-' : mapName(tr!.mapId!)} · ${age(_lastLocalizedAt)}'),
            ('Map points', _view.mapPointCount > 0 ? '${_view.mapPointCount} within ±1 m of the phone' : 'once localized'),
            ('Running', age(_startedAt).replaceAll(' ago', '')),
          ];
          return ListView(padding: const EdgeInsets.all(12), children: [
            Text(_status ?? '', style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: ok ? Colors.greenAccent : (_status == 'Error' ? Colors.redAccent : null))),
            Text(mapPose == null
                ? 'Map pose: -'
                : 'Map pose: ${v3(mapPose.t)} m · heading ${_heading(mapPose).toStringAsFixed(0)}°',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 15)),
            const SizedBox(height: 8),
            TopDownView(model: _view, revision: _viewRevision),
            Text('Blue: path (AR odometry) · green: frames that agreed with the place · grey: map points · '
                'all within ±1 m of the phone height',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Table(columnWidths: const {0: IntrinsicColumnWidth()}, children: [
              for (final (k, v) in rows)
                TableRow(children: [
                  Padding(padding: const EdgeInsets.only(right: 12, bottom: 3), child: Text(k, style: const TextStyle(color: Colors.white60))),
                  Text(v),
                ]),
            ]),
            const SizedBox(height: 8),
            for (final line in _log)
              Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white70)),
          ]);
        },
      ),
    );
  }

  // Compass-style heading of the camera's view direction in the map's horizontal plane (map x/z, degrees).
  static double _heading(Pose mapFromCamera) {
    final r = mapFromCamera.rotationMatrix;
    return (math.atan2(r[2], r[8]) * 180 / math.pi) % 360;
  }

  @override
  Widget build(BuildContext context) {
    final last = _last;
    final mapName = last == null ? null : _maps.where((m) => m.id == last.mapId).map((m) => m.name).firstOrNull;
    // The Start/Stop button stays at the bottom of the screen; the rest scrolls above it.
    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), children: [
      Row(children: [
        Expanded(
          child: SegmentedButton<bool>(
            segments: const [ButtonSegment(value: true, label: Text('Nearby (GPS)')), ButtonSegment(value: false, label: Text('All maps'))],
            selected: {_nearby},
            onSelectionChanged: _running
                ? null
                : (v) {
                    _nearby = v.first;
                    _loadMaps();
                  },
          ),
        ),
        IconButton(onPressed: _loadingMaps || _running ? null : _loadMaps, icon: const Icon(Icons.refresh)),
      ]),
      if (_nearby && _fix != null)
        Text('GPS ${_fix!.latitude.toStringAsFixed(5)}, ${_fix!.longitude.toStringAsFixed(5)} '
            '± ${_fix!.accuracy.round()} m · radius ${widget.config.mapRadiusMeters.round()} m'),
      if (_loadingMaps) const LinearProgressIndicator(),
      if (!_loadingMaps && _maps.isEmpty)
        const Padding(padding: EdgeInsets.all(8), child: Text('No maps found. Try “All maps”: maps without a GPS placement are not found by location.')),
      if (_maps.isNotEmpty) ...[
        const SizedBox(height: 12),
        MapPicker(
          maps: _maps,
          selected: _selected,
          enabled: !_running,
          onChanged: (ids) {
            setState(() => _selected
              ..clear()
              ..addAll(ids));
            widget.config.selectedMaps = ids.toList();
          },
        ),
        for (final m in _maps.where((m) => _selected.contains(m.id)))
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text('${m.folder.isEmpty ? '' : '${m.folder} / '}${m.name} · ${MapPicker.created(m)}${m.active ? '' : ' · inactive'}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
      const SizedBox(height: 12),
      if (_status != null) Text(_status!, style: Theme.of(context).textTheme.titleMedium),
      if (_lastFrame != null) Text('Tracking: ${_lastFrame!.tracking} · ${_lastFrame!.width}×${_lastFrame!.height}'),
      if (_attempts > 0) Text('Localized $_successes of $_attempts frames'),
      if (last != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Last localization: ${mapName ?? last.mapId.substring(0, 8)}', style: Theme.of(context).textTheme.titleSmall),
              Text('Position in map: ${last.mapFromCamera.t.map((v) => v.toStringAsFixed(2)).join(', ')} m'),
              Text('Confidence ${last.confidence.toStringAsFixed(2)} · ${last.latencyMs} ms'),
              if (last.metrics['num_inliers'] != null) Text('Inliers: ${last.metrics['num_inliers']}'),
            ]),
          ),
        ),
      ])),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _running ? _stop : _start,
              icon: Icon(_running ? Icons.stop : Icons.play_arrow),
              label: Text(_running ? 'Stop localizing' : 'Start localizing'),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------ capture

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.config, required this.api});
  final Config config;
  final PlaceframeApi api;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

// A capture kept on the device, with its server-side progress (saved next to the capture as `<id>.json`).
class LocalCapture {
  LocalCapture(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String? get status => json['status'] as String?;

  static Future<List<LocalCapture>> all() async {
    final root = await CaptureSession.root();
    final files = root.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    final list = [for (final f in files) LocalCapture(jsonDecode(await f.readAsString()) as Map<String, dynamic>)];
    list.sort((a, b) => (b.json['recorded_at'] as String).compareTo(a.json['recorded_at'] as String));
    return list;
  }

  Future<void> save() async =>
      File('${(await CaptureSession.root()).path}/$id.json').writeAsString(jsonEncode(json));
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _name = TextEditingController();
  CaptureSession? _session;
  StreamSubscription<ArFrame>? _frames;
  StreamSubscription<Position>? _gps;
  Position? _fix;
  String _tracking = '-';
  DateTime? _startedAt;
  List<LocalCapture> _captures = [];
  bool _usePriors = true;
  String? _message;
  final Set<String> _busy = {};
  Timer? _ticker;
  // Where the capture goes: a new map, or merged into an existing map (needs the map-updater, Config.mapperUrl).
  bool _newMap = true;
  final Set<String> _target = {};
  List<MapInfo> _maps = [];
  // Live view while recording.
  CaptureTrack _track = CaptureTrack();
  StreamSubscription<ArPose>? _poseSub;
  Pose? _lastPose;
  String _trackingReason = '';

  @override
  void initState() {
    super.initState();
    _reload();
    _loadMaps();
  }

  Future<void> _loadMaps() async {
    try {
      final maps = await widget.api.maps();
      maps.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (mounted) setState(() => _maps = maps);
    } catch (e) {
      debugPrint('PF: capture: maps not loaded: $e');
    }
  }

  MapInfo? get _targetMap => _newMap ? null : _maps.where((m) => _target.contains(m.id)).firstOrNull;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    _captures = await LocalCapture.all();
    if (mounted) setState(() {});
  }

  Future<void> _record() async {
    if (!await cameraAllowed()) return setState(() => _message = 'Camera permission is needed');
    final session = await CaptureSession.start();
    try {
      await ArFrames.start(intervalSeconds: widget.config.captureIntervalSeconds);
    } catch (e) {
      return setState(() => _message = 'AR tracking unavailable: $e');
    }
    _track = CaptureTrack();
    _frames = ArFrames.frames.listen((f) {
      _tracking = f.tracking;
      _trackingReason = f.trackingReason;
      _track.addFrame(f);
      session.addFrame(f);
    });
    _poseSub = ArFrames.poses.listen((p) {
      if (!p.trackingOk) return;
      _lastPose = p.worldFromCamera;
      _track.addPose(p.worldFromCamera);
    });
    debugPrint('PF: capture started ${session.id}: ${_newMap ? 'new map' : 'into ${_targetMap?.name}'}');
    if (await ensureLocationPermission()) {
      _gps = Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best))
          .listen((p) {
        _fix = p;
        session.addFix(p);
      });
    }
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}));
    setState(() {
      _session = session;
      _startedAt = DateTime.now();
      _message = null;
    });
  }

  Future<void> _stopRecording() async {
    final session = _session!;
    _ticker?.cancel();
    await _poseSub?.cancel();
    await _frames?.cancel();
    debugPrint('PF: capture stopped ${session.id}: ${session.frames} frames kept of ${session.received} '
        '(${session.describeTracking()}), ${_track.distance.toStringAsFixed(1)} m walked');
    await _gps?.cancel();
    await ArFrames.stop();
    setState(() => _session = null);
    try {
      final tar = await session.finish(widget.config.captureIntervalSeconds);
      final name = _name.text.trim().isEmpty ? 'phone capture ${session.id}' : _name.text.trim();
      await LocalCapture({
        'id': session.id,
        'name': name,
        'recorded_at': _startedAt!.toUtc().toIso8601String(),
        'frames': session.frames,
        'tar': tar.path,
        'tar_bytes': await tar.length(),
        'has_location': await File('${session.dir.path}/location.json').exists(),
        if (_targetMap != null) 'target_map_id': _targetMap!.id,
        if (_targetMap != null) 'target_map_name': _targetMap!.name,
        'distance_m': _track.distance,
        'status': 'recorded',
      }).save();
      await session.dir.delete(recursive: true); // the tar holds everything
      _message = 'Recorded ${session.frames} frames';
    } catch (e) {
      _message = '$e';
      debugPrint('PF: capture ${session.id} not saved: $e');
    }
    await _reload();
  }

  Future<void> _upload(LocalCapture c) async {
    setState(() => _busy.add(c.id));
    try {
      c.json['status'] = 'uploading';
      setState(() {});
      final captureId = await widget.api
          .uploadCapture(File(c.json['tar'] as String), c.name, DateTime.parse(c.json['recorded_at'] as String));
      c.json['capture_session_id'] = captureId;
      final target = c.json['target_map_id'] as String?;
      if (target != null) {
        // Merged into the existing map by the map-updater (it registers the capture to the map and rebuilds it).
        c.json['merge_job'] = await widget.api.mergeIntoMap(captureId, target, c.name);
        c.json['status'] = 'merging into ${c.json['target_map_name']}: queued';
        return;
      }
      final options = _usePriors ? {'use_prior_position': true, 'pose_prior_position_sigma_m': 2.0} : <String, dynamic>{};
      final rec = await widget.api.createReconstruction(captureId, options);
      c.json['reconstruction_id'] = rec['id'];
      c.json['status'] = rec['status'];
    } catch (e) {
      c.json['status'] = 'upload failed: $e';
    } finally {
      await c.save();
      _busy.remove(c.id);
      await _reload();
    }
  }

  Future<void> _refresh(LocalCapture c) async {
    final jobId = c.json['merge_job'] as String?;
    if (jobId != null) {
      try {
        final j = await widget.api.mergeJob(jobId);
        if (j != null) {
          final mapId = (j['result'] as Map<String, dynamic>?)?['map_id'];
          c.json['status'] = 'merging into ${c.json['target_map_name']}: ${j['state']}'
              '${j['current'] != null ? ' (${j['current']})' : ''}${j['error'] != null ? ' — ${j['error']}' : ''}';
          if (mapId != null) c.json['map_id'] = mapId;
          await c.save();
        }
      } catch (e) {
        _message = '$e';
      }
      return _reload();
    }
    final rid = c.json['reconstruction_id'] as String?;
    if (rid == null) return;
    try {
      final rec = await widget.api.reconstruction(rid);
      final cur = rec['progress_current'], tot = rec['progress_total'];
      c.json['status'] = '${rec['status']}${cur != null && tot != null ? ' $cur/$tot' : ''}';
      if (rec['status'] == 'failed') c.json['status'] = 'failed: ${rec['error'] ?? ''}';
      await c.save();
    } catch (e) {
      _message = '$e';
    }
    await _reload();
  }

  Future<void> _createMap(LocalCapture c) async {
    try {
      final map = await widget.api.createMap(c.json['reconstruction_id'] as String, c.name);
      c.json['map_id'] = map.id;
      c.json['status'] = 'map created';
      await c.save();
    } catch (e) {
      _message = '$e';
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    return ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: _name, enabled: s == null, decoration: const InputDecoration(labelText: 'Capture name (optional)')),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        segments: [
          const ButtonSegment(value: true, label: Text('New map')),
          ButtonSegment(value: false, label: const Text('Add to existing map'), enabled: widget.config.mapperUrl.isNotEmpty),
        ],
        selected: {_newMap},
        onSelectionChanged: s != null ? null : (v) => setState(() => _newMap = v.first),
      ),
      if (widget.config.mapperUrl.isEmpty)
        Text('Adding to an existing map needs a map-updater (Settings).', style: Theme.of(context).textTheme.bodySmall),
      if (!_newMap) ...[
        const SizedBox(height: 8),
        MapPicker(
          maps: _maps,
          selected: _target,
          enabled: s == null,
          // One target map: the latest one ticked.
          onChanged: (ids) => setState(() {
            final added = ids.difference(_target);
            _target
              ..clear()
              ..addAll(added.isNotEmpty ? {added.first} : ids.take(1));
          }),
        ),
        if (_targetMap != null)
          Text('Start and end in an area the map already covers.', style: Theme.of(context).textTheme.bodySmall),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _usePriors,
        onChanged: (v) => setState(() => _usePriors = v),
        title: const Text('Use AR poses as position priors'),
        subtitle: const Text('Guides the build with the phone’s tracking (2 m prior). Off = Placeframe defaults.'),
      ),
      FilledButton.icon(
        onPressed: s != null ? _stopRecording : (!_newMap && _targetMap == null ? null : _record),
        icon: Icon(s == null ? Icons.fiber_manual_record : Icons.stop),
        label: Text(s == null ? 'Start recording' : 'Stop recording'),
      ),
      if (s != null) ...[
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // The latest frame captured, turned upright.
          if (_track.lastFrame != null)
            SizedBox(
              width: 110,
              child: RotatedBox(
                quarterTurns: switch (_track.lastFrame!.orientation) { 'RIGHT_TOP' => 1, 'LEFT_BOTTOM' => 3, 'BOTTOM_RIGHT' => 2, _ => 0 },
                child: Image.memory(_track.lastFrame!.jpeg, gaplessPlayback: true, fit: BoxFit.contain),
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s.frames} frames captured (${s.received} received)'),
              Text('${_track.distance.toStringAsFixed(1)} m walked · ${DateTime.now().difference(_startedAt!).inSeconds} s'),
              if (_track.position != null) Text('xyz ${_track.position!.map((v) => v.toStringAsFixed(2)).join(', ')} m'),
              Text('Tracking: $_tracking${_trackingReason.isEmpty ? '' : ' ($_trackingReason)'}',
                  style: TextStyle(color: _tracking == 'normal' ? null : Colors.orange)),
              Text('${_track.landmarks.length} landmarks'),
              Text(_fix == null ? 'GPS: waiting for a fix…' : 'GPS ± ${_fix!.accuracy.round()} m'),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: 1,
          child: CustomPaint(painter: CaptureTopDown(_track, _lastPose, _track.path.length * 100000 + _track.landmarks.length)),
        ),
        const Text('Walk slowly; keep the phone steady and the scene textured.'),
      ],
      if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
      const Divider(height: 32),
      Row(children: [
        Text('Captures on this device', style: Theme.of(context).textTheme.titleSmall),
        const Spacer(),
        IconButton(
            onPressed: () async {
              for (final c in _captures) {
                await _refresh(c);
              }
            },
            icon: const Icon(Icons.refresh)),
      ]),
      for (final c in _captures)
        Card(
          child: ListTile(
            title: Text(c.name),
            subtitle: Text('${c.json['frames']} frames · ${((c.json['tar_bytes'] as num) / 1e6).toStringAsFixed(1)} MB'
                '${c.json['has_location'] == true ? ' · GPS' : ' · no GPS'}'
                '${c.json['target_map_name'] != null ? ' · into ${c.json['target_map_name']}' : ' · new map'}\n${c.status ?? ''}'),
            isThreeLine: true,
            trailing: _busy.contains(c.id)
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : PopupMenuButton<String>(
                    onSelected: (a) async {
                      if (a == 'upload') await _upload(c);
                      if (a == 'refresh') await _refresh(c);
                      if (a == 'map') await _createMap(c);
                      if (a == 'delete') {
                        await CaptureSession.delete(c.id);
                        await _reload();
                      }
                    },
                    itemBuilder: (_) => [
                      if (c.json['capture_session_id'] == null)
                        PopupMenuItem(
                            value: 'upload',
                            child: Text(c.json['target_map_id'] != null ? 'Upload and merge into the map' : 'Upload and build')),
                      if (c.json['reconstruction_id'] != null || c.json['merge_job'] != null)
                        const PopupMenuItem(value: 'refresh', child: Text('Refresh status')),
                      if ((c.status ?? '').startsWith('succeeded') && c.json['map_id'] == null)
                        const PopupMenuItem(value: 'map', child: Text('Create map')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete from device')),
                    ],
                  ),
          ),
        ),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------ settings

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.config, required this.auth, required this.onLogout});
  final Config config;
  final Auth auth;
  final VoidCallback onLogout;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    Widget number(String label, double value, void Function(double) set) => TextFormField(
          initialValue: value.toString(),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label),
          onChanged: (v) => double.tryParse(v) != null ? set(double.parse(v)) : null,
        );
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Server: ${c.serverUrl}\nUser: ${c.username}'),
      TextFormField(initialValue: c.realm, decoration: const InputDecoration(labelText: 'Keycloak realm'), onChanged: (v) => c.realm = v),
      TextFormField(initialValue: c.clientId, decoration: const InputDecoration(labelText: 'Client id'), onChanged: (v) => c.clientId = v),
      number('Nearby radius (m)', c.mapRadiusMeters, (v) => c.mapRadiusMeters = v),
      number('Seconds between capture frames', c.captureIntervalSeconds, (v) => c.captureIntervalSeconds = v),
      TextFormField(
          initialValue: c.mapperUrl,
          decoration: const InputDecoration(
              labelText: 'Map-updater URL (optional)',
              helperText: 'Map folders in the map picker, and adding captures to existing maps'),
          onChanged: (v) => c.mapperUrl = v),
      const SizedBox(height: 12),
      Text(
          'Localization rate is adaptive: every frame (at most 2 per second) until the phone is localized, then every '
          '${LocalizeScreen.trackingIntervalSeconds.round()} s while the localizations agree, and every frame again after a '
          'disagreement or an odometry jump.',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      OutlinedButton(
          onPressed: () {
            widget.auth.logout();
            widget.onLogout();
          },
          child: const Text('Log out')),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------ location

// Android needs the runtime camera permission before ARCore opens the camera; on iOS ARKit asks for it itself.
Future<bool> cameraAllowed() async => !Platform.isAndroid || await Permission.camera.request().isGranted;

Future<bool> ensureLocationPermission() async {
  if (!await Geolocator.isLocationServiceEnabled()) return false;
  var p = await Geolocator.checkPermission();
  if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
  return p == LocationPermission.always || p == LocationPermission.whileInUse;
}

Future<Position?> currentFix() async {
  if (!await ensureLocationPermission()) return null;
  try {
    return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 15)));
  } catch (_) {
    return await Geolocator.getLastKnownPosition();
  }
}

// ECEF of a GPS fix (exposed for callers that query maps by position).
List<double> ecefOf(Position p) => ecefFromGeodetic(p.latitude, p.longitude, p.altitude);
