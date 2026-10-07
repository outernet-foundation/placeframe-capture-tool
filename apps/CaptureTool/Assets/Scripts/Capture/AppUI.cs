using System;
using System.Linq;

using UnityEngine;
using UnityEngine.UI;

using FofX.Stateful;

using Nessle;

using ObserveThing;

using DeviceType = PlaceframeApiClient.Model.DeviceType;
using PlaceframeApiClient.Model;
using Cysharp.Threading.Tasks;
using Placeframe.Core;
using R3;
using UnityEngine.Events;
using Placeframe.Core.ARFoundation;

using static Nessle.UIBuilder;
using static Nessle.Props;
using Unity.VisualScripting;

namespace Placeframe.Client
{
    public static partial class UIElements
    {
        public static IControl AppUI() =>
            OrderedCanvas(new()
            {
                children = List(
                    App.state.screen
                        .ObservableCreate(screen => screen switch
                        {
                            AppScreen.Main => MainAppUI(new MainAppUIProps()
                            {
                                mode = App.state.mode,
                                onModeChanged = x => App.state.mode.value = x,
                            }),
                            AppScreen.Login => LoginUI(),
                            _ => ConnectUI(),
                        })
                ),
            });

        public struct MainAppUIProps
        {
            public IValueObservable<AppMode> mode;
            public Action<AppMode> onModeChanged;
        }

        public static IControl MainAppUI(MainAppUIProps props = default)
        {
            IControl currentScreen = null;

            return Control("Main UI", new()
            {
                layout = Utility.FillParentProps(),
                children = List(
                    TabbedMenu(new()
                    {
                        value = props.mode.ObservableSelect(x => (int)x),
                        tabs = List("Capture", "Validate"),
                        onValueChanged = x => props.onModeChanged?.Invoke((AppMode)x),
                        layout = new()
                        {
                            anchorMin = Value(new Vector2(0, 0)),
                            anchorMax = Value(new Vector2(1, 0)),
                            anchoredPosition = Value(new Vector2(0, 95f)),
                            sizeDelta = Value(new Vector2(-190, 95)),
                            pivot = Value(new Vector2(0.5f, 0))
                        }
                    }),
                    Control("Content", new()
                    {
                        layout = Utility.FillParentProps(),
                        children = List(props.mode.ObservableSelect(x =>
                        {
                            currentScreen?.Dispose();

                            if (x == AppMode.Capture)
                                currentScreen = CaptureUI();
                            else if (x == AppMode.Validation)
                                currentScreen = ValidationUI();
                            else
                                throw new Exception($"Unhandled App Mode {x}");

                            return currentScreen;
                        }))
                    })
                )
            });
        }

        private static bool IsBannerState(ZedStatusKind kind) => kind switch
        {
            ZedStatusKind.Stabilizing => true,
            ZedStatusKind.Unreachable => true,
            ZedStatusKind.LostMidCapture => true,
            ZedStatusKind.DegradedDiskLow => true,
            ZedStatusKind.DegradedError => true,
            _ => false,
        };

        private static Color ColorForBanner(ZedStatusKind kind) => kind switch
        {
            ZedStatusKind.Stabilizing => new Color(0.20f, 0.55f, 0.90f, 1f),
            ZedStatusKind.DegradedDiskLow => new Color(1.00f, 0.70f, 0.00f, 1f),
            ZedStatusKind.DegradedError => new Color(1.00f, 0.70f, 0.00f, 1f),
            _ => new Color(0.90f, 0.25f, 0.25f, 1f),
        };

        private static string LabelForBanner(ZedStatusKind kind) => kind switch
        {
            ZedStatusKind.Stabilizing => "Hold the Zed still and level — stabilizing…",
            ZedStatusKind.Unreachable => "Zed box not reachable",
            ZedStatusKind.LostMidCapture => "Connection lost to Zed box",
            ZedStatusKind.DegradedDiskLow => "Zed box disk low",
            ZedStatusKind.DegradedError => "Zed box camera error",
            _ => "",
        };

        public static IControl CaptureUI()
        {
            var zedStatusObservable = App.state.zedStatus;
            IControl namePromptDialog = default;

            return Control("Capture UI", new()
            {
                layout = Utility.FillParentProps(),
                children = List(
                    Control("Zed Status Banner", new()
                    {
                        layout = new()
                        {
                            pivot = Value(new Vector2(0.5f, 0)),
                            anchorMin = Value(new Vector2(0.5f, 0)),
                            anchorMax = Value(new Vector2(0.5f, 0)),
                            anchoredPosition = Value(new Vector2(0, 430)),
                            sizeDelta = Value(new Vector2(785, 60))
                        },
                        element = new()
                        {
                            active = Observables.ObservableCombineValues(
                                App.state.captureMode,
                                zedStatusObservable,
                                (mode, status) => mode == DeviceType.Zed && IsBannerState(status))
                        },
                        children = List(
                            Image(new()
                            {
                                sprite = Value(elements.roundedRect),
                                style = { color = zedStatusObservable.ObservableSelect(ColorForBanner) },
                                layout = Utility.FillParentProps()
                            }),
                            Text(new()
                            {
                                value = zedStatusObservable.ObservableSelect(LabelForBanner),
                                style =
                                {
                                    horizontalAlignment = Value(TMPro.HorizontalAlignmentOptions.Center),
                                    verticalAlignment = Value(TMPro.VerticalAlignmentOptions.Capline)
                                },
                                layout = Utility.FillParentProps()
                            })
                        )
                    }),
                    Control("Bottom Bar", new()
                    {
                        layout = new()
                        {
                            pivot = Value(new Vector2(0.5f, 0)),
                            anchorMin = Value(new Vector2(0.5f, 0)),
                            anchorMax = Value(new Vector2(0.5f, 0)),
                            anchoredPosition = Value(new Vector2(0, 250)),
                            sizeDelta = Value(new Vector2(785, 170))
                        },
                        children = List(
                            LabeledButton(new LabeledButtonProps()
                            {
                                label = Value("Captures"),
                                onClick = () => CapturesListUI(),
                                layout = new()
                                {
                                    sizeDelta = Value(new Vector2(255, 75)),
                                    anchorMin = Value(new Vector2(1, 0.5f)),
                                    anchorMax = Value(new Vector2(1, 0.5f)),
                                    pivot = Value(new Vector2(1, 0.5f)),
                                    anchoredPosition = Value(new Vector2(0, 0))
                                }
                            }),
                            LabeledButton(new LabeledButtonProps()
                            {
                                label = App.state.captureMode.ObservableSelect(x => x == DeviceType.ARFoundation ? "Local" : "Zed"),
                                onClick = () => App.state.captureMode.value = App.state.captureMode.value == DeviceType.ARFoundation ? DeviceType.Zed : DeviceType.ARFoundation,
                                layout = new()
                                {
                                    sizeDelta = Value(new Vector2(255, 75)),
                                    anchorMin = Value(new Vector2(0, 0.5f)),
                                    anchorMax = Value(new Vector2(0, 0.5f)),
                                    pivot = Value(new Vector2(0, 0.5f)),
                                    anchoredPosition = Value(new Vector2(0, 0))
                                }
                            }),
                            Toggle(prefab: elements.recordButton, props: new ToggleProps()
                            {
                                value = App.state.captureStatus
                                    .ObservableSelect(x => x == CaptureStatus.Capturing || x == CaptureStatus.Starting),
                                interactable = Observables.ObservableCombineValues(
                                    App.state.captureStatus,
                                    App.state.captureMode,
                                    zedStatusObservable,
                                    (status, mode, zed) =>
                                    {
                                        var statusOk = status == CaptureStatus.Idle || status == CaptureStatus.Capturing;
                                        if (!statusOk)
                                            return false;
                                        if (mode != DeviceType.Zed)
                                            return true;
                                        return zed == ZedStatusKind.Ready || zed == ZedStatusKind.Recording;
                                    }),
                                layout = new()
                                {
                                    anchorMin = Value(new Vector2(0.5f, 0.5f)),
                                    anchorMax = Value(new Vector2(0.5f, 0.5f)),
                                    anchoredPosition = Value(new Vector2(0, 0))
                                },
                                onValueChanged = isOn =>
                                {
                                    if (isOn)
                                    {
                                        if (App.state.captureStatus.value == CaptureStatus.Idle)
                                            App.state.captureStatus.value = CaptureStatus.Starting;
                                    }
                                    else
                                    {
                                        if (App.state.captureStatus.value == CaptureStatus.Capturing)
                                        {
                                            namePromptDialog = NamePromptDialog(new()
                                            {
                                                onSubmit = name =>
                                                {
                                                    App.state.pendingCaptureName.value = name;
                                                    App.state.captureStatus.value = CaptureStatus.Stopping;
                                                    namePromptDialog.Dispose();
                                                }
                                            });
                                        }
                                    }
                                }
                            })
                        )
                    })
                )
            });
        }

        public static IControl CapturesListUI()
        {
            return Dialog(new()
            {
                useBackground = Value(true),
                backgroundColor = Value(elements.backgroundColor),
                contentConstructor = dialog => Value(SafeArea(new()
                {
                    children = List(
                        TightRowsWideColumns(new()
                        {
                            padding = Value(new RectOffset(30, 30, 30, 30)),
                            layout = Utility.FillParentProps(),
                            children = List(
                                Image(new()
                                {
                                    style = { color = Value(elements.backgroundColor) },
                                    layout = Utility.FillParentProps(new() { ignoreLayout = Value(true) })
                                }),
                                Title(new() { value = Value("Captures") }),
                                ScrollRect(new()
                                {
                                    value = Value(new Vector2(0, 1)),
                                    vertical = Value(true),
                                    layout = new() { flexibleHeight = Value(1f) },
                                    content = Value(
                                        TightRowsWideColumns(new()
                                        {
                                            layout = Utility.FillParentProps(new()
                                            {
                                                fitContentVertical = Value(ContentSizeFitter.FitMode.PreferredSize),
                                                pivot = Value(new Vector2(0, 1))
                                            }),
                                            children = App.state.captures
                                                .ObservableOrderBy(x => x.Value.recordedAt.ObservableSelect(t => -t.Ticks))
                                                .ObservableCreate(x => CaptureRow(x.Value))
                                        })
                                    )
                                }),
                                Row(new()
                                {
                                    childAlignment = Value(TextAnchor.MiddleRight),
                                    children = List(
                                        LabeledButton(new()
                                        {
                                            label = Value("Done"),
                                            onClick = dialog.Dispose
                                        })
                                    )
                                })
                            )
                        }),
                        RoundIconButton(new RoundIconButtonProps()
                        {
                            layout = new()
                            {
                                anchorMax = Value(new Vector2(0, 1)),
                                anchorMin = Value(new Vector2(0, 1)),
                                pivot = Value(new Vector2(0, 1)),
                                localPosition = Value(new Vector3(29f, -29f)),
                                fitContentHorizontal = Value(ContentSizeFitter.FitMode.PreferredSize),
                                fitContentVertical = Value(ContentSizeFitter.FitMode.PreferredSize)
                            },
                            icon = new ImageProps()
                            {
                                sprite = Value(elements.moreMenuSprite),
                                style = { preserveAspect = Value(true) }
                            },
                            onClick = () => OptionsDialog()
                        })
                    )
                }))
            });
        }

        private static IDisposable OptionsDialog()
        {
            return Dialog(new()
            {
                useBackground = Value(true),
                backgroundColor = Value(elements.backgroundColor),
                contentConstructor = dialog => Value(SafeArea(new()
                {
                    children = List(
                        VerticalLayout(new()
                        {
                            layout = Utility.FillParentProps(),
                            childControlHeight = Value(true),
                            childControlWidth = Value(true),
                            childForceExpandWidth = Value(true),
                            padding = Value(new RectOffset(30, 30, 30, 30)),
                            spacing = Value(30f),
                            children = List(
                                Title(new() { value = Value("Settings ") }),
                                ScrollRect(new()
                                {
                                    value = Value(new Vector2(0, 1)),
                                    vertical = Value(true),
                                    layout = new() { flexibleHeight = Value(1f) },
                                    content = Value(
                                        TightRowsWideColumns(new()
                                        {
                                            layout = Utility.FillParentProps(new()
                                            {
                                                fitContentVertical = Value(ContentSizeFitter.FitMode.PreferredSize),
                                                pivot = Value(new Vector2(0, 1))
                                            }),
                                            children = List(
                                                ObjectInspector(new()
                                                {
                                                    isReadonly = Value(false),
                                                    target = App.state.settings.reconstructionOptions.value,
                                                    foldout = new() { label = new() { value = Value("Reconstruction Options") } },
                                                })
                                            )
                                        })
                                    )
                                }),
                                HorizontalLayout(new()
                                {
                                    childControlWidth = Value(true),
                                    childControlHeight = Value(true),
                                    childAlignment = Value(TextAnchor.MiddleRight),
                                    children = List(LabeledButton(new()
                                    {
                                        label = Value("Done"),
                                        onClick = () =>
                                        {
                                            SettingsManager.SaveSettings();
                                            dialog.Dispose();
                                        }
                                    }))
                                })
                            )
                        })
                    )
                }))
            });
        }

        public struct LocalizationMetricsDialogProps
        {
            public ElementProps element;
            public LayoutProps layout;
        }

        public static IControl LocalizationMetricsDialog(LocalizationMetricsDialogProps props)
        {
            var filterHealth = new ObservableValue<FilterHealth>(FilterHealth.Snapshot());
            var bypassInnovationGate = new ObservableValue<bool>(VisualPositioningSystem.BypassInnovationGate);
            var bypassKalman = new ObservableValue<bool>(VisualPositioningSystem.BypassKalman);

            var tickSubscription = Observable
                .EveryUpdate(UnityFrameProvider.Update)
                .Subscribe(_ => filterHealth.value = FilterHealth.Snapshot());

            var lostObservable = filterHealth.ObservableSelect(h => h.LocalizationLost);
            var lastAcceptObservable = filterHealth.ObservableSelect(h =>
                float.IsPositiveInfinity(h.SecondsSinceLastAccept)
                    ? "Last accept: never"
                    : $"Last accept: {h.SecondsSinceLastAccept:F1}s ago"
            );

            var control = VerticalLayout(new()
            {
                childControlWidth = Value(true),
                childControlHeight = Value(true),
                padding = Value(new RectOffset(30, 30, 30, 30)),
                spacing = Value(10f),
                element = props.element,
                layout = props.layout,
                children = List(
                    Title(new()
                    {
                        value = Value("Metrics"),
                        style = new() { outlineWidth = Value(.15f) }
                    }),
                    Text(new()
                    {
                        value = Value("LOCALIZATION LOST — Stop and Start to recover."),
                        element = new() { active = lostObservable },
                        style = new()
                        {
                            color = Value(Color.red),
                            outlineWidth = Value(.15f),
                            horizontalAlignment = Value(TMPro.HorizontalAlignmentOptions.Center)
                        }
                    }),
                    Text(new() { value = lastAcceptObservable }),
                    BypassToggleRow(
                        "Bypass innovation gate",
                        bypassInnovationGate,
                        isOn => VisualPositioningSystem.BypassInnovationGate = isOn
                    ),
                    BypassToggleRow(
                        "Bypass Kalman update",
                        bypassKalman,
                        isOn => VisualPositioningSystem.BypassKalman = isOn
                    )
                )
            });

            control.AddBinding(tickSubscription);

            return control;
        }

        private static IControl BypassToggleRow(string label, ObservableValue<bool> state, Action<bool> setStatic)
        {
            return HorizontalLayout(new()
            {
                childControlWidth = Value(true),
                childControlHeight = Value(true),
                childAlignment = Value(TextAnchor.MiddleLeft),
                spacing = Value(10f),
                children = List(
                    Text(new()
                    {
                        value = Value(label),
                        layout = new() { flexibleWidth = Value(1f) },
                        style = new()
                        {
                            verticalAlignment = Value(TMPro.VerticalAlignmentOptions.Capline),
                            overflowMode = Value(TMPro.TextOverflowModes.Ellipsis),
                            textWrappingMode = Value(TMPro.TextWrappingModes.NoWrap)
                        }
                    }),
                    Toggle(new ToggleProps()
                    {
                        value = state,
                        onValueChanged = isOn =>
                        {
                            setStatic(isOn);
                            state.value = isOn;
                        }
                    })
                )
            });
        }

        public static IControl ValidationUI()
        {
            var metricsDialogOpen = new ObservableValue<bool>(false);
            var lockupHealth = new ObservableValue<FilterHealth>(FilterHealth.Snapshot());
            var lockupTick = Observable
                .EveryUpdate(UnityFrameProvider.Update)
                .Subscribe(_ => lockupHealth.value = FilterHealth.Snapshot());
            IControl selectValidationTargetDialog = default;

            var control = Control("Validation UI", new()
            {
                layout = Utility.FillParentProps(),
                children = List(
                    LocalizationMetricsDialog(new()
                    {
                        element = new() { active = metricsDialogOpen },
                        layout = Utility.FillParentProps(new()
                        {
                            offsetMin = Value(new Vector2(95, 480)),
                            offsetMax = Value(new Vector2(-95, -95))
                        })
                    }),
                    Control("Bottom Bar", new()
                    {
                        layout = new()
                        {
                            pivot = Value(new Vector2(0.5f, 0)),
                            anchorMin = Value(new Vector2(0.5f, 0)),
                            anchorMax = Value(new Vector2(0.5f, 0)),
                            anchoredPosition = Value(new Vector2(0, 250)),
                            sizeDelta = Value(new Vector2(785, 170))
                        },
                        children = List(
                            LabeledButton(new LabeledButtonProps()
                            {
                                label = Value("Metrics"),
                                labelStyle = new TextStyleProps()
                                {
                                    color = lockupHealth.ObservableSelect(h => h.LocalizationLost ? Color.red : Color.white)
                                },
                                onClick = () => metricsDialogOpen.value = !metricsDialogOpen.value,
                                layout = new()
                                {
                                    sizeDelta = Value(new Vector2(255, 75)),
                                    pivot = Value(new Vector2(1, 0.5f)),
                                    anchorMin = Value(new Vector2(1, 0.5f)),
                                    anchorMax = Value(new Vector2(1, 0.5f)),
                                    anchoredPosition = Value(new Vector2(0, 0))
                                }
                            }),
                            LabeledButton(new LabeledButtonProps()
                            {
                                label = App.state.mapForLocalization.ObservableSelect(x =>
                                {
                                    if (x == Guid.Empty)
                                        return Value("Maps");

                                    return App.state.captures
                                        .ObservableSelect(x => x.Value)
                                        .ObservableFirstOrDefault(x => Observables.ObservableCombineValues(
                                            App.state.mapForLocalization,
                                            x.localizationMapId,
                                            (targetCapture, capture) => targetCapture == capture
                                        ))
                                        .ObservableSelect(x => x?.name.ObservableSelect(n => n ?? $"Unnamed [{x.id}]") ?? Value("Maps"));
                                }),
                                labelStyle = new TextStyleProps()
                                {
                                    textWrappingMode = Value(TMPro.TextWrappingModes.NoWrap),
                                    overflowMode = Value(TMPro.TextOverflowModes.Ellipsis)
                                },
                                onClick = () => selectValidationTargetDialog = SelectValidationTargetDialog(new()
                                {
                                    onValidationTargetSelected = x =>
                                    {
                                        App.state.mapForLocalization.value = x;
                                        App.state.localizing.value = true;
                                        selectValidationTargetDialog.Dispose();
                                    }
                                }),
                                layout = new()
                                {
                                    sizeDelta = Value(new Vector2(255, 75)),
                                    pivot = Value(new Vector2(0, 0.5f)),
                                    anchorMin = Value(new Vector2(0, 0.5f)),
                                    anchorMax = Value(new Vector2(0, 0.5f)),
                                    anchoredPosition = Value(new Vector2(0, 0))
                                }
                            }),
                            Toggle(prefab: elements.playButton, props: new ToggleProps()
                            {
                                value = App.state.localizing,
                                interactable = App.state.mapForLocalization.ObservableSelect(x => x != Guid.Empty),
                                onValueChanged = x => App.state.localizing.value = x,
                                layout = new()
                                {
                                    anchorMin = Value(new Vector2(0.5f, 0.5f)),
                                    anchorMax = Value(new Vector2(0.5f, 0.5f)),
                                    anchoredPosition = Value(new Vector2(0, 0))
                                }
                            })
                        )
                    })
                )
            });

            control.AddBinding(lockupTick);
            return control;
        }

        public struct SelectValidationTargetProps
        {
            public UnityAction<Guid> onValidationTargetSelected;
        }

        public struct NamePromptDialogProps
        {
            public Action<string> onSubmit;
        }

        public static IControl NamePromptDialog(NamePromptDialogProps props)
        {
            var input = new ObservableValue<string>("");
            return Dialog(new()
            {
                useBackground = Value(true),
                backgroundColor = Value(elements.backgroundColor),
                contentConstructor = dialog => Value(SafeArea(new()
                {
                    children = List(
                        VerticalLayout(new()
                        {
                            childControlWidth = Value(true),
                            childControlHeight = Value(true),
                            childForceExpandWidth = Value(true),
                            spacing = Value(30f),
                            padding = Value(new RectOffset(30, 30, 30, 30)),
                            layout = Utility.FillParentProps(),
                            children = List(
                                Title(new() { value = Value("Name this capture") }),
                                InputField(new InputFieldProps()
                                {
                                    layout = new() { flexibleWidth = Value(1f) },
                                    value = input,
                                    placeholderValue = Value("e.g. west stairwell"),
                                    onValueChanged = x => input.value = x
                                }),
                                Row(new()
                                {
                                    childAlignment = Value(TextAnchor.MiddleRight),
                                    children = List(
                                        LabeledButton(new LabeledButtonProps()
                                        {
                                            label = Value("OK"),
                                            interactable = input.ObservableSelect(n => !string.IsNullOrWhiteSpace(n)),
                                            onClick = () => props.onSubmit?.Invoke(input.value.Trim())
                                        })
                                    )
                                })
                            )
                        })
                    )
                }))
            });
        }

        public static IControl SelectValidationTargetDialog(SelectValidationTargetProps props = default)
        {
            return Dialog(new()
            {
                useBackground = Value(true),
                backgroundColor = Value(elements.backgroundColor),
                contentConstructor = dialog => Value(SafeArea(new()
                {
                    children = List(
                        TightRowsWideColumns(new()
                        {
                            padding = Value(new RectOffset(30, 30, 30, 30)),
                            layout = Utility.FillParentProps(),
                            children = List(
                                Title(new() { value = Value("Localization Maps") }),
                                ScrollRect(new()
                                {
                                    value = Value(new Vector2(0, 1)),
                                    horizontal = Value(false),
                                    layout = new() { flexibleHeight = Value(1f) },
                                    content = Value(
                                        TightRowsWideColumns(new()
                                        {
                                            padding = Value(new RectOffset(30, 30, 30, 30)),
                                            layout = Utility.FillParentProps(new()
                                            {
                                                pivot = Value(new Vector2(0, 1)),
                                                anchorMin = Value(new Vector2(0, 1)),
                                                anchorMax = Value(new Vector2(1, 1)),
                                                offsetMin = Value(new Vector2(0, 0)),
                                                offsetMax = Value(new Vector2(0, 0)),
                                                fitContentVertical = Value(ContentSizeFitter.FitMode.PreferredSize)
                                            }),
                                            children = App.state.captures
                                                .ObservableWhere(x => x.Value.localizationMapId.ObservableSelect(x => x != Guid.Empty))
                                                .ObservableOrderBy(x => x.Value.recordedAt.ObservableSelect(t => -t.Ticks))
                                                .ObservableSelect(x => LabeledButton(new LabeledButtonProps()
                                                {
                                                    label = x.Value.name.ObservableSelect(n => n ?? $"Unnamed [{x.Value.id}]"),
                                                    onClick = () => props.onValidationTargetSelected?.Invoke(x.Value.localizationMapId.value)
                                                }))
                                        })
                                    )
                                }),
                                Row(new()
                                {
                                    childAlignment = Value(TextAnchor.MiddleRight),
                                    children = List(
                                        LabeledButton(new LabeledButtonProps()
                                        {
                                            label = Value("Done"),
                                            onClick = dialog.Dispose
                                        })
                                    )
                                })
                            )
                        })
                    )
                }))
            });
        }

        public static IControl CaptureDataDialog(CaptureState capture)
        {
            return Dialog(new()
            {
                useBackground = Value(true),
                backgroundColor = Value(elements.backgroundColor),
                contentConstructor = dialog => Value(SafeArea(new()
                {
                    children = List(
                        VerticalLayout(new()
                        {
                            childControlWidth = Value(true),
                            childControlHeight = Value(true),
                            childForceExpandWidth = Value(true),
                            spacing = Value(30f),
                            padding = Value(new RectOffset(30, 30, 30, 30)),
                            layout = Utility.FillParentProps(),
                            children = List(
                                Title(new TextProps() { value = Value("Capture Data") }),
                                ScrollRect(new ScrollRectProps()
                                {
                                    vertical = Value(true),
                                    layout = new() { flexibleHeight = Value(1f) },
                                    content = Value(
                                        VerticalLayout(new()
                                        {
                                            childControlWidth = Value(true),
                                            childControlHeight = Value(true),
                                            spacing = Value(10f),
                                            padding = Value(new RectOffset(30, 30, 30, 30)),
                                            layout = new()
                                            {
                                                pivot = Value(new Vector2(0, 1)),
                                                anchorMin = Value(new Vector2(0, 1)),
                                                anchorMax = Value(new Vector2(1, 1)),
                                                offsetMin = Value(new Vector2(0, 0)),
                                                offsetMax = Value(new Vector2(0, 0)),
                                                fitContentVertical = Value(ContentSizeFitter.FitMode.PreferredSize)
                                            },
                                            children = List(
                                                LabeledControl(new LabeledControlProps()
                                                {
                                                    label = Value("Name"),
                                                    control = InputField(new InputFieldProps()
                                                    {
                                                        layout = new() { flexibleWidth = Value(1f) },
                                                        value = capture.name,
                                                        placeholderValue = Value(capture.id.ToString()),
                                                        onEndEdit = x => capture.name.value = x
                                                    })
                                                }),
                                                LabeledControl(new LabeledControlProps()
                                                {
                                                    label = Value("Source"),
                                                    labelWidth = Value(240f),
                                                    control = Text(new TextProps()
                                                    {
                                                        layout = new() { flexibleWidth = Value(1f) },
                                                        value = capture.type.ObservableSelect(x => x == DeviceType.ARFoundation ? "Mobile" : "Zed"),
                                                        style = new TextStyleProps()
                                                        {
                                                            verticalAlignment = Value(TMPro.VerticalAlignmentOptions.Capline),
                                                            horizontalAlignment = Value(TMPro.HorizontalAlignmentOptions.Right)
                                                        }
                                                    })
                                                }),
                                                LabeledControl(new LabeledControlProps()
                                                {
                                                    label = Value("Recorded At"),
                                                    labelWidth = Value(240f),
                                                    control = Text(new TextProps()
                                                    {
                                                        layout = new() { flexibleWidth = Value(1f) },
                                                        value = capture.recordedAt.ObservableSelect(x => x.ToString()),
                                                        style = new TextStyleProps()
                                                        {
                                                            verticalAlignment = Value(TMPro.VerticalAlignmentOptions.Capline),
                                                            horizontalAlignment = Value(TMPro.HorizontalAlignmentOptions.Right)
                                                        }
                                                    })
                                                }),
                                                Columns(new()
                                                {
                                                    spacing = Value(30f),
                                                    layout = new()
                                                    {
                                                        flexibleWidth = Value(1f),
                                                        minHeight = Value(75f),
                                                    },
                                                    columns = List(
                                                        LabeledButton(new LabeledButtonProps()
                                                        {
                                                            label = Value("Clear Local Files "),
                                                            interactable = Observables.ObservableCombineValues(
                                                                capture.status,
                                                                capture.hasLocalFiles,
                                                                (status, hasLocalFiles) =>
                                                                    hasLocalFiles && (
                                                                        status == CaptureUploadStatus.NotUploaded ||
                                                                        status == CaptureUploadStatus.ReconstructionNotStarted ||
                                                                        status == CaptureUploadStatus.Uploaded ||
                                                                        status == CaptureUploadStatus.MapCreated ||
                                                                        status == CaptureUploadStatus.Failed
                                                                    )
                                                            ),
                                                            onClick = () =>
                                                            {
                                                                CaptureController.DeleteCapture(capture.id, capture.type.value).Forget();

                                                                if (capture.status.value == CaptureUploadStatus.NotUploaded)
                                                                {
                                                                    App.state.captures.Remove(capture.id);
                                                                    dialog.Dispose();
                                                                }
                                                                else
                                                                {
                                                                    capture.hasLocalFiles.value = false;
                                                                }
                                                            }
                                                        }),
                                                        LabeledButton(new LabeledButtonProps()
                                                        {
                                                            label = Observables.ObservableCombineValues(
                                                                capture.status,
                                                                capture.reconstruction,
                                                                capture.clientProgress,
                                                                capture.uploadBytesPerSecond,
                                                                capture.uploadQueuePosition,
                                                                capture.uploadQueueDepth,
                                                                CaptureStatusLabel
                                                            ),
                                                            interactable = capture.status.ObservableSelect(CaptureStatusIsActionable),
                                                            onClick = () => OnCaptureActionClicked(capture)
                                                        })
                                                    )
                                                }),
                                                ObjectInspector(new ObjectInspectorProps()
                                                {
                                                    target = ManifestHelpers.ExtractOptions(capture.reconstruction.value),
                                                    foldout = new FoldoutProps()
                                                    {
                                                        label = new TextProps() { value = Value("Reconstruction Options") },
                                                        isOpen = Value(false),
                                                        interactable = capture.reconstruction.ObservableSelect(x => x != null)
                                                    },
                                                    isReadonly = Value(true)
                                                }),
                                                ObjectInspector(new ObjectInspectorProps()
                                                {
                                                    target = ManifestHelpers.ExtractMetrics(capture.reconstruction.value),
                                                    foldout = new FoldoutProps()
                                                    {
                                                        label = new TextProps() { value = Value("Reconstruction Metrics") },
                                                        isOpen = Value(false),
                                                        interactable = capture.reconstruction.ObservableSelect(x => x != null)
                                                    },
                                                    isReadonly = Value(true)
                                                })
                                            )
                                        })
                                    )
                                }),
                                HorizontalLayout(new()
                                {
                                    childControlWidth = Value(true),
                                    childControlHeight = Value(true),
                                    spacing = Value(10f),
                                    childAlignment = Value(TextAnchor.MiddleRight),
                                    children = List(
                                        LabeledButton(new LabeledButtonProps()
                                        {
                                            label = Value("Done"),
                                            onClick = dialog.Dispose
                                        })
                                    )
                                })
                            )
                        })
                    )
                }))
            });
        }
    }
}
