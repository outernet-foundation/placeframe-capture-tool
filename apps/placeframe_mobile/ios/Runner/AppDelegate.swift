import ARKit
import CoreImage
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ArFramesPlugin") {
      ArFramesPlugin.register(with: registrar)
    }
  }
}

/// ARKit without a view: a world-tracking session whose frames are sent to Dart every `interval` seconds as a JPEG
/// of the camera image (sensor orientation), its intrinsics, the camera pose (column-major 4x4, ARKit camera axes:
/// x right, y up, looking along -z) and the tracking state. Same messages as the Android ArFrameStreamer.
final class ArFramesPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, ARSessionDelegate {
  private var sink: FlutterEventSink?
  private let session = ARSession()
  private let queue = DispatchQueue(label: "placeframe.ar.frames")
  private let ciContext = CIContext()
  private var interval: TimeInterval = 1
  private var quality: CGFloat = 0.9
  private var lastSent: TimeInterval = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = ArFramesPlugin()
    let methods = FlutterMethodChannel(name: "placeframe/ar", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: methods)
    FlutterEventChannel(name: "placeframe/ar/frames", binaryMessenger: registrar.messenger()).setStreamHandler(plugin)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(ARWorldTrackingConfiguration.isSupported)
    case "start":
      guard ARWorldTrackingConfiguration.isSupported else {
        result(FlutterError(code: "arkit", message: "ARKit world tracking is not supported on this device", details: nil))
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      interval = args["interval"] as? Double ?? 1
      quality = CGFloat(args["quality"] as? Int ?? 90) / 100
      let config = ARWorldTrackingConfiguration()
      config.isAutoFocusEnabled = false  // a fixed focus keeps the intrinsics stable for localization
      session.delegate = self
      session.delegateQueue = queue
      lastSent = 0
      session.run(config, options: [.resetTracking, .removeExistingAnchors])
      result(nil)
    case "stop":
      session.pause()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // Runs on `queue`; frames arriving while one is being encoded are simply skipped by ARKit.
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard frame.timestamp - lastSent >= interval else { return }
    lastSent = frame.timestamp
    let image = CIImage(cvPixelBuffer: frame.capturedImage)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let jpeg = ciContext.jpegRepresentation(
        of: image, colorSpace: colorSpace,
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    else { return }
    let k = frame.camera.intrinsics  // column-major: k[2] is the principal point column
    let t = frame.camera.transform
    let pose: [Double] = [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap {
      [Double($0.x), Double($0.y), Double($0.z), Double($0.w)]
    }
    let tracking: String
    var reason = ""  // why tracking is limited, for the logs
    switch frame.camera.trackingState {
    case .normal: tracking = "normal"
    case .limited(let r):
      tracking = "limited"
      switch r {
      case .initializing: reason = "INITIALIZING"
      case .excessiveMotion: reason = "EXCESSIVE_MOTION"
      case .insufficientFeatures: reason = "INSUFFICIENT_FEATURES"
      case .relocalizing: reason = "RELOCALIZING"
      @unknown default: reason = "UNKNOWN"
      }
    default: tracking = "not_available"
    }
    // ARKit's current 3D feature points (world frame, as the pose): x, y, z of up to 200 points.
    var landmarks: [Double] = []
    if let points = frame.rawFeaturePoints?.points, !points.isEmpty {
      let step = max(1, points.count / 200)
      for i in stride(from: 0, to: points.count, by: step) {
        landmarks += [Double(points[i].x), Double(points[i].y), Double(points[i].z)]
      }
    }
    let message: [String: Any] = [
      "jpeg": FlutterStandardTypedData(bytes: jpeg),
      "width": Int(frame.camera.imageResolution.width), "height": Int(frame.camera.imageResolution.height),
      "fx": Double(k[0][0]), "fy": Double(k[1][1]), "cx": Double(k[2][0]), "cy": Double(k[2][1]),
      "pose": pose, "timestamp": frame.timestamp, "tracking": tracking, "tracking_reason": reason,
      "landmarks": landmarks,
    ]
    DispatchQueue.main.async { self.sink?(message) }
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    DispatchQueue.main.async {
      self.sink?(FlutterError(code: "arkit", message: error.localizedDescription, details: nil))
    }
  }
}
