import { useEffect } from "react";
import { useMeetingStore } from "../stores/meetingStore";
import type {
  Meeting,
  MeetingKind,
  MeetingSummary,
} from "../stores/meetingStore";

interface UseMeetingsReturn {
  // State
  meetings: MeetingSummary[];
  activeMeeting: Meeting | null;
  isLoading: boolean;

  // Actions
  refreshMeetings: () => Promise<void>;
  setActiveMeeting: (meeting: Meeting | null) => void;
  startMeeting: (kind: MeetingKind) => Promise<void>;
  stopMeeting: (meetingId: number) => Promise<void>;
}

// Skeleton hook for the meeting notetaker feature, following the shape of
// `useSettings.ts`. There is no real data behind it yet — `meetingStore`'s
// actions are no-ops until the backend commands from T011+ exist. Real UI
// (Phase 3, Historia 1, T017+) can depend on this API without changing its
// shape once the store is wired up to actual Tauri commands.
export const useMeetings = (): UseMeetingsReturn => {
  const store = useMeetingStore();

  // Initialize on first mount
  useEffect(() => {
    store.refreshMeetings();
  }, [store.refreshMeetings]);

  return {
    meetings: store.meetings,
    activeMeeting: store.activeMeeting,
    isLoading: store.isLoading,
    refreshMeetings: store.refreshMeetings,
    setActiveMeeting: store.setActiveMeeting,
    startMeeting: store.startMeeting,
    stopMeeting: store.stopMeeting,
  };
};
