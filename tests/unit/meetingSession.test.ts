import { beforeEach, describe, expect, test } from "bun:test";
import type { MeetingSegment, MeetingSummary } from "@/bindings";
import { useMeetingStore } from "@/stores/meetingStore";
import { appendMeetingPage } from "@/components/meeting/meetingFormat";

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
