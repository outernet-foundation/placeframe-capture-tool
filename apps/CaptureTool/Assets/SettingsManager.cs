using System;
using System.IO;
using FofX.Serialization;
using FofX.Stateful;
using PlaceframeApiClient.Model;
using SimpleJSON;
using UnityEngine;

namespace Placeframe.Client
{
    public static class SettingsManager
    {
        private static bool _initializing;
        private static IDisposable _subscription;
        private static string settingsPath => $"{Application.persistentDataPath}/settings.json";

        public static void Initialize()
        {
            Debug.Log(settingsPath);

            JSONSerialization.AddSerializer(
                json =>
                {
                    if (json.IsNull)
                        return null;

                    return Newtonsoft.Json.JsonConvert.DeserializeObject<ReconstructionOptions>(json.Value);
                },
                obj =>
                {
                    if (obj == null)
                        return JSONNull.CreateOrGet();

                    return obj.ToJson();
                }
            );

            if (File.Exists(settingsPath))
            {
                App.ExecuteTransaction(appState =>
                {
                    var json = JSONNode.Parse(File.ReadAllText(settingsPath));
                    appState.settings.FromJSON(json);
                });
            }
            else
            {
                var baked = Resources.Load<CaptureEnv>("CaptureEnv");
                if (baked != null)
                {
                    App.ExecuteTransaction(appState =>
                    {
                        var x = appState.settings;
                        x.apiUrl.value = baked.apiUrl;
                        x.username.value = baked.username;
                        x.password.value = baked.password;
                    });
                }
                else
                {
                    App.ExecuteTransaction(appState =>
                    {
                        var x = appState.settings;
                        x.apiUrl.value = null;
                        x.username.value = "user";
                        x.password.value = "password";
                    });
                }
            }

            if (App.state.settings.reconstructionOptions.value == null)
                App.state.settings.reconstructionOptions.value = new ReconstructionOptions();

            _initializing = true;

            _subscription = App.state.settings.SubscribeOperationsRecursive(_ =>
            {
                if (_initializing)
                    return;

                File.WriteAllText(settingsPath, App.state.settings.ToJSON(_ => true).ToString());
            });

            _initializing = false;

            if (!string.IsNullOrEmpty(App.state.settings.apiUrl.value))
                App.state.connectRequested.value = true;
        }

        public static void SaveSettings()
        {
            File.WriteAllText(settingsPath, App.state.settings.ToJSON(_ => true).ToString());
        }

        public static void Shutdown()
        {
            _subscription?.Dispose();
            _subscription = null;
        }
    }
}
