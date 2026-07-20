export interface ModelStateEvent {
  event_type: string;
  model_id?: string;
  model_name?: string;
  error?: string;
}

export interface RecordingErrorEvent {
  error_type: string;
  detail?: string;
}

/** Payload de `assistant-error` (ver `assistant.rs`, `emit_assistant_error`). */
export interface AssistantErrorEvent {
  error_type: "disabled" | "not_configured" | "llm_failed" | "tts_failed";
  detail?: string;
}
