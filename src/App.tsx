import { useEffect, useState, useRef, type ReactNode } from "react";
import { toast, Toaster } from "sonner";
import { useTranslation } from "react-i18next";
import type { TFunction } from "i18next";
import { listen } from "@tauri-apps/api/event";
import { platform } from "@tauri-apps/plugin-os";
import {
  checkAccessibilityPermission,
  checkMicrophonePermission,
} from "tauri-plugin-macos-permissions-api";
import {
  AssistantErrorEvent,
  ModelStateEvent,
  ModeShortcutsClearedEvent,
} from "./lib/types/events";
import "./App.css";
import AccessibilityPermissions from "./components/AccessibilityPermissions";
import Footer from "./components/footer";
import Onboarding, {
  AccessibilityOnboarding,
  DictationTestOnboarding,
} from "./components/onboarding";
import { Sidebar, SidebarSection, SECTIONS_CONFIG } from "./components/Sidebar";
import { HomeDashboard } from "./components/home";
import { WhatsNewGate } from "./components/whats-new";
import { useOsType } from "./hooks/useOsType";
import { useRecordingErrorToast } from "./hooks/useRecordingErrorToast";
import { useSettings } from "./hooks/useSettings";
import { useSettingsStore } from "./stores/settingsStore";
import { commands, events } from "@/bindings";
import { getLanguageDirection, initializeRTL } from "@/lib/utils/rtl";
import {
  getNextOnboardingStep,
  type OnboardingStep,
} from "@/lib/utils/onboardingFlow";
import {
  buildClearedNoticeText,
  CLEARED_NOTICE_DURATION_MS,
  MODE_SHORTCUTS_CLEARED_EVENT,
  shouldShowClearedNotice,
} from "@/lib/clearedShortcutsNotice";
import { attachOrDiscardListener } from "@/lib/utils/keyboard";

// Un solo toast para los cuatro tipos de `AssistantErrorEvent` — lo usan
// tanto el listener en vivo (ventana abierta) como el vaciado de la cola de
// pendientes (ver `commands.takePendingAssistantNotices`) al montar, así el
// aviso se ve igual llegue por el camino que llegue.
// Tipo laxo a propósito: lo alimentan tanto el evento en vivo
// (`AssistantErrorEvent` de `lib/types/events.ts`, `error_type` como unión
// literal) como `commands.takePendingAssistantNotices()` (bindings.ts
// generado por specta, `error_type: string`) — ambos calzan acá sin castear.
const showAssistantErrorToast = (
  t: TFunction,
  event: { error_type: string; detail?: string | null },
) => {
  const { error_type, detail } = event;
  if (error_type === "disabled") {
    toast.error(t("errors.assistantDisabledTitle"), {
      description: t("errors.assistantDisabled"),
    });
  } else if (error_type === "not_configured") {
    toast.error(t("errors.assistantNotConfiguredTitle"), {
      description: t("errors.assistantNotConfigured"),
    });
  } else if (error_type === "tts_failed") {
    toast.error(t("errors.assistantTtsFailedTitle"), {
      description: detail ?? t("errors.assistantTtsFailed"),
    });
  } else {
    toast.error(t("errors.assistantFailedTitle"), {
      description: detail ?? t("errors.assistantFailed"),
    });
  }
};

const renderSettingsContent = (
  section: SidebarSection,
  onNavigate: (section: SidebarSection) => void,
) => {
  if (section === "home") {
    return <HomeDashboard onCustomize={() => onNavigate("postprocessing")} />;
  }
  const ActiveComponent =
    SECTIONS_CONFIG[section]?.component || SECTIONS_CONFIG.general.component;
  return <ActiveComponent />;
};

/**
 * Si el aviso de atajos retirados ya se mostró **en esta sesión**. Rust reemite
 * el aviso a propósito (no puede saber si había alguien escuchando), así que la
 * repetición se corta acá. No se persiste: si la persona se pierde el toast,
 * vuelve en el próximo arranque — hasta que asigne una tecla de modo, que es
 * cuando `change_mode_shortcut` borra el aviso del store.
 */
let clearedNoticeShown = false;

function App() {
  const { t, i18n } = useTranslation();
  const osType = useOsType();
  const [onboardingStep, setOnboardingStep] = useState<OnboardingStep | null>(
    null,
  );
  // Track if this is a returning user who just needs to grant permissions
  // (vs a new user who needs full onboarding including model selection)
  const [isReturningUser, setIsReturningUser] = useState(false);
  const [currentSection, setCurrentSection] = useState<SidebarSection>("home");
  const { settings, updateSetting } = useSettings();
  const direction = getLanguageDirection(i18n.language);
  const refreshAudioDevices = useSettingsStore(
    (state) => state.refreshAudioDevices,
  );
  const refreshOutputDevices = useSettingsStore(
    (state) => state.refreshOutputDevices,
  );
  const hasCompletedPostOnboardingInit = useRef(false);

  useEffect(() => {
    checkOnboardingStatus();
  }, []);

  // Initialize RTL direction when language changes
  useEffect(() => {
    initializeRTL(i18n.language);
  }, [i18n.language]);

  // Initialize Enigo, shortcuts, and refresh audio devices when main app loads
  useEffect(() => {
    if (
      (onboardingStep === "test" || onboardingStep === "done") &&
      !hasCompletedPostOnboardingInit.current
    ) {
      hasCompletedPostOnboardingInit.current = true;
      Promise.all([
        commands.initializeEnigo(),
        commands.initializeShortcuts(),
      ]).catch((e) => {
        console.warn("Failed to initialize:", e);
      });
      refreshAudioDevices();
      refreshOutputDevices();
    }
  }, [onboardingStep, refreshAudioDevices, refreshOutputDevices]);

  // Handle keyboard shortcuts for debug mode toggle
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      // Check for Ctrl+Shift+D (Windows/Linux) or Cmd+Shift+D (macOS)
      const isDebugShortcut =
        event.shiftKey &&
        event.key.toLowerCase() === "d" &&
        (event.ctrlKey || event.metaKey);

      if (isDebugShortcut) {
        event.preventDefault();
        const currentDebugMode = settings?.debug_mode ?? false;
        updateSetting("debug_mode", !currentDebugMode);
      }
    };

    // Add event listener when component mounts
    document.addEventListener("keydown", handleKeyDown);

    // Cleanup event listener when component unmounts
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [settings?.debug_mode, updateSetting]);

  // El toast de un dictado que no pudo empezar. El listener ya no vive acá:
  // es compartido con Reuniones y el popover, porque abrir Reuniones esconde
  // esta ventana y el aviso se dibujaba donde nadie lo veía (ver
  // `useRecordingErrorToast`).
  useRecordingErrorToast();

  // Avisa cuando la caída al proveedor general cruzó de local a la nube: el
  // dictado sí se procesó, pero por un camino que el usuario debía conocer.
  useEffect(() => {
    const unlisten = events.postProcessFallback.listen((event) => {
      const { mode_name, provider_label } = event.payload;
      toast.info(
        t("settings.postProcessing.modeProvider.fallbackNotice", {
          mode: mode_name,
          provider: provider_label,
        }),
      );
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [t]);

  // Gemini no respondió y el dictado lo rescató un modelo local. El aviso es
  // después del hecho —el texto ya se pegó— y nunca muestra el token crudo que
  // manda Rust (`offline`, `daily_quota`, …): se traduce acá, con una frase
  // genérica para un token que este idioma todavía no conozca. Con
  // `fallback_model` vacío no hubo rescate posible y el mensaje cambia.
  useEffect(() => {
    const unlisten = events.geminiFallback.listen((event) => {
      const { fallback_model, reason } = event.payload;
      const description = t(`gemini.fallback_reason.${reason}`, {
        defaultValue: t("gemini.fallback_reason.generic"),
      });
      if (!fallback_model) {
        toast.error(t("gemini.fallback_none"), { description });
        return;
      }
      toast.info(t("gemini.fallback_notice", { model: fallback_model }), {
        description,
      });
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [t]);

  // Y los cruces que pasaron con esta ventana cerrada: dictar con la ventana
  // cerrada es lo NORMAL, y al cerrarla se destruye el webview con su
  // listener, así que sin esto el aviso se perdía justo en el caso común.
  // La llamada consume la cola: se muestran una vez, no en cada apertura.
  // Sólo al montar: la cola es justamente lo que pasó mientras no había
  // ventana.
  useEffect(() => {
    void (async () => {
      try {
        const pending = await commands.takePendingFallbackNotices();
        for (const notice of pending) {
          toast.info(
            t("settings.postProcessing.modeProvider.fallbackNotice", {
              mode: notice.mode_name,
              provider: notice.provider_label,
            }),
          );
        }
      } catch (error) {
        console.error("No se pudieron leer los avisos pendientes:", error);
      }
    })();
  }, []);

  // Los atajos de modo que la actualización retiró por no poder dispararse
  // (regla 2 de la migración). Rust deja el aviso **guardado en el store** —la
  // migración corre al arrancar, casi siempre sin ninguna ventana abierta— y
  // lo reemite cada vez que una ventana se muestra y en cada
  // `get_app_settings`. Acá se pide ese refresco a propósito **después** de
  // dejar puesto el listener: es la única forma de no perder la carrera del
  // arranque, porque `listen()` resuelve asincrónicamente.
  useEffect(() => {
    let canceled = false;
    let unlisten: (() => void) | undefined;
    void (async () => {
      const stop = await listen<ModeShortcutsClearedEvent>(
        MODE_SHORTCUTS_CLEARED_EVENT,
        (event) => {
          if (!shouldShowClearedNotice(event.payload, clearedNoticeShown))
            return;
          clearedNoticeShown = true;
          const { title, description } = buildClearedNoticeText(
            event.payload,
            osType,
            t,
          );
          toast.warning(title, {
            description,
            duration: CLEARED_NOTICE_DURATION_MS,
          });
        },
      );
      attachOrDiscardListener(stop, canceled, (fn) => {
        unlisten = fn;
      });
      if (canceled) return;
      await commands.getAppSettings();
    })();
    return () => {
      canceled = true;
      unlisten?.();
    };
  }, [t, osType]);

  // Listen for paste failures and show a toast.
  // The technical error detail is logged to handy.log on the Rust side
  // (see actions.rs `error!("Failed to paste transcription: ...")`),
  // so we show a localized, user-friendly message here instead of the raw error.
  useEffect(() => {
    const unlisten = listen("paste-error", () => {
      toast.error(t("errors.pasteFailedTitle"), {
        description: t("errors.pasteFailed"),
      });
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [t]);

  // Listen for transcription failures and show a toast.
  // The payload is the backend error message (also logged to handy.log).
  useEffect(() => {
    const unlisten = listen<string>("transcription-error", (event) => {
      toast.error(t("errors.transcriptionFailedTitle"), {
        description: event.payload,
      });
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [t]);

  // Listen for local note-write failures and show a toast.
  // The payload is the backend error message (notes.rs emits `note-error` when
  // the local markdown file can't be written; also logged to dilo.log).
  useEffect(() => {
    const unlisten = listen<string>("note-error", (event) => {
      toast.error(t("errors.noteSaveFailed", { error: event.payload }));
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [t]);

  // Listen for voice assistant mode failures and show a toast (assistant.rs,
  // `emit_assistant_error`) — "blank" transcriptions are handled in silence on
  // the Rust side and never reach this event.
  useEffect(() => {
    const unlisten = listen<AssistantErrorEvent>("assistant-error", (event) => {
      showAssistantErrorToast(t, event.payload);
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [t]);

  // Y los avisos del asistente que pasaron con esta ventana cerrada: usar el
  // atajo del asistente es justo lo NORMAL con la ventana principal cerrada
  // (dictar no necesita tenerla abierta), así que sin esto el aviso más
  // importante —"apretaste la tecla y no pasó nada, acá está el porqué"— se
  // perdía en el caso común. Mismo patrón que el vaciado de
  // `takePendingFallbackNotices` de abajo. Sólo al montar: la cola es
  // justamente lo que pasó mientras no había ventana.
  useEffect(() => {
    void (async () => {
      try {
        const pending = await commands.takePendingAssistantNotices();
        for (const notice of pending) {
          showAssistantErrorToast(t, notice);
        }
      } catch (error) {
        console.error(
          "No se pudieron leer los avisos del asistente pendientes:",
          error,
        );
      }
    })();
  }, []);

  // Listen for model loading failures and show a toast
  useEffect(() => {
    const unlisten = listen<ModelStateEvent>("model-state-changed", (event) => {
      if (event.payload.event_type === "loading_failed") {
        toast.error(
          t("errors.modelLoadFailed", {
            model:
              event.payload.model_name || t("errors.modelLoadFailedUnknown"),
          }),
          {
            description: event.payload.error,
          },
        );
      }
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [t]);

  const revealMainWindowForPermissions = async () => {
    try {
      await commands.showMainWindowCommand();
    } catch (e) {
      console.warn("Failed to show main window for permission onboarding:", e);
    }
  };

  const checkOnboardingStatus = async () => {
    try {
      const settingsResult = await commands.getAppSettings();
      const hasCompletedOnboarding =
        settingsResult.status === "ok" &&
        settingsResult.data.onboarding_completed === true;
      const currentPlatform = platform();

      if (hasCompletedOnboarding) {
        // Returning user - check if they need to grant permissions first
        setIsReturningUser(true);

        if (currentPlatform === "macos") {
          try {
            const [hasAccessibility, hasMicrophone] = await Promise.all([
              checkAccessibilityPermission(),
              checkMicrophonePermission(),
            ]);
            if (!hasAccessibility || !hasMicrophone) {
              await revealMainWindowForPermissions();
              setOnboardingStep("accessibility");
              return;
            }
          } catch (e) {
            console.warn("Failed to check macOS permissions:", e);
            // If we can't check, proceed to main app and let them fix it there
          }
        }

        if (currentPlatform === "windows") {
          try {
            const microphoneStatus =
              await commands.getWindowsMicrophonePermissionStatus();
            if (
              microphoneStatus.supported &&
              microphoneStatus.overall_access === "denied"
            ) {
              await revealMainWindowForPermissions();
              setOnboardingStep("accessibility");
              return;
            }
          } catch (e) {
            console.warn("Failed to check Windows microphone permissions:", e);
            // If we can't check, proceed to main app and let them fix it there
          }
        }

        setOnboardingStep("done");
      } else {
        // New user - start full onboarding
        setIsReturningUser(false);
        setOnboardingStep("accessibility");
      }
    } catch (error) {
      console.error("Failed to check onboarding status:", error);
      setOnboardingStep("accessibility");
    }
  };

  const handleAccessibilityComplete = () => {
    setOnboardingStep(
      getNextOnboardingStep("permissions-complete", isReturningUser),
    );
  };

  const handleModelSelected = () => {
    setOnboardingStep(getNextOnboardingStep("model-selected", false));
  };

  const handleDictationTestComplete = () => {
    setOnboardingStep(getNextOnboardingStep("test-complete", false));
  };

  // Rendered once around every step below (including onboarding) so
  // toast.error() calls surface to the user. sonner renders via a portal, so
  // its position in the tree doesn't affect layout. Without this, errors during
  // onboarding (e.g. a model download failing because blob.handy.computer is
  // unreachable) are silently swallowed and the wizard just appears to "blink".
  const toaster = (
    <Toaster
      theme="system"
      toastOptions={{
        unstyled: true,
        classNames: {
          toast:
            "glass-toast rounded-xl px-4 py-3 flex items-center gap-3 text-sm",
          title: "font-medium",
          description: "text-muted-text",
          actionButton:
            "shrink-0 cursor-pointer rounded-lg bg-text/10 px-2 py-1 text-xs font-medium text-text transition-colors hover:bg-text/20",
        },
      }}
    />
  );

  // Still checking onboarding status
  if (onboardingStep === null) {
    return null;
  }

  // Select the content for the current step. The Toaster is rendered once, in a
  // stable wrapper around this node, so crossing between onboarding steps and
  // the main app never remounts it (which would drop any in-flight toast).
  const titlebarDragRegion = (
    <div
      className="dilo-titlebar-drag-region"
      data-tauri-drag-region
      aria-hidden="true"
    />
  );

  let content: ReactNode;
  if (onboardingStep === "accessibility") {
    content = (
      <div className="dilo-onboarding-shell">
        {titlebarDragRegion}
        <AccessibilityOnboarding onComplete={handleAccessibilityComplete} />
      </div>
    );
  } else if (onboardingStep === "model") {
    content = (
      <div className="dilo-onboarding-shell">
        {titlebarDragRegion}
        <Onboarding onModelSelected={handleModelSelected} />
      </div>
    );
  } else if (onboardingStep === "test") {
    content = (
      <div className="dilo-onboarding-shell">
        {titlebarDragRegion}
        <DictationTestOnboarding onComplete={handleDictationTestComplete} />
      </div>
    );
  } else {
    content = (
      <div
        dir={direction}
        className="dilo-shell h-screen flex flex-col select-none cursor-default"
      >
        {titlebarDragRegion}
        <WhatsNewGate />
        {/* Main content area that takes remaining space */}
        <div className="dilo-workspace flex-1 flex overflow-hidden">
          <Sidebar
            activeSection={currentSection}
            onSectionChange={setCurrentSection}
          />
          {/* Scrollable content area */}
          <main className="dilo-main flex-1 flex flex-col overflow-hidden">
            <div className="dilo-scroll flex-1 overflow-y-auto">
              <div className="dilo-page flex flex-col items-center gap-4">
                <AccessibilityPermissions />
                {renderSettingsContent(currentSection, setCurrentSection)}
              </div>
            </div>
          </main>
        </div>
        {/* Fixed footer at bottom */}
        <Footer />
      </div>
    );
  }

  return (
    <>
      {toaster}
      {content}
    </>
  );
}

export default App;
