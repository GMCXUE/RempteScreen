export const fileTransferSchema = `
CREATE TABLE IF NOT EXISTS file_transfers (
 id BIGSERIAL PRIMARY KEY,
 sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 recipient_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 client_id TEXT NOT NULL,
 sender_name TEXT NOT NULL, recipient_name TEXT NOT NULL,
 sender_device_id TEXT NOT NULL, sender_device_name TEXT NOT NULL,
 recipient_device_id TEXT NOT NULL, recipient_device_name TEXT NOT NULL,
 file_name TEXT NOT NULL, size_bytes BIGINT NOT NULL CHECK(size_bytes BETWEEN 0 AND 52428800),
 created_at BIGINT NOT NULL, finished_at BIGINT,
 status TEXT NOT NULL CHECK(status IN ('sending','completed','failed','cancelled')),
 UNIQUE(sender_id,client_id)
);
CREATE INDEX IF NOT EXISTS idx_file_transfers_sender ON file_transfers(sender_id,id DESC);
CREATE INDEX IF NOT EXISTS idx_file_transfers_recipient ON file_transfers(recipient_id,id DESC);
`;
