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

// Hold a dataSync foreground service and partial wakelock so uploads survive screen off
public final class UploadService extends Service {
    private static final String CHANNEL_ID = "upload";
    private static final int NOTIFICATION_ID = 2;
    private static volatile boolean running;

    private PowerManager.WakeLock wakeLock;

    // Call only while the app is foregrounded because Android 12+ restricts background starts
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

    // Pass a negative percent to render the indeterminate text
    public static void updateProgress(Context context, String phaseLabel, int percent, String detail) {
        if (!running) return;
        NotificationManager manager =
            (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) return;
        manager.notify(NOTIFICATION_ID, buildNotification(context, phaseLabel, percent, detail));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        wakeLock = ((PowerManager) getSystemService(Context.POWER_SERVICE))
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "placeframe:upload");
        // Release in onDestroy because process death force releases it too
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
            buildNotification(this, "Uploading", -1, null),
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

    private static Notification buildNotification(Context context, String phaseLabel, int percent, String detail) {
        String text;
        if (percent < 0) {
            text = phaseLabel;
        } else if (detail == null || detail.isEmpty()) {
            text = phaseLabel + " · " + percent + "%";
        } else {
            text = phaseLabel + " · " + percent + "% · " + detail;
        }

        Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        PendingIntent contentIntent = null;
        if (launch != null) {
            contentIntent = PendingIntent.getActivity(
                context, 0, launch, PendingIntent.FLAG_IMMUTABLE);
        }

        // Resolve the icon by name because the androidlib R class package is gradle derived
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
