CREATE TABLE installations (
 id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, token_key_version TEXT NOT NULL,
 created_at TEXT NOT NULL, last_seen_at TEXT NOT NULL, revoked_at TEXT,
 client_version TEXT NOT NULL, platform TEXT NOT NULL CHECK(platform='macos-arm64')
);
CREATE TABLE daily_quotas (
 installation_id TEXT NOT NULL REFERENCES installations(id), bucket_date TEXT NOT NULL,
 limit_snapshot INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0,
 reserved INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(installation_id,bucket_date),
 CHECK(used>=0 AND reserved>=0 AND used+reserved<=limit_snapshot)
);
CREATE TABLE transcription_tasks (
 request_id TEXT NOT NULL, owner_installation_id TEXT NOT NULL REFERENCES installations(id),
 idempotency_key TEXT NOT NULL, input_fingerprint TEXT NOT NULL,
 output_mode TEXT NOT NULL CHECK(output_mode IN ('raw','light_polish')),
 status TEXT NOT NULL CHECK(status IN ('processing','ready','failed','cancelled','unknown','result_expired')),
 polish_status TEXT NOT NULL CHECK(polish_status IN ('not_requested','pending','succeeded','failed_fallback_raw')),
 quota_bucket_date TEXT NOT NULL,
 reservation_state TEXT NOT NULL CHECK(reservation_state IN ('reserved','used','released')),
 dispatch_marked_at TEXT, cancel_requested_at TEXT,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, terminal_at TEXT,
 result_expires_at TEXT, failure_code TEXT, tombstone_until TEXT NOT NULL,
 PRIMARY KEY(owner_installation_id,request_id), UNIQUE(owner_installation_id,idempotency_key)
);
CREATE INDEX tasks_status ON transcription_tasks(status,updated_at);
CREATE INDEX tasks_tombstone ON transcription_tasks(tombstone_until);
CREATE INDEX tasks_expiry ON transcription_tasks(result_expires_at);
CREATE TABLE budget_ledger (
 id TEXT PRIMARY KEY, owner_installation_id TEXT NOT NULL, request_id TEXT NOT NULL,
 bucket_date TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('reserved','committed','settled','held_unknown','released')),
 estimated_units INTEGER NOT NULL CHECK(estimated_units>0), actual_units INTEGER CHECK(actual_units>=0),
 config_version TEXT NOT NULL, created_at TEXT NOT NULL, settled_at TEXT,
 UNIQUE(owner_installation_id,request_id),
 FOREIGN KEY(owner_installation_id,request_id) REFERENCES transcription_tasks(owner_installation_id,request_id) ON DELETE CASCADE
);
CREATE INDEX budget_bucket ON budget_ledger(bucket_date,state);
