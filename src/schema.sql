-- capsule's store. Opened only by capsuled; the CLI and the board reach it over the
-- socket, so the in-memory world model is never stale behind a write it didn't see.
--
-- Schema changes are handled by dropping and recreating this database. There is one user
-- and no production data, so there is no migration framework, no schema_version table,
-- and no up/down scripts. If the schema changes, say so in the commit.
--
-- Ids are UUIDv7 stored as 16-byte blobs: time-ordered, so index locality is good and the
-- default sort is creation order. created_at duplicates the timestamp already inside the
-- id, and is kept anyway — extracting it in SQL would mean hex arithmetic in every query.

CREATE TABLE IF NOT EXISTS projects (
  id             BLOB PRIMARY KEY,
  -- `git rev-parse --git-common-dir`, realpath'd. Not the worktree, or worktrees would
  -- silently fork into separate backlogs.
  canonical_path TEXT    NOT NULL UNIQUE,
  -- Profile belongs to the project, not the run, so `runs` has no profile column and
  -- joins through here.
  profile        TEXT    NOT NULL DEFAULT 'default',
  created_at     INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS issues (
  id            BLOB PRIMARY KEY,
  project_id    BLOB    NOT NULL REFERENCES projects(id),
  title         TEXT    NOT NULL,
  body          TEXT    NOT NULL DEFAULT '',
  -- A cache of replaying this issue's events, maintained only by the event applier.
  -- Nothing else may write it; see src/replay.zig.
  state         TEXT    NOT NULL,
  -- The optimistic-concurrency token for editor writeback: read at spawn, compared
  -- before write. There is no separate version column.
  last_event_id BLOB,
  created_at    INTEGER NOT NULL
) STRICT;

-- The source of truth, and append-only. An agent can claim completion but cannot erase
-- the record or rewrite an issue to match what it built.
CREATE TABLE IF NOT EXISTS events (
  id         BLOB PRIMARY KEY,
  issue_id   BLOB    NOT NULL REFERENCES issues(id),
  run_id     BLOB,
  actor      TEXT    NOT NULL,
  kind       TEXT    NOT NULL,
  payload    TEXT    NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS runs (
  id         BLOB PRIMARY KEY,
  issue_id   BLOB    NOT NULL REFERENCES issues(id),
  project_id BLOB    NOT NULL REFERENCES projects(id),
  branch     TEXT    NOT NULL,
  -- Only ever a hash. The token itself lives in the container's environment for the
  -- run's duration and nowhere else.
  token_hash BLOB,
  state      TEXT    NOT NULL,
  started_at INTEGER NOT NULL,
  ended_at   INTEGER
) STRICT;

-- Deliberately not in `events`: events are issue-scoped and append-only, memories are a
-- small curated set that gets edited and re-reviewed. Bending one table to hold both
-- would complicate replay for no benefit.
CREATE TABLE IF NOT EXISTS memories (
  id              BLOB PRIMARY KEY,
  -- NOT NULL until cross-project memory is built, so linking later is an added join
  -- rather than a migration.
  project_id      BLOB    NOT NULL REFERENCES projects(id),
  state           TEXT    NOT NULL,
  body            TEXT    NOT NULL,
  -- Repo-relative paths, newline-separated. Used only to flag a memory suspect when the
  -- path is deleted or renamed — never to filter which memories get injected.
  anchors         TEXT    NOT NULL DEFAULT '',
  origin_issue_id BLOB,
  created_at      INTEGER NOT NULL,
  reviewed_at     INTEGER
) STRICT;

CREATE INDEX IF NOT EXISTS issues_by_project ON issues(project_id, state);
CREATE INDEX IF NOT EXISTS events_by_issue   ON events(issue_id, id);
CREATE INDEX IF NOT EXISTS runs_by_project   ON runs(project_id, state);
CREATE INDEX IF NOT EXISTS memories_by_state ON memories(project_id, state);
