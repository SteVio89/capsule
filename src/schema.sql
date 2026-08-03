-- capsule's store. Schema changes are made by dropping and recreating the database;
-- there is no migration framework.

CREATE TABLE IF NOT EXISTS projects (
  id             BLOB PRIMARY KEY,
  -- `git rev-parse --git-common-dir`, realpath'd — not the worktree, which would fork
  -- one repository into separate backlogs.
  canonical_path TEXT    NOT NULL UNIQUE,
  profile        TEXT    NOT NULL DEFAULT 'default',
  created_at     INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS issues (
  id            BLOB PRIMARY KEY,
  project_id    BLOB    NOT NULL REFERENCES projects(id),
  title         TEXT    NOT NULL,
  body          TEXT    NOT NULL DEFAULT '',
  -- A cache of replaying this issue's events, written only by the event applier.
  state         TEXT    NOT NULL,
  -- The optimistic-concurrency token for editor writeback.
  last_event_id BLOB,
  created_at    INTEGER NOT NULL
) STRICT;

-- The source of truth, and append-only.
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
  -- Only ever a hash; the token itself lives in the container's environment.
  token_hash BLOB,
  state      TEXT    NOT NULL,
  started_at INTEGER NOT NULL,
  ended_at   INTEGER
) STRICT;

CREATE TABLE IF NOT EXISTS memories (
  id              BLOB PRIMARY KEY,
  project_id      BLOB    NOT NULL REFERENCES projects(id),
  state           TEXT    NOT NULL,
  body            TEXT    NOT NULL,
  -- Repo-relative paths, newline-separated. Only ever used to flag a memory suspect,
  -- never to filter which memories get injected.
  anchors         TEXT    NOT NULL DEFAULT '',
  origin_issue_id BLOB,
  created_at      INTEGER NOT NULL,
  reviewed_at     INTEGER
) STRICT;

CREATE INDEX IF NOT EXISTS issues_by_project ON issues(project_id, state);
CREATE INDEX IF NOT EXISTS events_by_issue   ON events(issue_id, id);
CREATE INDEX IF NOT EXISTS runs_by_project   ON runs(project_id, state);
CREATE INDEX IF NOT EXISTS memories_by_state ON memories(project_id, state);
