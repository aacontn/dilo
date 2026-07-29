import React from "react";
import { useTranslation } from "react-i18next";
import { PageHeader } from "../ui/PageHeader";
import { useMeetingEvents } from "../../hooks/useMeetings";
import { RecordingControls } from "./RecordingControls";
import { LiveTranscript } from "./LiveTranscript";
import { SpeakerAssignment } from "./SpeakerAssignment";

/**
 * Sección "Reuniones": la superficie desde la que se graba una reunión y se
 * la sigue en vivo.
 *
 * Es la casa mínima de los componentes de la Historia 1 — sin esto, T017-T019
 * existirían sin forma de llegar a ellos y el Escenario 1 de `quickstart.md`
 * no se podría probar a mano. Cuando llegue T039 (`MeetingsHub`, Historia 4),
 * esta pantalla pasa a ser la vista de "reunión en curso" dentro del hub, con
 * el listado de reuniones pasadas arriba.
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
