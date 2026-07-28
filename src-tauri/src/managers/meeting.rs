//! Manages the lifecycle of a meeting notetaker session: recording, live
//! transcription, and speaker diarization. This is currently a skeleton —
//! real behavior lands in later tasks (T006/T011 onward). T005 adds the
//! SQLite schema (migrations only, no business logic yet).

use anyhow::Result;
use log::{debug, info};
use rusqlite::Connection;
use rusqlite_migration::{Migrations, M};
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

#[allow(dead_code)]
pub struct MeetingManager {
    db_path: PathBuf,
}

impl MeetingManager {
    /// Open (or create) the meeting database at `db_path` and apply any
    /// pending migrations. Mirrors `HistoryManager::new` /
    /// `HistoryManager::init_database`, minus the tauri-plugin-sql legacy
    /// migration path (there is no pre-existing meeting data to carry over).
    #[allow(dead_code)]
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
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
