# SchedulesDirectService

Schedules Direct (JSON API 20141201) account, client and guide-data sync for Live TV.
Phase 1: account + client + sync + on-device cache. There is **no** guide merge yet:
nothing here is read by the matcher, station index, XMLTV or lineup code.

Legal and tech background: `~/doc/SCHEDULES_DIRECT_LEGAL.md`,
`_briefs/live-tv-glass/schedules-direct/REPORT-tech.md`.

## Feature flag

`RuntimeFeatureFlag.schedulesDirect` (CoreModels `RuntimeFeatureFlags`). **On in DEBUG
builds, off in Release** (`productionDefault` excludes it) until Schedules Direct approves
Plozz in writing. With the flag off there is no UI (Live TV settings shows no "Guide Data"
section), `SchedulesDirectService` throws `featureDisabled` before any network, Keychain or
file access, and `state()` returns a disabled state. Tests: `SchedulesDirectFeatureFlagTests`.

## Layout

| File | Role |
|---|---|
| `SchedulesDirectService` | Facade per profile namespace: `signIn`, `signOut`, `reconnect`, `headends`, `addLineup`, `removeLineup`, `syncNow`, `syncIfDue`, `purgeProfile`, `state()`. `.standard(namespace:)` is the production wiring |
| `SchedulesDirectSession` | One actor per account (shared by every profile with that account): one reused token, the single place requests are sent, response classification, central `User-Agent: Plozz/<CFBundleShortVersionString> (<platform>)` |
| `SchedulesDirectGovernor` | Persisted per-account ledger, not-before, needs-attention, circuit breaker, sync schedule; `SchedulesDirectRequestLimiter` (token bucket + max 2 in flight) |
| `SchedulesDirectCredentials` | Username + lowercase SHA1 hex in the Keychain (`SecureStoring`, `ThisDeviceOnly`), per profile; token + expiry in the Keychain keyed by account |
| `SchedulesDirectSyncEngine` / `SchedulesDirectGuideCache` | status → lineups (only if `modified` changed) → `schedules/md5` → changed schedules → programs with changed md5; cache in Application Support, excluded from backup |
| `SchedulesDirectError` | Typed errors and the code table |

## Request governor

- One token per account, reused until 5 minutes before `tokenExpires`; a new token (`newToken`)
  only through "Reconnect". Profiles with the same account share token, ledger and cache.
- Ledger: at most **20 requests/hour, 100/day** per account (every request counts, including
  `/token`), persisted in `governor.json`; survives relaunch and sign-out.
- Limiter: token bucket (burst 2, 1/s) and at most 2 concurrent requests.
- Stop (persisted `needsAttention`, no automatic retry, including after relaunch): 1050, 4001,
  4002, 4003, 4004, 4005, 4007, 4008, 4009, 4010, 4011, protocol errors (1003/1005/…) and any
  unknown code.
- Back-pressure (persisted not-before): HTTP 429/503, `Retry-After`, `retryTime` (7100), 6001,
  3000/3001, status `Offline` (1 h), non-JSON/HTML bodies. Up to 3 attempts per request, only when
  the wait is ≤ 60 s; otherwise the exponential backoff (15 min, 30 min, … ≤ 6 h, +≤ 10 % jitter) is
  persisted. The third consecutive failure holds the circuit open for 6 h.
- Sync: at most once per hour; automatic sync daily at a per-install random minute, never on a cold
  start with a cache younger than a day; on iOS only on Wi-Fi/Ethernet
  (`SchedulesDirectNetworkPolicy`).

## Cache

`Application Support/SchedulesDirect/<accountKey>/guide-cache.json` (+ `account.json`,
`governor.json`). Window `now − 6 h … now + 72 h`, at most 500 stations, 50 MB (stations are dropped
from the tail, then unreferenced programs). Purged on sign-out, account expiry and profile deletion
(`purgeProfile()`). No artwork is downloaded.

## Logging

Only reason names and numeric codes are logged (`PlozzLog.sync`). Usernames, hashes and tokens never
are (`SchedulesDirectFeatureFlagTests.testCredentialsTokensAndHashesNeverAppearInLogs`).

## Tests

`tools/run-tests.sh SchedulesDirectServiceTests` — stub HTTP, fake clock, in-memory secure store; no
real Schedules Direct calls.
