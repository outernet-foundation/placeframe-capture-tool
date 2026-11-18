package org.outernet.placeframe.placeframe_mobile

import android.app.Activity
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.Log
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Camera
import com.google.ar.core.CameraConfig
import com.google.ar.core.CameraConfigFilter
import com.google.ar.core.Config
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.NotYetAvailableException
import io.flutter.plugin.common.EventChannel
import java.io.ByteArrayOutputStream
import kotlin.math.atan
import kotlin.math.roundToInt

// ARCore without a view: the session runs on its own thread with an offscreen EGL context (ARCore needs a camera
// texture to update), and every [intervalSec] the CPU camera image is JPEG-encoded and sent to Dart with the image
// intrinsics, the camera pose (column-major 4x4, ARCore/OpenGL camera axes) and the tracking state.
private const val POSE_INTERVAL_NS = 100_000_000L // 10 Hz
private const val MAX_LANDMARKS = 200 // 3D feature points sent with each image

class ArFrameStreamer(private val activity: Activity) : EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    @Volatile private var running = false
    private var session: Session? = null
    private var intervalSec = 1.0
    private var quality = 90

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // True when ARCore is supported on this device (it may still need installing from the Play Store).
    fun available(): Boolean = ArCoreApk.getInstance().checkAvailability(activity).isSupported

    fun start(interval: Double, jpegQuality: Int) {
        if (running) return
        when (ArCoreApk.getInstance().requestInstall(activity, true)) {
            ArCoreApk.InstallStatus.INSTALL_REQUESTED -> throw IllegalStateException("Install Google Play Services for AR, then try again")
            ArCoreApk.InstallStatus.INSTALLED -> Unit
        }
        intervalSec = interval
        quality = jpegQuality
        running = true
        val t = HandlerThread("placeframe-arcore").also { it.start() }
        thread = t
        handler = Handler(t.looper).also { it.post { runSession() } }
    }

    fun stop() {
        running = false
        thread?.quitSafely()
        thread = null
        handler = null
    }

    private fun runSession() {
        try {
            setUpEgl()
            val texture = IntArray(1).also { GLES20.glGenTextures(1, it, 0) }[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
            val s = Session(activity)
            chooseCameraConfig(s)
            s.configure(Config(s).apply {
                updateMode = Config.UpdateMode.BLOCKING
                focusMode = Config.FocusMode.FIXED // a fixed focus keeps the intrinsics stable for localization
                planeFindingMode = Config.PlaneFindingMode.DISABLED
                lightEstimationMode = Config.LightEstimationMode.DISABLED
            })
            s.setCameraTextureName(texture)
            s.resume()
            session = s
            var lastSent = 0L
            var lastPose = 0L
            while (running) {
                val frame = s.update()
                val now = frame.timestamp
                if (now - lastSent < (intervalSec * 1e9).toLong()) {
                    // Between images, a pose-only event every POSE_INTERVAL_NS: enough to draw the odometry path.
                    if (now - lastPose >= POSE_INTERVAL_NS) {
                        lastPose = now
                        val pose = poseMessage(frame.camera, now)
                        main.post { sink?.success(pose) }
                    }
                    continue
                }
                val camera = frame.camera
                val image: Image = try {
                    frame.acquireCameraImage()
                } catch (e: NotYetAvailableException) {
                    continue
                }
                lastSent = now
                val jpeg = image.use { toJpeg(it) }
                val k = camera.imageIntrinsics
                val dims = k.imageDimensions
                val msg = poseMessage(camera, now).apply {
                    putAll(mapOf(
                        "jpeg" to jpeg,
                        "width" to dims[0], "height" to dims[1],
                        "fx" to k.focalLength[0].toDouble(), "fy" to k.focalLength[1].toDouble(),
                        "cx" to k.principalPoint[0].toDouble(), "cy" to k.principalPoint[1].toDouble(),
                        "landmarks" to landmarks(frame),
                    ))
                }
                main.post { sink?.success(msg) }
            }
        } catch (e: Exception) {
            main.post { sink?.error("arcore", e.message ?: e.javaClass.simpleName, null) }
        } finally {
            session?.pause()
            session?.close()
            session = null
            tearDownEgl()
        }
    }

    private fun poseMessage(camera: Camera, now: Long): HashMap<String, Any> {
        val pose = FloatArray(16).also { camera.pose.toMatrix(it, 0) }
        val tracking = when (camera.trackingState) {
            TrackingState.TRACKING -> "normal"
            TrackingState.PAUSED -> "limited"
            else -> "not_available"
        }
        // Why tracking is not normal (INSUFFICIENT_LIGHT, EXCESSIVE_MOTION, INSUFFICIENT_FEATURES, ...), for the logs.
        val reason = if (camera.trackingState == TrackingState.TRACKING) "" else camera.trackingFailureReason.name
        return hashMapOf("pose" to pose.map { it.toDouble() }, "timestamp" to now / 1e9, "tracking" to tracking,
            "tracking_reason" to reason)
    }

    // ARCore's current 3D feature points (world frame, the same as the poses): x, y, z of up to MAX_LANDMARKS
    // points with confidence of at least 0.3, for the capture screen's top-down view.
    private fun landmarks(frame: com.google.ar.core.Frame): List<Double> = try {
        frame.acquirePointCloud().use { cloud ->
            val b = cloud.points  // x, y, z, confidence per point
            val n = b.remaining() / 4
            val step = maxOf(1, n / MAX_LANDMARKS)
            val out = ArrayList<Double>(minOf(n, MAX_LANDMARKS) * 3)
            var i = 0
            while (i < n) {
                if (b.get(i * 4 + 3) >= 0.3f) {
                    out.add(b.get(i * 4).toDouble()); out.add(b.get(i * 4 + 1).toDouble()); out.add(b.get(i * 4 + 2).toDouble())
                }
                i += step
            }
            out
        }
    } catch (e: Exception) {
        emptyList()
    }

    // The largest CPU image up to 1920 px wide: enough detail for localization without large uploads.
    // The widest field of view ARCore offers (any back camera it supports, and the CPU image aspect that crops the
    // sensor least), then the largest image up to 1920 px wide: a wide view sees more of the map per frame.
    private fun chooseCameraConfig(s: Session) {
        val configs = s.getSupportedCameraConfigs(CameraConfigFilter(s))
        val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        fun fov(c: CameraConfig): Pair<Double, Double> {
            val ch = manager.getCameraCharacteristics(c.cameraId)
            val f = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.minOrNull() ?: return 0.0 to 0.0
            val sensor = ch.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: return 0.0 to 0.0
            val aspect = c.imageSize.width.toDouble() / c.imageSize.height
            val sensorAspect = (sensor.width / sensor.height).toDouble()
            val (w, h) = if (aspect >= sensorAspect) sensor.width.toDouble() to sensor.width / aspect
            else sensor.height * aspect to sensor.height.toDouble()
            return Math.toDegrees(2 * atan(w / (2 * f))) to Math.toDegrees(2 * atan(h / (2 * f)))
        }
        for (c in configs) {
            val (h, v) = fov(c)
            Log.i("PF", "camera config id=${c.cameraId} cpu=${c.imageSize} gpu=${c.textureSize} fps=${c.fpsRange} " +
                "fov=%.1fx%.1f".format(h, v))
        }
        val best = configs.filter { it.imageSize.width <= 1920 }
            .maxWithOrNull(compareBy<CameraConfig>({ fov(it).let { (h, v) -> (h * v).roundToInt() } },
                { it.imageSize.width * it.imageSize.height }))
        if (best != null) {
            s.cameraConfig = best
            Log.i("PF", "camera chosen id=${best.cameraId} cpu=${best.imageSize} fov=%.1fx%.1f".format(fov(best).first, fov(best).second))
        }
    }

    // YUV_420_888 to JPEG via NV21 (handles any row and pixel stride).
    private fun toJpeg(image: Image): ByteArray {
        val w = image.width
        val h = image.height
        val nv21 = ByteArray(w * h * 3 / 2)
        val y = image.planes[0]
        var pos = 0
        for (row in 0 until h) {
            val buf = y.buffer
            buf.position(row * y.rowStride)
            if (y.pixelStride == 1) {
                buf.get(nv21, pos, w)
                pos += w
            } else {
                for (col in 0 until w) nv21[pos++] = buf.get(row * y.rowStride + col * y.pixelStride)
            }
        }
        val u = image.planes[1]
        val v = image.planes[2]
        for (row in 0 until h / 2) {
            for (col in 0 until w / 2) {
                nv21[pos++] = v.buffer.get(row * v.rowStride + col * v.pixelStride)
                nv21[pos++] = u.buffer.get(row * u.rowStride + col * u.pixelStride)
            }
        }
        val out = ByteArrayOutputStream()
        YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), quality, out)
        return out.toByteArray()
    }

    private fun setUpEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        EGL14.eglInitialize(eglDisplay, version, 0, version, 1)
        val attribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, count, 0)
        eglContext = EGL14.eglCreateContext(
            eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, configs[0], intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
    }

    private fun tearDownEgl() {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return
        EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(eglDisplay, eglSurface)
        EGL14.eglDestroyContext(eglDisplay, eglContext)
        EGL14.eglTerminate(eglDisplay)
        eglDisplay = EGL14.EGL_NO_DISPLAY
    }
}
