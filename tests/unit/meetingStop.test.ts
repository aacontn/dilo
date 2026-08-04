import { beforeEach, describe, expect, mock, test } from "bun:test";
import type { MeetingSummary } from "@/bindings";

/**
 * Detener una reunión desde la ventana de Reuniones.
 *
 * Regresión del reporte del dueño (2026-08-04): con la reunión empezada en
 * el popover, el store de ESTA ventana no tenía `activeMeetingId` —los
 * stores de Zustand son por ventana— y `stopMeeting` hacía `return` sin
 * llamar a nadie, sin error y sin log. El botón de detener no producía
 * ningún efecto ni ninguna señal.
 *
 * El store se importa dinámicamente DESPUÉS de mockear `@/bindings`: los
 * `import` estáticos se elevan, así que un import normal tomaría los
 * comandos reales (que intentarían hablar por IPC con Tauri).
 */
const recording = (id: number): MeetingSummary => ({
  id,
  title: `Reunión ${id}`,
  kind: "presencial",
  started_at: 1_000,
  ended_at: null,
  status: "recording",
});

// Lo que el backend responde en cada test: la fila más nueva de
// `list_meetings(1, 0)`, o ninguna.
let topMeeting: MeetingSummary | null = null;

const listMeetings = mock(async () => ({
  status: "ok" as const,
  data: { meetings: topMeeting === null ? [] : [topMeeting], total: 0 },
}));

const stopMeetingCommand = mock(async (_meetingId: number) => ({
  status: "ok" as const,
  data: null,
}));

mock.module("@/bindings", () => ({
  commands: { listMeetings, stopMeeting: stopMeetingCommand },
  events: {},
}));

const { useMeetingStore } = await import("@/stores/meetingStore");
const { resolveActiveMeeting } = await import("@/lib/activeMeeting");

describe("meetingStore.stopMeeting", () => {
  beforeEach(() => {
    topMeeting = null;
    listMeetings.mockClear();
    stopMeetingCommand.mockClear();
    useMeetingStore.setState({
      activeMeetingId: null,
      status: null,
      segments: [],
      pendingSegments: [],
      speakerNames: {},
      isStarting: false,
      isStopping: false,
    });
  });

  test("sin id local, adopta la reunión que el backend dice que está grabando y la detiene", async () => {
    // La ventana muestra "grabando" (adoptada, o quedó así) pero perdió el
    // id: la reunión la empezó otra ventana. Antes esto era un `return` mudo.
    topMeeting = recording(20);
    useMeetingStore.setState({ activeMeetingId: null, status: "recording" });

    await useMeetingStore.getState().stopMeeting();

    expect(stopMeetingCommand).toHaveBeenCalledTimes(1);
    expect(stopMeetingCommand.mock.calls[0][0]).toBe(20);
    const state = useMeetingStore.getState();
    expect(state.activeMeetingId).toBe(20);
    expect(state.status).toBe("processing");
    expect(state.isStopping).toBe(false);
  });

  test("sin ninguna reunión viva avisa en vez de irse en silencio", async () => {
    topMeeting = null;
    useMeetingStore.setState({ activeMeetingId: null, status: "recording" });

    await expect(useMeetingStore.getState().stopMeeting()).rejects.toThrow(
      "meeting_no_active_session",
    );

    expect(stopMeetingCommand).not.toHaveBeenCalled();
    const state = useMeetingStore.getState();
    // Y la pantalla deja de decir "grabando": no hay nada que detener.
    expect(state.status).toBe(null);
    expect(state.isStopping).toBe(false);
  });

  test("con id local detiene ése y no le pregunta nada al backend", async () => {
    topMeeting = recording(99);
    useMeetingStore.setState({ activeMeetingId: 7, status: "recording" });

    await useMeetingStore.getState().stopMeeting();

    expect(listMeetings).not.toHaveBeenCalled();
    expect(stopMeetingCommand.mock.calls[0][0]).toBe(7);
    expect(useMeetingStore.getState().status).toBe("processing");
  });

  test("adopta también cuando esta ventana se creía en reposo", async () => {
    // La otra mitad del mismo agujero: la ventana quedó en `idle` (nunca se
    // enteró de la reunión), así que ni siquiera muestra el botón correcto.
    // Si igual llega una orden de detener, tiene que detener la que hay.
    topMeeting = recording(31);
    useMeetingStore.setState({ activeMeetingId: null, status: null });

    await useMeetingStore.getState().stopMeeting();

    expect(stopMeetingCommand.mock.calls[0][0]).toBe(31);
  });

  test("no se pisa a sí mismo: una segunda llamada mientras detiene no hace nada", async () => {
    useMeetingStore.setState({
      activeMeetingId: 7,
      status: "recording",
      isStopping: true,
    });

    await useMeetingStore.getState().stopMeeting();

    expect(stopMeetingCommand).not.toHaveBeenCalled();
  });
});

/**
 * La resolución que usan las dos ventanas para saber qué está grabando —la
 * mitad de "la ventana no adoptó la reunión en curso" que se puede probar
 * sin una ventana real (la otra mitad, cuándo se vuelve a preguntar, está
 * cableada a eventos de ventana y se cubre en `meetingSession.test.ts`).
 */
describe("resolveActiveMeeting", () => {
  beforeEach(() => {
    topMeeting = null;
    listMeetings.mockClear();
  });

  test("la fila más nueva en `recording` es la reunión activa", async () => {
    topMeeting = recording(20);

    expect((await resolveActiveMeeting())?.id).toBe(20);
  });

  test("una fila terminada no es una reunión activa", async () => {
    topMeeting = { ...recording(20), status: "ready" };

    expect(await resolveActiveMeeting()).toBe(null);
  });

  test("sin ninguna reunión en el registro tampoco hay activa", async () => {
    topMeeting = null;

    expect(await resolveActiveMeeting()).toBe(null);
  });

  test("pide una sola fila: si algo graba, es siempre la más nueva", async () => {
    await resolveActiveMeeting();

    expect(listMeetings.mock.calls[0]).toEqual([1, 0]);
  });
});
