//! Manages the lifecycle of a meeting notetaker session: recording, live
//! transcription, and speaker diarization. T005 added the SQLite schema
//! (migrations), and T006 added `get_connection()` so later tasks can open
//! per-operation connections against the migrated database, mirroring
//! `HistoryManager`'s pattern. T011 added the first real business logic,
//! `start_meeting()` — it only creates the `meetings` row; wiring real audio
//! capture is a later task (T012).

use anyhow::{bail, Result};
use chrono::{Local, Utc};
use log::{debug, info};
use rusqlite::{params, Connection, TransactionBehavior};
use rusqlite_migration::{Migrations, M};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::path::PathBuf;

/// Database migrations for the meeting notetaker feature.
/// Each migration is applied in order. The library tracks which migrations
/// have been applied using SQLite's user_version pragma (same mechanism as
/// `managers/history.rs`).
///
/// All six tables are created in a single initial migration (rather than one
/// table per migration) so that the foreign-key dependency order between
/// them — `sync_destinations` -> `meetings` -> `meeting_speakers` ->
/// `meeting_segments`, and `meetings` -> `meeting_action_items` /
/// `meeting_notes` — is guaranteed within one `execute_batch` call. Schema
/// verbatim from `specs/001-meeting-notetaker/data-model.md`.
static MIGRATIONS: &[M] = &[M::up(
    "CREATE TABLE IF NOT EXISTS sync_destinations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        config TEXT NOT NULL,
        enabled BOOLEAN NOT NULL DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS meetings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        kind TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        status TEXT NOT NULL,
        summary TEXT,
        summary_prompt TEXT,
        sync_destination_id INTEGER,
        synced_at INTEGER,
        FOREIGN KEY (sync_destination_id) REFERENCES sync_destinations(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_speakers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id INTEGER NOT NULL,
        label TEXT NOT NULL,
        display_name TEXT,
        merged_into_id INTEGER,
        FOREIGN KEY (meeting_id) REFERENCES meetings(id),
        FOREIGN KEY (merged_into_id) REFERENCES meeting_speakers(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_segments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id INTEGER NOT NULL,
        speaker_id INTEGER,
        text TEXT NOT NULL,
        started_at_ms INTEGER NOT NULL,
        ended_at_ms INTEGER NOT NULL,
        overlapped BOOLEAN NOT NULL DEFAULT 0,
        FOREIGN KEY (meeting_id) REFERENCES meetings(id),
        FOREIGN KEY (speaker_id) REFERENCES meeting_speakers(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_action_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id INTEGER NOT NULL,
        text TEXT NOT NULL,
        done BOOLEAN NOT NULL DEFAULT 0,
        order_index INTEGER NOT NULL,
        FOREIGN KEY (meeting_id) REFERENCES meetings(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id INTEGER NOT NULL UNIQUE,
        content TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (meeting_id) REFERENCES meetings(id)
    );",
)];

/// Table names created by `MIGRATIONS`, in dependency order. Used by tests
/// to verify the schema was applied.
#[cfg(test)]
const MEETING_TABLES: &[&str] = &[
    "sync_destinations",
    "meetings",
    "meeting_speakers",
    "meeting_segments",
    "meeting_action_items",
    "meeting_notes",
];

// --- Tauri events (T010) -----------------------------------------------
//
// Type definitions only — nothing here emits an event yet. Emission starts
// in Phase 3 (T014+) once the commands that drive a meeting's lifecycle are
// implemented.
//
// A note on event names: `tauri_specta::Event`'s derive macro (pinned at
// tauri-specta-macros 2.0.0-rc.16 via tauri-specta =2.0.0-rc.21, see
// Cargo.lock) hardcodes the wire event name to `heck::ToKebabCase` of the
// Rust struct/enum identifier. It declares `attributes(tauri_specta)` but
// does not read any value from it in this version — there is no way to
// override the event name with an attribute, only by naming the type
// itself. That's also how the existing events in this codebase resolve
// their names: `HistoryUpdatePayload` -> `history-update-payload`,
// `StreamTextEvent` -> `stream-text-event` (see `src/bindings.ts`), not the
// shorter names their doc comments might suggest.
//
// Because of this, the 7 event structs below are named to match
// `specs/001-meeting-notetaker/contracts/tauri-commands.md`'s required
// wire names exactly (`MeetingSegment` -> `meeting-segment`, etc.) — they
// do NOT carry an `...Event` suffix the way a first read of the task brief
// might suggest, since e.g. `MeetingSegmentEvent` would kebab-case to
// `meeting-segment-event`, not `meeting-segment`.
//
// This also means `MeetingSegment` below is the flat, full segment shape
// from `data-model.md` / `contracts/tauri-commands.md`'s `MeetingSegment`
// TS interface (no `meeting_id` field — the doc's own wording is "Payload:
// `MeetingSegment` completo"), not a `{ meeting_id, segment }` wrapper.
// Keeping it flat also avoids defining a second, differently-shaped
// `MeetingSegment` type that Phase 3 would collide with when it needs this
// exact DTO for `Meeting.segments`. Reuse this type there instead of
// duplicating it.

/// Emitted whenever a new transcript segment is ready (incremental, during
/// recording).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingSegment {
    pub id: i64,
    pub speaker_id: Option<i64>,
    pub text: String,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub overlapped: bool,
}

/// Phase of post-recording processing (summary generation, diarization when
/// it runs as a separate step, etc.), reported via [`MeetingProgress`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "lowercase")]
pub enum MeetingProgressPhase {
    Transcribing,
    Diarizing,
    Summarizing,
}

/// Emitted while a finished recording is being processed (summary,
/// diarization if it runs as a separate step, etc.).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingProgress {
    pub meeting_id: i64,
    pub phase: MeetingProgressPhase,
}

/// The meeting finished processing (`status` -> `ready`).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingFinished {
    pub meeting_id: i64,
}

/// Error during recording or post-processing.
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingError {
    pub meeting_id: i64,
    pub error: String,
}

/// Detected at app startup: a meeting without `ended_at` left over from a
/// previous session (crash recovery, FR-008).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingInterrupted {
    pub meeting_id: i64,
}

/// An active video call was detected with no recording in progress
/// (User Story 3, FR-017). `call_source` is the detected app name when it
/// could be determined.
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingCallDetected {
    pub call_source: Option<String>,
}

/// The video call that triggered an auto-detected recording has ended
/// (User Story 3, FR-018).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct MeetingCallEnded {
    pub meeting_id: i64,
}

pub struct MeetingManager {
    db_path: PathBuf,
}

impl MeetingManager {
    /// Open (or create) the meeting database at `db_path` and apply any
    /// pending migrations. Mirrors `HistoryManager::new` /
    /// `HistoryManager::init_database`, minus the tauri-plugin-sql legacy
    /// migration path (there is no pre-existing meeting data to carry over).
    pub fn new(db_path: PathBuf) -> Result<Self> {
        let manager = Self { db_path };
        manager.init_database()?;
        Ok(manager)
    }

    fn init_database(&self) -> Result<()> {
        info!("Initializing meeting database at {:?}", self.db_path);

        let mut conn = Connection::open(&self.db_path)?;

        let migrations = Migrations::new(MIGRATIONS.to_vec());

        #[cfg(debug_assertions)]
        migrations.validate().expect("Invalid meeting migrations");

        let version_before: i32 =
            conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        debug!(
            "Meeting database version before migration: {}",
            version_before
        );

        migrations.to_latest(&mut conn)?;

        let version_after: i32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;

        if version_after > version_before {
            info!(
                "Meeting database migrated from version {} to {}",
                version_before, version_after
            );
        } else {
            debug!(
                "Meeting database already at latest version {}",
                version_after
            );
        }

        Ok(())
    }

    /// Open a new connection to the meeting database. Mirrors
    /// `HistoryManager::get_connection`: the manager does not keep a
    /// persistent connection in the struct, so each operation opens its own
    /// short-lived connection against `db_path`.
    fn get_connection(&self) -> Result<Connection> {
        Ok(Connection::open(&self.db_path)?)
    }

    /// Start a new meeting: inserts a `meetings` row with `status =
    /// "recording"` and returns its `id`. This is the only business logic
    /// behind the `start_meeting` Tauri command (T011) — it does not touch
    /// the microphone or any recording pipeline, that's T012's job.
    ///
    /// Fails with `"recording_busy"` if another meeting already has
    /// `status = 'recording'` (contract: `specs/001-meeting-notetaker/
    /// contracts/tauri-commands.md#start_meeting`). The check-then-insert
    /// runs inside a single `IMMEDIATE` transaction so two overlapping
    /// calls can't both observe "no meeting recording" and both insert.
    ///
    /// `title` defaults to a timestamp derived from the current local time
    /// (e.g. "Reunión 28/07 10:30"); the user can rename it later via the
    /// future `rename_meeting` command.
    pub fn start_meeting(&self, kind: &str) -> Result<i64> {
        let mut conn = self.get_connection()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;

        let already_recording: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM meetings WHERE status = 'recording')",
            [],
            |row| row.get(0),
        )?;
        if already_recording {
            bail!("recording_busy");
        }

        let started_at = Utc::now().timestamp();
        let title = format!("Reunión {}", Local::now().format("%d/%m %H:%M"));

        tx.execute(
            "INSERT INTO meetings (title, kind, started_at, status) VALUES (?1, ?2, ?3, 'recording')",
            params![title, kind, started_at],
        )?;
        let id = tx.last_insert_rowid();
        tx.commit()?;

        info!("Started meeting {} (kind={})", id, kind);
        Ok(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Unique temp db path for a test (mirrors the inline pattern the
    /// existing T007 tests below already use, factored out so the new
    /// `start_meeting` tests don't duplicate it a third/fourth time).
    fn temp_db_path(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "dilo-meeting-test-{}-{}-{}.db",
            label,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn apply_migrations(conn: &mut Connection) {
        let migrations = Migrations::new(MIGRATIONS.to_vec());
        migrations.validate().expect("migrations should be valid");
        migrations
            .to_latest(conn)
            .expect("migrations should apply cleanly");
    }

    fn table_exists(conn: &Connection, table: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |row| row.get::<_, i64>(0),
        )
        .expect("query sqlite_master")
            == 1
    }

    #[test]
    fn migrations_apply_cleanly_on_in_memory_db() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        apply_migrations(&mut conn);
    }

    #[test]
    fn migrations_create_all_meeting_tables() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        apply_migrations(&mut conn);

        for table in MEETING_TABLES {
            assert!(
                table_exists(&conn, table),
                "expected table {} to exist",
                table
            );
        }
    }

    #[test]
    fn migrations_are_idempotent_when_applied_twice() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        apply_migrations(&mut conn);
        // Applying to_latest again on an already-migrated connection should
        // be a no-op, not an error (mirrors real app restarts).
        let migrations = Migrations::new(MIGRATIONS.to_vec());
        migrations
            .to_latest(&mut conn)
            .expect("re-applying migrations should be a no-op");
    }

    #[test]
    fn empty_select_against_each_table_succeeds() {
        let mut conn = Connection::open_in_memory().expect("open in-memory db");
        apply_migrations(&mut conn);

        for table in MEETING_TABLES {
            let mut stmt = conn
                .prepare(&format!("SELECT * FROM {}", table))
                .unwrap_or_else(|e| panic!("failed to prepare SELECT against {}: {}", table, e));
            let _rows = stmt
                .query([])
                .unwrap_or_else(|e| panic!("SELECT against {} failed: {}", table, e));
        }
    }

    #[test]
    fn meeting_manager_new_applies_migrations_to_file_db() {
        let dir = std::env::temp_dir().join(format!(
            "dilo-meeting-test-{}-{}.db",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));

        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");

        let conn = Connection::open(&dir).expect("open the db file MeetingManager created");
        for table in MEETING_TABLES {
            assert!(
                table_exists(&conn, table),
                "expected table {} to exist",
                table
            );
        }

        drop(manager);
        drop(conn);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn get_connection_returns_a_valid_connection_against_migrated_db() {
        let dir = std::env::temp_dir().join(format!(
            "dilo-meeting-test-get-connection-{}-{}.db",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));

        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");

        let conn = manager
            .get_connection()
            .expect("get_connection should open a connection");
        for table in MEETING_TABLES {
            assert!(
                table_exists(&conn, table),
                "expected table {} to be visible via get_connection",
                table
            );
        }

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn start_meeting_inserts_a_recording_row_with_expected_fields() {
        let dir = temp_db_path("start-meeting-basic");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");

        let before = Utc::now().timestamp();
        let id = manager
            .start_meeting("presencial")
            .expect("start_meeting should succeed");
        let after = Utc::now().timestamp();

        let conn = manager.get_connection().expect("get_connection");
        let (title, kind, started_at, ended_at, status): (
            String,
            String,
            i64,
            Option<i64>,
            String,
        ) = conn
            .query_row(
                "SELECT title, kind, started_at, ended_at, status FROM meetings WHERE id = ?1",
                [id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .expect("the inserted row should be readable back");

        assert_eq!(kind, "presencial");
        assert_eq!(status, "recording");
        assert!(
            ended_at.is_none(),
            "ended_at must be NULL while status = recording"
        );
        assert!(
            (before..=after).contains(&started_at),
            "started_at ({started_at}) should fall within [{before}, {after}]"
        );
        assert!(
            title.starts_with("Reunión "),
            "unexpected default title: {title:?}"
        );

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn start_meeting_fails_when_a_meeting_is_already_recording() {
        let dir = temp_db_path("start-meeting-conflict");
        let manager = MeetingManager::new(dir.clone()).expect("MeetingManager::new should succeed");

        manager
            .start_meeting("presencial")
            .expect("the first start_meeting should succeed");

        let second = manager.start_meeting("presencial");
        assert!(
            second.is_err(),
            "a second start_meeting should fail while the first meeting is still recording"
        );
        assert_eq!(second.unwrap_err().to_string(), "recording_busy");

        let conn = manager.get_connection().expect("get_connection");
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM meetings", [], |row| row.get(0))
            .expect("count meetings");
        assert_eq!(count, 1, "the rejected second call must not insert a row");

        drop(conn);
        drop(manager);
        let _ = std::fs::remove_file(&dir);
    }
}
