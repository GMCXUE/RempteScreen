# Project instructions

- Any user-facing client feature must be implemented in both the primary desktop client under `apps/desktop-rs/` and the mobile client under `apps/flutter_client/` in the same change.
- Keep the desktop and mobile behavior, protocol, error handling, and user-visible wording aligned unless a platform limitation requires a documented difference.
- The legacy Electron client in `apps/desktop/` and the early Android prototype in `apps/android/` do not need matching changes unless the user explicitly requests them.
- Publish updates as full installation packages by default. Do not publish new hot-update patches unless the user explicitly asks for hot updates. Keep the desktop hot-update loader, mobile Shorebird integration, and existing hot-update management capabilities available.
