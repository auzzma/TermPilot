CREATE TABLE IF NOT EXISTS batch_saved_jobs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    configuration TEXT NOT NULL,
    created_ms INTEGER NOT NULL,
    updated_ms INTEGER NOT NULL,
    revision INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS batch_editor_drafts (
    id TEXT PRIMARY KEY,
    payload TEXT NOT NULL,
    revision INTEGER NOT NULL
);
