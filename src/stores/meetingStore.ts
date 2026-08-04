import { create } from "zustand";
import { commands, type MeetingSegment } from "@/bindings";

// `MeetingSegment` sale del binding generado, no se redeclara acá — así se
// entera el frontend cuando el backend cambia de forma. El resumen y el
// detalle completos de una reunión (`MeetingSummary`, `Meeting`,
// `MeetingSpeaker`) ya viven en `bindings.ts` (Historia 4, `get_meeting`/
// `list_meetings`); los tipos propios de este store se limitan a lo que sólo
// existe en memoria mientras una sesión graba.
export type MeetingStatus =
  | "recording"
  | "processing"
  | "ready"
  | "interrupted";
export type MeetingKind = "presencial" | "virtual";

/**
 * Estado de la sesión de reunión en curso.
 *
 * Vive en memoria a propósito: no hay comando para preguntarle al backend
 * "¿hay una reunión grabando ahora mismo, y cuál es?", así que cerrar y
 * reabrir la ventana durante una reunión pierde de vista la sesión en esta
 * pantalla aunque la grabación siga corriendo. La consecuencia está acotada:
 * el backend rechaza empezar otra con `recording_busy` y ese mensaje se
 * muestra tal cual; y si la app se cierra de verdad, la reunión queda
 * `interrupted` y aparece como tal en el registro (Historia 4).
 */
interface MeetingStore {
  /** `null` = no hay ninguna reunión en curso en esta ventana. */
  activeMeetingId: number | null;
  status: MeetingStatus | null;
  /** Segmentos de la sesión en curso, en el orden en que llegaron. */
  segments: MeetingSegment[];
  /**
   * Lo que se está diciendo ahora y el backend todavía no cierra
   * (`meeting-pending-segments`). No está persistido: se reemplaza entero en
   * cada actualización y se vacía al terminar la sesión. Es la mitad "en
   * curso" del transcript en vivo — la misma distinción que el overlay del
   * dictado hace entre `committed` y `tentative`.
   */
  pendingSegments: MeetingSegment[];
  /** Nombres puestos por el usuario, por id de hablante. */
  speakerNames: Record<number, string>;
  isStarting: boolean;
  isStopping: boolean;

  startMeeting: (kind: MeetingKind) => Promise<void>;
  stopMeeting: () => Promise<void>;
  appendSegment: (segment: MeetingSegment) => void;
  setPendingSegments: (segments: MeetingSegment[]) => void;
  markFinished: () => void;
  markErrored: () => void;
  adoptActive: (
    meetingId: number,
    segments: MeetingSegment[],
    speakerNames: Record<number, string>,
  ) => void;
  setSpeakerName: (speakerId: number, name: string) => void;
  reset: () => void;
}

export const useMeetingStore = create<MeetingStore>()((set, get) => ({
  activeMeetingId: null,
  status: null,
  segments: [],
  pendingSegments: [],
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
        pendingSegments: [],
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

  setPendingSegments: (segments) => set({ pendingSegments: segments }),

  // La sesión terminó normalmente. Limpia `activeMeetingId` igual que
  // `markErrored` de aquí abajo, y por la misma razón: mientras quede un id
  // puesto, `startMeeting` cree que sigue habiendo una reunión viva en esta
  // ventana y no deja empezar otra — aunque el backend ya la dejó en
  // `status = 'ready'` y está libre para grabar de nuevo.
  //
  // Los segmentos ya mostrados NO se borran acá tampoco: el backend los
  // tiene persistidos (FR-007) y borrarlos de la pantalla haría parecer que
  // se perdió lo que sí se guardó. `startMeeting` los limpia recién cuando
  // arranca la próxima reunión de verdad.
  //
  // Lo pendiente sí se limpia (a diferencia de los segmentos ya guardados):
  // no está persistido en ningún lado y, con la sesión cerrada, ya no puede
  // crecer ni confirmarse. Lo que valía de ahí se cerró con el `Flush` del
  // backend y llegó como `meeting-segment`.
  markFinished: () =>
    set({ activeMeetingId: null, status: "ready", pendingSegments: [] }),

  // La sesión murió (falla del pipeline de captura o del cierre). Vuelve a
  // "listo para grabar" — sin esto la pantalla quedaba clavada en "Cerrando…"
  // para siempre y `startMeeting` retornaba en silencio por su guard, así que
  // no había forma de grabar otra sin reiniciar la app.
  //
  // Los segmentos ya mostrados NO se borran: el backend los tiene
  // persistidos (FR-007) y borrarlos de la pantalla haría parecer que se
  // perdió lo que sí se guardó.
  markErrored: () =>
    set({ activeMeetingId: null, status: null, pendingSegments: [] }),

  // Adopta una reunión que ya está grabando en el backend pero que esta
  // ventana todavía no conoce — por ejemplo, se empezó desde el popover
  // mientras la ventana de reuniones estaba escondida o recién se creó (ver
  // `useMeetingActiveSync` en `hooks/useMeetings.ts`, el único llamador).
  // Sólo tiene sentido cuando `activeMeetingId` acá es `null`: si esta
  // ventana ya sabe de una sesión propia, `useMeetingActiveSync` no llama a
  // esto, así que no hace falta guardarlo de nuevo.
  adoptActive: (meetingId, segments, speakerNames) =>
    set({
      activeMeetingId: meetingId,
      status: "recording",
      segments,
      pendingSegments: [],
      speakerNames,
    }),

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
      pendingSegments: [],
      speakerNames: {},
    }),
}));
