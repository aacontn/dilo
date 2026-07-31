import React, { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { Users } from "lucide-react";
import { toast } from "sonner";
import { commands } from "@/bindings";
import { Button } from "../ui/Button";
import { PageHeader } from "../ui/PageHeader";

/**
 * Lo que queda de la sección "Reuniones" en el panel principal, ahora que
 * grabar y leer transcripts vive en su propia ventana (diseño
 * 2026-07-31-notetaker-usable-design.md §1). Este panel ya no es la
 * actividad: es el lanzador. Abre la ventana solo al entrar a la sección, y
 * deja un botón por si el usuario la cerró o quedó detrás de otra ventana.
 */
export const MeetingsLauncher: React.FC = () => {
  const { t } = useTranslation();

  const openWindow = async () => {
    const result = await commands.openMeetingsWindow();
    if (result.status === "error") {
      toast.error(t("meeting.launcher.openFailed"), {
        description: result.error,
      });
    }
  };

  // Solo al entrar a la sección, no en cada render.
  useEffect(() => {
    void openWindow();
  }, []);

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
    </div>
  );
};
