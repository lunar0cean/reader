CREATE TABLE sessions (
  owner TEXT NOT NULL, id TEXT NOT NULL, character_id TEXT NOT NULL,
  character_name TEXT NOT NULL, persona TEXT NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY(owner, id)
);
CREATE TABLE requests (
  owner TEXT NOT NULL, id TEXT NOT NULL, session_id TEXT NOT NULL, character_id TEXT NOT NULL,
  text TEXT NOT NULL, excerpts_json TEXT NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY(owner, id)
);
CREATE INDEX requests_session ON requests(owner, session_id, created_at);
CREATE TABLE subscriptions (
  id TEXT PRIMARY KEY, owner TEXT NOT NULL, session_id TEXT NOT NULL, character_id TEXT NOT NULL,
  callback_url TEXT NOT NULL, secret TEXT NOT NULL, expires_at TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX subscriptions_session ON subscriptions(owner, session_id, character_id);
CREATE TABLE deliveries (
  subscription_id TEXT NOT NULL, request_id TEXT NOT NULL, owner TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0, accepted INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL, last_error TEXT,
  PRIMARY KEY(subscription_id, request_id)
);
CREATE TABLE results (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT NOT NULL, request_id TEXT NOT NULL,
  session_id TEXT NOT NULL, character_id TEXT NOT NULL, kind TEXT NOT NULL,
  payload_json TEXT NOT NULL, created_at TEXT NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0,
  UNIQUE(owner, request_id, kind)
);
CREATE INDEX results_sync ON results(owner, session_id, seq);
