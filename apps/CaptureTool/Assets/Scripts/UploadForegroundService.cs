#if !UNITY_EDITOR && UNITY_ANDROID
using System;
using System.Threading;
using UnityEngine;

namespace Placeframe.Client
{
    // Refcounted keep-alive over io.placeframe.android.UploadService. Each
    // EnqueueUpload holds a reference for its full duration (queued + active);
    // while any reference is held, the dataSync foreground service keeps the
    // process exempt from the cached-apps freezer and Doze network cuts, and
    // the service's partial wakelock holds the CPU through the USB leg's quiet
    // gaps. The activity reference is held for the process lifetime (never
    // disposed) so a late progress tick can't race a Release into a dead JNI
    // object.
    public static class UploadForegroundService
    {
        private static readonly AndroidJavaClass serviceClass =
            new("io.placeframe.android.UploadService");
        private static readonly AndroidJavaObject activity =
            new AndroidJavaClass("com.unity3d.player.UnityPlayer")
                .GetStatic<AndroidJavaObject>("currentActivity");

        private static int references;
        private static DateTime lastNotificationUpdateUtc = DateTime.MinValue;
        private static readonly TimeSpan notificationUpdateInterval = TimeSpan.FromSeconds(1);

        public static void Acquire()
        {
            if (Interlocked.Increment(ref references) != 1)
                return;
            AndroidJNI.AttachCurrentThread();
            serviceClass.CallStatic("start", activity);
        }

        public static void Release()
        {
            if (Interlocked.Decrement(ref references) != 0)
                return;
            AndroidJNI.AttachCurrentThread();
            serviceClass.CallStatic("stop", activity);
        }

        // Called from the Progress<UploadProgress> callback (main thread);
        // throttled because the underlying ticks arrive every 200ms.
        public static void UpdateNotification(float? percent, string detail)
        {
            if (Volatile.Read(ref references) == 0)
                return;
            var now = DateTime.UtcNow;
            if (now - lastNotificationUpdateUtc < notificationUpdateInterval)
                return;
            lastNotificationUpdateUtc = now;
            serviceClass.CallStatic("updateProgress", activity, (int)(percent ?? -1f), detail ?? "");
        }
    }
}
#else
namespace Placeframe.Client
{
    public static class UploadForegroundService
    {
        public static void Acquire() { }

        public static void Release() { }

        public static void UpdateNotification(float? percent, string detail) { }
    }
}
#endif
