export const updateSchema=`
CREATE TABLE IF NOT EXISTS update_packages (
 sha256 TEXT PRIMARY KEY, platform TEXT NOT NULL, arch TEXT NOT NULL,
 extension TEXT NOT NULL, size_bytes BIGINT NOT NULL, uploaded_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS app_releases (
 id TEXT PRIMARY KEY, platform TEXT NOT NULL, arch TEXT NOT NULL, channel TEXT NOT NULL,
 version_name TEXT NOT NULL, build_code BIGINT NOT NULL, notes TEXT NOT NULL,
 package_sha256 TEXT NOT NULL REFERENCES update_packages(sha256),
 force_update BOOLEAN NOT NULL DEFAULT FALSE,
 status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','published','withdrawn')),
 created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL, published_at BIGINT,
 revision INTEGER NOT NULL DEFAULT 1,
 UNIQUE(platform,arch,channel,build_code)
);
CREATE INDEX IF NOT EXISTS app_releases_lookup ON app_releases(platform,arch,channel,status,build_code DESC);
CREATE TABLE IF NOT EXISTS hot_releases (
 id TEXT PRIMARY KEY, platform TEXT NOT NULL, arch TEXT NOT NULL, channel TEXT NOT NULL,
 native_build BIGINT NOT NULL, revision INTEGER NOT NULL, notes TEXT NOT NULL,
 resource JSONB NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('published','withdrawn')),
 created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL,
 UNIQUE(platform,arch,channel,native_build,revision)
);
CREATE INDEX IF NOT EXISTS hot_releases_lookup ON hot_releases(platform,arch,channel,native_build,status,revision DESC);
`;
