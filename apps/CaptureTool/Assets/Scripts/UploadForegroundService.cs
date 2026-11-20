#if !UNITY_EDITOR && UNITY_ANDROID
using System;
using System.Threading;
using UnityEngine;

namespace Placeframe.Client
{
    // Hold the upload foreground service for the full duration of every enqueued upload
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

        // Throttle notification updates because progress ticks arrive every 200ms
        public static void UpdateNotification(string phaseLabel, float? percent, string detail)
        {
            if (Volatile.Read(ref references) == 0)
                return;
            var now = DateTime.UtcNow;
            if (now - lastNotificationUpdateUtc < notificationUpdateInterval)
                return;
            lastNotificationUpdateUtc = now;
            serviceClass.CallStatic("updateProgress", activity, phaseLabel ?? "Uploading", (int)(percent ?? -1f), detail ?? "");
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

        public static void UpdateNotification(string phaseLabel, float? percent, string detail) { }
    }
}
#endif
