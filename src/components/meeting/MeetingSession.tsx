import React from "react";
import { useTranslation } from "react-i18next";
import { PageHeader } from "../ui/PageHeader";
import { useMeetingEvents } from "../../hooks/useMeetings";
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
 */
export const MeetingSession: React.FC = () => {
  const { t } = useTranslation();
  // Un solo punto de suscripción para toda la pantalla — ver el doc comment
  // de `useMeetingEvents`.
  useMeetingEvents();

  return (
    <div className="w-full mx-auto space-y-6">
      <PageHeader
        title={t("meeting.page.title")}
        description={t("meeting.page.description")}
      />
      <RecordingControls />
      <LiveTranscript />
      <SpeakerAssignment />
    </div>
  );
};
