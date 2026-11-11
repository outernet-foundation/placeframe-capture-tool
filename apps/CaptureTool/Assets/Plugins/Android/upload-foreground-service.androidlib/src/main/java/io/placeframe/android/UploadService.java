package io.placeframe.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.IBinder;
import android.os.PowerManager;

// Keeps the Unity process elevated while capture uploads run: a dataSync
// foreground service exempts the process from the cached-apps freezer and
// from Doze network cuts, and the partial wakelock holds the CPU awake
// through the quiet gaps of the USB leg (which has no network traffic to
// hold wakeup sources). The upload work itself stays in the Unity process;
// this service only holds the notification and the wakelock.
public final class UploadService extends Service {
    private static final String CHANNEL_ID = "upload";
    private static final int NOTIFICATION_ID = 2;
    private static volatile boolean running;

    private PowerManager.WakeLock wakeLock;

    // Must be called while the app is foregrounded (Android 12+ restricts
    // foreground-service starts from the background); every call site is a
    // UI-tap-driven upload enqueue.
    public static void start(Context context) {
        if (running) return;
        running = true;
        context.startForegroundService(new Intent(context, UploadService.class));
    }

    public static void stop(Context context) {
        if (!running) return;
        running = false;
        context.stopService(new Intent(context, UploadService.class));
    }

    // percent < 0 renders the indeterminate "Uploading" text. Guarded by
    // `running` so a late tick can't post a standalone notification after
    // the service stopped.
    public static void updateProgress(Context context, int percent, String detail) {
        if (!running) return;
        NotificationManager manager =
            (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) return;
        manager.notify(NOTIFICATION_ID, buildNotification(context, percent, detail));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        wakeLock = ((PowerManager) getSystemService(Context.POWER_SERVICE))
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "placeframe:upload");
        // Released in onDestroy; process death force-releases it too, so an
        // unbounded acquire cannot outlive the app.
        wakeLock.acquire();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        NotificationManager manager =
            (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        NotificationChannel channel = new NotificationChannel(
            CHANNEL_ID, "Capture upload", NotificationManager.IMPORTANCE_LOW);
        manager.createNotificationChannel(channel);

        startForeground(
            NOTIFICATION_ID,
            buildNotification(this, -1, null),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE);
        wakeLock.release();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private static Notification buildNotification(Context context, int percent, String detail) {
        String text;
        if (percent < 0) {
            text = "Uploading";
        } else if (detail == null || detail.isEmpty()) {
            text = "Uploading · " + percent + "%";
        } else {
            text = "Uploading · " + percent + "% · " + detail;
        }

        Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        PendingIntent contentIntent = null;
        if (launch != null) {
            contentIntent = PendingIntent.getActivity(
                context, 0, launch, PendingIntent.FLAG_IMMUTABLE);
        }

        // Resolved by name instead of an R reference because the generated R
        // class's package depends on how Unity's gradle derives the androidlib
        // namespace; merged resources are always reachable through the app's
        // own resources. The framework icon is a last-resort fallback.
        int iconId = context.getResources()
            .getIdentifier("ic_stat_upload", "drawable", context.getPackageName());
        if (iconId == 0) iconId = android.R.drawable.stat_sys_upload;

        return new Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(iconId)
            .setContentTitle("Placeframe Capture Tool")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentIntent)
            .build();
    }
}
