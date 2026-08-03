// Meeting notetaker components (Historia 1, T017-T019; registro Historia 4).
// `MeetingSession` sólo se monta en la ventana de reuniones (src/meetings/):
// grabar, transcript en vivo, nombrar hablantes. `MeetingsLauncher` es la
// sección "Reuniones" del panel principal — el registro (`MeetingsList` /
// `MeetingDetail`) y el botón para abrir la ventana de sesión.
export { MeetingSession } from "./MeetingSession";
export { MeetingsLauncher } from "./MeetingsLauncher";
export { RecordingControls } from "./RecordingControls";
export { LiveTranscript } from "./LiveTranscript";
export { SpeakerAssignment } from "./SpeakerAssignment";
export { MeetingsList } from "./MeetingsList";
export { MeetingDetail } from "./MeetingDetail";
export { TranscriptList } from "./TranscriptList";
