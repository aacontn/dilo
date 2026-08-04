import { beforeEach, describe, expect, test } from "bun:test";
import type { MeetingSegment, MeetingSummary } from "@/bindings";
import { useMeetingStore } from "@/stores/meetingStore";
import {
  appendMeetingPage,
  exceedsSpeakerCap,
  groupConsecutiveSegments,
  isPastMeeting,
  RECENT_MEETINGS_LIMIT,
  SORTFORMER_MAX_SPEAKERS,
} from "@/components/meeting/meetingFormat";

const segment = (id: number): MeetingSegment => ({
  id,
  speaker_id: null,
  text: `turno ${id}`,
  started_at_ms: id * 1000,
  ended_at_ms: id * 1000 + 500,
  overlapped: false,
});

const summary = (id: number): MeetingSummary => ({
  id,
  title: `Reunión ${id}`,
  kind: "presencial",
  started_at: id,
  ended_at: id + 60,
  status: "ready",
});

describe("meetingStore.markErrored", () => {
  beforeEach(() => {
    useMeetingStore.setState({
      activeMeetingId: null,
      status: null,
      segments: [],
      speakerNames: {},
      isStarting: false,
      isStopping: false,
    });
  });

  test("saca la sesión de 'Cerrando…' y deja grabar otra", () => {
    useMeetingStore.setState({ activeMeetingId: 7, status: "processing" });

    useMeetingStore.getState().markErrored();

    const state = useMeetingStore.getState();
    expect(state.status).toBe(null);
    expect(state.activeMeetingId).toBe(null);
  });

  test("no borra el transcript ya mostrado: esos segmentos sí se guardaron", () => {
    useMeetingStore.setState({
      activeMeetingId: 7,
      status: "recording",
      segments: [segment(1), segment(2)],
      speakerNames: { 3: "Ana" },
    });

    useMeetingStore.getState().markErrored();

    const state = useMeetingStore.getState();
    expect(state.segments.map((s) => s.id)).toEqual([1, 2]);
    expect(state.speakerNames).toEqual({ 3: "Ana" });
  });
});

describe("meetingStore.markFinished", () => {
  beforeEach(() => {
    useMeetingStore.setState({
      activeMeetingId: null,
      status: null,
      segments: [],
      speakerNames: {},
      isStarting: false,
      isStopping: false,
    });
  });

  // Regresión: sin limpiar `activeMeetingId` acá, `startMeeting` seguía
  // creyendo que había una reunión viva en esta ventana después de
  // detenerla y no dejaba empezar otra — aunque el backend ya la dejó en
  // `status = 'ready'`, libre para grabar de nuevo.
  test("deja `activeMeetingId` en null para poder empezar otra reunión", () => {
    useMeetingStore.setState({ activeMeetingId: 7, status: "processing" });

    useMeetingStore.getState().markFinished();

    const state = useMeetingStore.getState();
    expect(state.activeMeetingId).toBe(null);
    expect(state.status).toBe("ready");
  });

  test("no borra el transcript ya mostrado: esos segmentos sí se guardaron", () => {
    useMeetingStore.setState({
      activeMeetingId: 7,
      status: "processing",
      segments: [segment(1), segment(2)],
      speakerNames: { 3: "Ana" },
    });

    useMeetingStore.getState().markFinished();

    const state = useMeetingStore.getState();
    expect(state.segments.map((s) => s.id)).toEqual([1, 2]);
    expect(state.speakerNames).toEqual({ 3: "Ana" });
  });
});

describe("un turno perdido no termina la sesión en la ventana", () => {
  // Regresión: mandar `meeting-error` por un turno fallido hacía que el
  // store limpiara la sesión mientras el backend seguía capturando. Sin
  // `isRecording`/`isProcessing`, `RecordingControls` deja de dibujar el
  // botón de detener y el micrófono (y el árbitro, o sea también el dictado)
  // quedan tomados hasta reiniciar la app.
  const listenerBlock = (source: string, event: string): string => {
    const start = source.indexOf(`events.${event}.listen(`);
    expect(start).toBeGreaterThan(-1);
    const rest = source.slice(start);
    const end = rest.indexOf("\n    });");
    expect(end).toBeGreaterThan(-1);
    return rest.slice(0, end);
  };

  test("el listener de meeting-turn-failed avisa pero no limpia la sesión", async () => {
    const source = await Bun.file("src/hooks/useMeetings.ts").text();
    const handler = listenerBlock(source, "meetingTurnFailed");

    expect(handler).not.toContain("markErrored");
    expect(handler).toContain("meeting.errors.turnFailed");
  });

  test("markErrored se llama sólo desde el listener de fin de sesión", async () => {
    const source = await Bun.file("src/hooks/useMeetings.ts").text();

    expect(listenerBlock(source, "meetingError")).toContain("markErrored()");
    expect(source.match(/markErrored\(\)/g)).toHaveLength(1);
  });
});

/**
 * Reporte del dueño (2026-08-04): la ventana de Reuniones mostró "no estoy
 * grabando" con una reunión corriendo, y los rechazos del dictado se
 * dibujaron en la ventana de Ajustes, que estaba escondida. Las dos mitades
 * viven en cableado entre Rust y ventanas reales —no hay cómo montarlas en
 * un test unitario— así que lo que se protege acá es que el cableado siga
 * puesto: si alguien saca el aviso de "me mostré", o el listener compartido
 * de una ventana, esto falla.
 */
describe("el aviso llega donde el usuario está mirando", () => {
  test("Rust y el frontend usan el mismo nombre de evento para 'me mostré'", async () => {
    const ts = await Bun.file("src/lib/windowShown.ts").text();
    const rust = await Bun.file("src-tauri/src/utils.rs").text();

    expect(ts).toContain('export const WINDOW_SHOWN_EVENT = "window-shown"');
    expect(rust).toContain(
      'pub const WINDOW_SHOWN_EVENT: &str = "window-shown"',
    );
  });

  test("mostrar la ventana de Reuniones avisa, después de show()", async () => {
    const source = await Bun.file("src-tauri/src/meeting_window.rs").text();
    const open = source.slice(source.indexOf("pub fn open_meetings_window"));

    expect(open.indexOf("window.show()")).toBeLessThan(
      open.indexOf("emit_window_shown"),
    );
  });

  test("resolver la reunión activa no depende sólo del foco", async () => {
    const source = await Bun.file("src/lib/activeMeeting.ts").text();

    expect(source).toContain("useWindowShown(");
    expect(source).toContain("onFocusChanged");
  });

  test("las tres ventanas con interfaz escuchan los rechazos del dictado", async () => {
    for (const file of [
      "src/App.tsx",
      "src/meetings/MeetingsWindow.tsx",
      "src/popover/PopoverWindow.tsx",
    ]) {
      expect(await Bun.file(file).text()).toContain("useRecordingErrorToast()");
    }
  });

  test("el rechazo se manda a una sola ventana, no a todas", async () => {
    // Con el listener montado en tres ventanas, un broadcast dibujaría el
    // mismo toast en cada una que esté a la vista.
    const source = await Bun.file("src-tauri/src/actions.rs").text();

    expect(source).toMatch(/emit_ui_notice\(\s*app,\s*"recording-error"/);
    expect(source).not.toMatch(/app\.emit\(\s*"recording-error"/);
  });

  test("el rechazo por reunión en curso no culpa al micrófono", async () => {
    const rust = await Bun.file("src-tauri/src/managers/audio.rs").text();
    const hook = await Bun.file("src/hooks/useRecordingErrorToast.ts").text();
    const en = await Bun.file("src/i18n/locales/en/translation.json").json();
    const es = await Bun.file("src/i18n/locales/es/translation.json").json();

    // El backend clasifica el caso en vez de mandar un string crudo…
    expect(rust).toContain(
      'pub const MEETING_RECORDING_ACTIVE: &str = "meeting_recording_active"',
    );
    expect(hook).toContain('error_type === "meeting_recording_active"');
    // …y la copia dice qué pasa y qué hacer, sin hablar de micrófonos.
    expect(en.errors.meetingRecordingActive).not.toContain("microphone");
    expect(es.errors.meetingRecordingActive).not.toContain("micrófono");
    expect(es.errors.meetingRecordingActive).toContain("Detén la reunión");
  });
});

describe("appendMeetingPage", () => {
  test("no repite una reunión que ya estaba en la lista", () => {
    // El caso real: se grabó una reunión nueva entre la primera página y el
    // 'cargar más', así que el offset posicional devuelve corrida la última
    // fila que ya se mostraba.
    const shown = [summary(10), summary(9), summary(8)];
    const nextPage = [summary(8), summary(7), summary(6)];

    expect(appendMeetingPage(shown, nextPage).map((m) => m.id)).toEqual([
      10, 9, 8, 7, 6,
    ]);
  });

  test("una página sin repetidos se anexa entera y en orden", () => {
    expect(
      appendMeetingPage([summary(3)], [summary(2), summary(1)]).map(
        (m) => m.id,
      ),
    ).toEqual([3, 2, 1]);
  });
});

describe("groupConsecutiveSegments", () => {
  // El backend corta un turno cada MAX_TURN_MS (8s) aunque el mismo
  // hablante siga con la palabra — ver el doc comment de la función. Estos
  // casos son los bordes de la regla "sólo se unen dos hablantes conocidos
  // e iguales".
  const withSpeaker = (id: number, speakerId: number): MeetingSegment => ({
    ...segment(id),
    speaker_id: speakerId,
  });

  test("dos seguidos del mismo hablante se unen, con la marca del primero", () => {
    const result = groupConsecutiveSegments([
      withSpeaker(1, 10),
      withSpeaker(2, 10),
    ]);

    expect(result).toHaveLength(1);
    expect(result[0].started_at_ms).toBe(1000);
    expect(result[0].ended_at_ms).toBe(2500);
    expect(result[0].text).toBe("turno 1 turno 2");
  });

  test("dos seguidos de hablantes distintos NO se unen", () => {
    const result = groupConsecutiveSegments([
      withSpeaker(1, 10),
      withSpeaker(2, 20),
    ]);

    expect(result.map((s) => s.id)).toEqual([1, 2]);
  });

  test("dos seguidos sin hablante NO se unen: son dos dudas independientes", () => {
    const result = groupConsecutiveSegments([segment(1), segment(2)]);

    expect(result.map((s) => s.id)).toEqual([1, 2]);
  });

  test("un hablante conocido seguido de uno sin identificar NO se une", () => {
    const result = groupConsecutiveSegments([withSpeaker(1, 10), segment(2)]);

    expect(result.map((s) => s.id)).toEqual([1, 2]);
  });

  test("uno sin identificar seguido de un hablante conocido tampoco se une", () => {
    const result = groupConsecutiveSegments([segment(1), withSpeaker(2, 10)]);

    expect(result.map((s) => s.id)).toEqual([1, 2]);
  });

  test("tres o más seguidos del mismo hablante quedan en un solo bloque", () => {
    const result = groupConsecutiveSegments([
      withSpeaker(1, 10),
      withSpeaker(2, 10),
      withSpeaker(3, 10),
      withSpeaker(4, 10),
    ]);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe(1);
    expect(result[0].started_at_ms).toBe(1000);
    expect(result[0].ended_at_ms).toBe(4500);
    expect(result[0].text).toBe("turno 1 turno 2 turno 3 turno 4");
  });

  test("lista vacía da lista vacía, sin reventar", () => {
    expect(groupConsecutiveSegments([])).toEqual([]);
  });

  test("un cambio de hablante en el medio corta el bloque en dos", () => {
    const result = groupConsecutiveSegments([
      withSpeaker(1, 10),
      withSpeaker(2, 10),
      withSpeaker(3, 20),
      withSpeaker(4, 20),
    ]);

    expect(result.map((s) => s.id)).toEqual([1, 3]);
  });

  test("overlapped viaja con OR: no se pierde si sólo un trozo lo tenía", () => {
    const result = groupConsecutiveSegments([
      { ...withSpeaker(1, 10), overlapped: false },
      { ...withSpeaker(2, 10), overlapped: true },
    ]);

    expect(result).toHaveLength(1);
    expect(result[0].overlapped).toBe(true);
  });
});

describe("exceedsSpeakerCap", () => {
  test("cuatro hablantes distintos todavía no supera el tope", () => {
    expect(exceedsSpeakerCap([1, 2, 3, 4])).toBe(false);
  });

  test("cinco lo superan", () => {
    expect(exceedsSpeakerCap([1, 2, 3, 4, 5])).toBe(true);
  });

  test("los repetidos no cuentan doble", () => {
    expect(exceedsSpeakerCap([1, 1, 1, 2])).toBe(false);
  });

  test("sin hablantes no supera nada", () => {
    expect(exceedsSpeakerCap([])).toBe(false);
  });

  test("el tope es el del modelo", () => {
    expect(SORTFORMER_MAX_SPEAKERS).toBe(4);
  });
});

describe("isPastMeeting", () => {
  test("deja pasar las terminadas", () => {
    expect(isPastMeeting({ ...summary(1), status: "ready" })).toBe(true);
  });

  test("deja pasar las interrumpidas: son legibles aunque incompletas", () => {
    expect(isPastMeeting({ ...summary(1), status: "interrupted" })).toBe(true);
  });

  test("saca la que está grabando ahora", () => {
    expect(isPastMeeting({ ...summary(1), status: "recording" })).toBe(false);
  });

  test("pedir una fila de más deja 4 pasadas aunque una esté grabando", () => {
    const rows = [
      { ...summary(5), status: "recording" },
      summary(4),
      summary(3),
      summary(2),
      summary(1),
    ];
    expect(
      rows.filter(isPastMeeting).slice(0, RECENT_MEETINGS_LIMIT),
    ).toHaveLength(4);
  });
});
