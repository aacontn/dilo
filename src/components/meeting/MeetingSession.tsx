import React from "react";
import {
  useMeetingActiveSync,
  useMeetingEvents,
} from "../../hooks/useMeetings";
import { RecordingControls } from "./RecordingControls";
import { LiveTranscript } from "./LiveTranscript";
import { SpeakerAssignment } from "./SpeakerAssignment";

/**
 * Ventana de reuniones: sólo la sesión — grabar, el transcript en vivo y
 * nombrar hablantes. El registro de reuniones pasadas (`MeetingsList` /
 * `MeetingDetail`) vive en `MeetingsLauncher`, la sección "Reuniones" del
 * panel principal, no acá — apilar lanzador + sesión en vivo + detalle de
 * una reunión pasada en la misma ventana era el error de diseño que esto
 * corrige (reporte del dueño, 2026-08-02).
 *
 * Sin encabezado de título/descripción: repetía lo que `RecordingControls`
 * ya muestra debajo y, además, la copia decía "presencial" cuando la
 * ventana también graba reuniones online por audio del computador (reporte
 * del dueño, 2026-08-03). Esa misma copia no se usaba en ningún otro lado
 * (`meeting.launcher.description`, en el panel principal, es un texto
 * distinto), así que se retiró también de los 22 locales (`meeting.page`).
 */
export const MeetingSession: React.FC = () => {
  // Un solo punto de suscripción para toda la pantalla — ver el doc comment
  // de `useMeetingEvents`.
  useMeetingEvents();
  // Igual criterio: un solo punto que adopta contra el backend una reunión
  // que ya está grabando y que esta ventana todavía no sabe que existe (ver
  // el doc comment de `useMeetingActiveSync`) — antes esta ventana sólo
  // confiaba en su propio store, y por eso podía "correr en paralelo" con
  // el popover mostrando cosas distintas (reporte del dueño, 2026-08-04).
  useMeetingActiveSync();

  return (
    <div className="w-full mx-auto space-y-6">
      <RecordingControls />
      <LiveTranscript />
      <SpeakerAssignment />
    </div>
  );
};
