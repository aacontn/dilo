import { create } from "zustand";

// Placeholder types for the meeting notetaker feature.
//
// These mirror the "Tipos compartidos" section of
// `specs/001-meeting-notetaker/contracts/tauri-commands.md` (not exhaustive
// there either). There are no real `meetings` commands in `bindings.ts` yet
// (the first one, `start_meeting`, lands in T011) — once tauri-specta
// generates them, these local types should be dropped in favor of the
// generated ones, the same way `useSettings`/`settingsStore` consume
// `AppSettings` from `@/bindings`.
export type MeetingStatus = "recording" | "processing" | "ready" | "interrupted";
export type MeetingKind = "presencial" | "virtual";

export interface MeetingSummary {
  id: number;
  title: string;
  kind: MeetingKind;
  startedAt: number;
  endedAt: number | null;
  status: MeetingStatus;
}

export interface MeetingSpeaker {
  id: number;
  label: string;
  displayName: string | null;
}

export interface MeetingSegment {
  id: number;
  speakerId: number | null;
  text: string;
  startedAtMs: number;
  endedAtMs: number;
  overlapped: boolean;
}

export interface ActionItem {
  id: number;
  text: string;
  done: boolean;
}

export interface Meeting extends MeetingSummary {
  summary: string | null;
  notes: string | null;
  segments: MeetingSegment[];
  speakers: MeetingSpeaker[];
  actionItems: ActionItem[];
}

interface MeetingStore {
  meetings: MeetingSummary[];
  activeMeeting: Meeting | null;
  isLoading: boolean;

  // Actions
  //
  // Skeleton only — no Tauri commands exist for meetings yet (T011+ adds
  // `start_meeting`, `stop_meeting`, `list_meetings`, etc., see
  // `specs/001-meeting-notetaker/contracts/tauri-commands.md`). These are
  // no-ops so real UI work in Phase 3 has a stable store API to build
  // against without inventing calls to commands that don't exist.
  refreshMeetings: () => Promise<void>;
  setActiveMeeting: (meeting: Meeting | null) => void;
  startMeeting: (kind: MeetingKind) => Promise<void>;
  stopMeeting: (meetingId: number) => Promise<void>;

  // Internal state setters
  setMeetings: (meetings: MeetingSummary[]) => void;
  setLoading: (loading: boolean) => void;
}

export const useMeetingStore = create<MeetingStore>()((set) => ({
  meetings: [],
  activeMeeting: null,
  isLoading: false,

  setMeetings: (meetings) => set({ meetings }),
  setLoading: (isLoading) => set({ isLoading }),

  refreshMeetings: async () => {
    // TODO(T011+): call commands.listMeetings() once it exists and normalize
    // the result into `meetings`, following the pattern of
    // `refreshSettings` in settingsStore.ts.
  },

  setActiveMeeting: (meeting) => set({ activeMeeting: meeting }),

  startMeeting: async (_kind) => {
    // TODO(T011+): call commands.startMeeting({ kind }) once it exists.
  },

  stopMeeting: async (_meetingId) => {
    // TODO(T011+): call commands.stopMeeting({ meetingId }) once it exists.
  },
}));
