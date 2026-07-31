import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { PageHeader } from "../ui/PageHeader";
import { useMeetingEvents } from "../../hooks/useMeetings";
import { RecordingControls } from "./RecordingControls";
import { LiveTranscript } from "./LiveTranscript";
import { SpeakerAssignment } from "./SpeakerAssignment";
import { MeetingsList } from "./MeetingsList";
import { MeetingDetail } from "./MeetingDetail";

/**
 * Sección "Reuniones": el registro completo — grabar una nueva arriba, leer
 * las pasadas abajo (Historia 4). Antes de esto la app grababa y guardaba en
 * SQLite pero ninguna pantalla lo leía; ésta es la casa que le faltaba.
 *
 * `selectedMeetingId` decide qué se ve debajo de los controles: la lista, o
 * el detalle de la que se eligió. La reunión en curso no aparece ahí — ya la
 * muestran los controles de arriba (decisión de producto).
 */
export const MeetingSession: React.FC = () => {
  const { t } = useTranslation();
  // Un solo punto de suscripción para toda la pantalla — ver el doc comment
  // de `useMeetingEvents`.
  useMeetingEvents();
  const [selectedMeetingId, setSelectedMeetingId] = useState<number | null>(
    null,
  );

  return (
    <div className="w-full mx-auto space-y-6">
      <PageHeader
        title={t("meeting.page.title")}
        description={t("meeting.page.description")}
      />
      <RecordingControls />
      <LiveTranscript />
      <SpeakerAssignment />
      {selectedMeetingId === null ? (
        <MeetingsList onSelect={setSelectedMeetingId} />
      ) : (
        <MeetingDetail
          meetingId={selectedMeetingId}
          onBack={() => setSelectedMeetingId(null)}
        />
      )}
    </div>
  );
};
