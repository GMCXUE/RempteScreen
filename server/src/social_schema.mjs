// Idempotent account social tables, installed alongside the existing device schema.
export const socialSchema = `
CREATE TABLE IF NOT EXISTS friend_links (
 low_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 high_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 requester_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 state TEXT NOT NULL CHECK(state IN ('pending','accepted','declined','removed')),
 note TEXT NOT NULL DEFAULT '', created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
 PRIMARY KEY(low_id,high_id), CHECK(low_id < high_id)
);
CREATE TABLE IF NOT EXISTS friend_profiles (
 owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 peer_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 remark TEXT NOT NULL DEFAULT '', blocked BOOLEAN NOT NULL DEFAULT FALSE,
 read_seq BIGINT NOT NULL DEFAULT 0, PRIMARY KEY(owner_id,peer_id), CHECK(owner_id <> peer_id)
);
CREATE TABLE IF NOT EXISTS chat_messages (
 seq BIGSERIAL PRIMARY KEY, id TEXT NOT NULL UNIQUE,
 sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 recipient_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 client_id TEXT NOT NULL, text TEXT NOT NULL, created_at BIGINT NOT NULL,
 UNIQUE(sender_id,client_id), CHECK(sender_id <> recipient_id)
);
ALTER TABLE friend_profiles ADD COLUMN IF NOT EXISTS pinned BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE friend_profiles ADD COLUMN IF NOT EXISTS cleared_seq BIGINT NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_chat_pair ON chat_messages(sender_id,recipient_id,seq);
CREATE INDEX IF NOT EXISTS idx_chat_recipient ON chat_messages(recipient_id,seq);
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'text';
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS metadata JSONB;
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS recalled_at BIGINT;
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS edit_seq BIGINT NOT NULL DEFAULT 0;
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS payload_hash TEXT;
CREATE SEQUENCE IF NOT EXISTS chat_change_seq;
CREATE TABLE IF NOT EXISTS chat_images (
 message_id TEXT PRIMARY KEY REFERENCES chat_messages(id) ON DELETE CASCADE,
 data BYTEA NOT NULL
);
CREATE TABLE IF NOT EXISTS chat_videos (message_id TEXT PRIMARY KEY REFERENCES chat_messages(id) ON DELETE CASCADE,data BYTEA NOT NULL);
CREATE INDEX IF NOT EXISTS idx_chat_edits ON chat_messages(sender_id,recipient_id,edit_seq) WHERE edit_seq>0;
`;
