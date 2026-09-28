using System.Collections.Generic;
using UnityEngine;

namespace Placeframe.Client
{
    public enum CaptureEnvMode
    {
        Airgapped,
        Override,
    }

    public sealed class CaptureEnv : ScriptableObject
    {
        public const string TargetPath = "Assets/_LocalWorkspace/Resources/CaptureEnv.asset";

        public static readonly Dictionary<CaptureEnvMode, string> Presets = new()
        {
            { CaptureEnvMode.Airgapped, "Assets/BuildConfigs/CaptureEnvAirgapped.asset" },
        };

        public CaptureEnvMode configMode;
        public string apiUrl = "";
        public string username = "";
        public string password = "";
    }
}
