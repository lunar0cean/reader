ALTER TABLE subscriptions ADD COLUMN oauth_client_id TEXT;
ALTER TABLE subscriptions ADD COLUMN verified_at TEXT;
ALTER TABLE subscriptions ADD COLUMN previous_secret TEXT;
ALTER TABLE subscriptions ADD COLUMN rotation_until TEXT;
