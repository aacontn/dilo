import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { Users } from "lucide-react";
import { toast } from "sonner";
import { commands } from "@/bindings";
import { Button } from "../ui/Button";
import { PageHeader } from "../ui/PageHeader";
import { MeetingsList } from "./MeetingsList";
import { MeetingDetail } from "./MeetingDetail";

/**
 * Sección "Reuniones" del panel principal: el registro completo (reporte del
 * dueño, 2026-08-02). Grabar y ver el transcript en vivo vive en su propia
 * ventana (`MeetingSession`, montada en `src/meetings/`); acá vive todo lo
 * demás — abrir esa ventana, y leer las reuniones ya grabadas.
 *
 * A diferencia de la versión anterior, esta sección **no** abre la ventana
 * sola al entrar: eso apilaba tres pantallas (lanzador + sesión + detalle)
 * en el mismo lugar y competía con este registro. Abrir la ventana es ahora
 * una acción explícita del botón, igual que cualquier otro control.
 */
export const MeetingsLauncher: React.FC = () => {
  const { t } = useTranslation();
  const [selectedMeetingId, setSelectedMeetingId] = useState<number | null>(
    null,
  );

  const openWindow = async () => {
    const result = await commands.openMeetingsWindow();
    if (result.status === "error") {
      toast.error(t("meeting.launcher.openFailed"), {
        description: result.error,
      });
    }
  };

  return (
    <div className="w-full mx-auto space-y-6">
      <PageHeader
        title={t("meeting.launcher.title")}
        description={t("meeting.launcher.description")}
      />
      <section className="glass-surface flex flex-col items-center gap-4 rounded-xl p-8 text-center">
        <Users className="size-8 text-muted-text" />
        <p className="max-w-sm text-sm text-muted-text">
          {t("meeting.launcher.hint")}
        </p>
        <Button variant="primary" onClick={() => void openWindow()}>
          {t("meeting.launcher.openButton")}
        </Button>
      </section>
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
