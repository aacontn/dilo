import type { ModelInfo } from "@/bindings";

/**
 * El proveedor bajo el que vive la API key de Google. Es el mismo id del
 * catálogo de post-proceso (`settings.rs`, `"google"`), a propósito: quien ya
 * puso su key para transformar texto no tiene que pegarla dos veces para
 * dictar con Gemini.
 */
export const GOOGLE_PROVIDER_ID = "google";

/**
 * Un motor en línea: vive en el servidor del proveedor, no se descarga, no
 * ocupa disco y no se borra. La tarjeta de un modelo así no muestra tamaño,
 * progreso ni botón de eliminar — no hay nada que descargar ni que liberar.
 */
export const isCloudModel = (model: Pick<ModelInfo, "source">): boolean =>
  model.source === "Cloud";

/**
 * Los modelos que de verdad ocupan disco en esta máquina.
 *
 * Un motor en línea llega siempre con `is_downloaded: true` — no hay nada que
 * bajar — así que preguntar sólo por esa bandera hace que el onboarding de una
 * instalación recién hecha salude con "modelos que ya tienes" y le muestre
 * Gemini, que nadie descargó. Quien sí tenga modelos locales ve exactamente lo
 * mismo de antes.
 */
export const downloadedLocalModels = <
  T extends Pick<ModelInfo, "source" | "is_downloaded">,
>(
  models: T[],
): T[] => models.filter((model) => model.is_downloaded && !isCloudModel(model));

/**
 * Gemini 3.5 Transcribe, el único motor de dictado en línea por ahora. Se
 * pregunta por el motor y no por el id para que un segundo modelo de Gemini
 * (o un rename del id del catálogo) no deje la tarjeta muda.
 */
export const isGeminiModel = (model: Pick<ModelInfo, "engine_type">): boolean =>
  model.engine_type === "GeminiTranscribe";

/**
 * ¿Hay una API key de Google guardada? Devuelve un sí/no y nunca el valor: la
 * key no sale de esta comprobación ni se muestra en la tarjeta.
 */
export const hasGoogleApiKey = (
  settings: {
    post_process_api_keys?: Partial<{ [key: string]: string }> | null;
  } | null,
): boolean =>
  (settings?.post_process_api_keys?.[GOOGLE_PROVIDER_ID] ?? "").trim().length >
  0;
