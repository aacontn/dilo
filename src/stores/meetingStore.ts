import { create } from "zustand";
import { commands, type MeetingSegment } from "@/bindings";

// Tipos que todavía no vienen de `bindings.ts` porque sus comandos no
// existen (`get_meeting`/`list_meetings` son T035). Los que sí existen se
// importan del binding generado — `MeetingSegment` arriba — en vez de
// redeclararlos acá, que es como se entera el frontend cuando el backend
// cambia de forma.
export type MeetingStatus =
  | "recording"
  | "processing"
  | "ready"
  | "interrupted";
export type MeetingKind = "presencial" | "virtual";

export interface MeetingSummary {
  id: number;
  title: string;
  kind: MeetingKind;
  startedAt: number;
  endedAt: number | null;
  status: MeetingStatus;
}

export interface MeetingSpeaker {
  id: number;
  label: string;
  displayName: string | null;
}

export interface ActionItem {
  id: number;
  text: string;
  done: boolean;
}

export interface Meeting extends MeetingSummary {
  summary: string | null;
  notes: string | null;
  segments: MeetingSegment[];
  speakers: MeetingSpeaker[];
  actionItems: ActionItem[];
}

/**
 * Estado de la sesión de reunión en curso.
 *
 * Vive en memoria a propósito: mientras no exista `list_meetings` (T035) no
 * hay forma de preguntarle al backend "¿hay una reunión grabando?", así que
 * cerrar y reabrir la ventana durante una reunión pierde de vista la sesión
 * aunque la grabación siga corriendo. La consecuencia está acotada: el
 * backend rechaza empezar otra con `recording_busy` y ese mensaje se muestra
 * tal cual. Cuando llegue T035 esto se hidrata al montar.
 */
interface MeetingStore {
  /** `null` = no hay ninguna reunión en curso en esta ventana. */
  activeMeetingId: number | null;
  status: MeetingStatus | null;
  /** Segmentos de la sesión en curso, en el orden en que llegaron. */
  segments: MeetingSegment[];
  /** Nombres puestos por el usuario, por id de hablante. */
  speakerNames: Record<number, string>;
  isStarting: boolean;
  isStopping: boolean;

  startMeeting: (kind: MeetingKind) => Promise<void>;
  stopMeeting: () => Promise<void>;
  appendSegment: (segment: MeetingSegment) => void;
  markFinished: () => void;
  setSpeakerName: (speakerId: number, name: string) => void;
  reset: () => void;
}

export const useMeetingStore = create<MeetingStore>()((set, get) => ({
  activeMeetingId: null,
  status: null,
  segments: [],
  speakerNames: {},
  isStarting: false,
  isStopping: false,

  startMeeting: async (kind) => {
    if (get().isStarting || get().activeMeetingId !== null) return;
    set({ isStarting: true });
    try {
      const result = await commands.startMeeting(kind);
      if (result.status === "error") throw new Error(result.error);
      set({
        activeMeetingId: result.data,
        status: "recording",
        segments: [],
        speakerNames: {},
      });
    } finally {
      set({ isStarting: false });
    }
  },

  stopMeeting: async () => {
    const meetingId = get().activeMeetingId;
    if (meetingId === null || get().isStopping) return;
    set({ isStopping: true });
    try {
      const result = await commands.stopMeeting(meetingId);
      if (result.status === "error") throw new Error(result.error);
      // No se limpia la sesión acá: el backend sigue transcribiendo lo que
      // quedó en la cola y esos segmentos llegan después de detener. La
      // sesión se cierra con `meeting-finished` (markFinished).
      set({ status: "processing" });
    } finally {
      set({ isStopping: false });
    }
  },

  // Ignora un id que ya está: React monta los efectos dos veces en
  // StrictMode, y un segmento repetido en el transcript se lee como si
  // alguien hubiera dicho la misma frase dos veces.
  appendSegment: (segment) =>
    set((state) =>
      state.segments.some((existing) => existing.id === segment.id)
        ? state
        : { segments: [...state.segments, segment] },
    ),

  markFinished: () => set({ status: "ready" }),

  setSpeakerName: (speakerId, name) =>
    set((state) => {
      const speakerNames = { ...state.speakerNames };
      if (name.trim() === "") {
        delete speakerNames[speakerId];
      } else {
        speakerNames[speakerId] = name.trim();
      }
      return { speakerNames };
    }),

  reset: () =>
    set({
      activeMeetingId: null,
      status: null,
      segments: [],
      speakerNames: {},
    }),
}));
