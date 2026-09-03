# 0002: Retire the RS-CONNECTIONS module

**Status:** Open
**Priority:** Medium
**Area:** Architecture / service topology (ORCHESTRATOR, RS-GROUPS, RS-NOTES, RS-NOTIFICATIONS)

## Problem

RS-CONNECTIONS is a half-migrated duplicate of state RS-GROUPS already owns, and
most of its surface is dead. The parent↔subgroup edge lives in **two** stores —
the `connections` table (RS-CONNECTIONS) *and* the `groups.parent_group_key`
column (RS-GROUPS) — and they drift immediately: RS-GROUPS writes only the
column, so the connections rows go stale. Two of four relationship endpoints
are empty stubs; `POST /connection/groups` and `locker_items` have zero callers;
the frontends (sr-next, sr-client, sr-web) never invoke it (`sr-client` keeps
only `Connection` type stubs and a commented-out registry entry, no
`Connections.ts` accessor, no URL calls). Orgs live **only** in RS-GROUPS
(`group_orgs`), not in connections. Nothing in the connections store exists
that isn't also expressed by the GROUPS column — except the unused generic
`connection_type` vocabulary + connection locker, which no live feature reads.

The orphaned service is also a fragility hazard: `httpclient` panics (without
recover) on an unreachable service, so the three live call paths would 500 if
the container were stopped without re-pointing their readers first.

## Proposed solution

Re-point the five live uses at GROUPS-held state, then remove the container,
compose entries, and (optionally) the tables.

### Per-use removal

1. **`POST /connection` — RS-GROUPS subgroup fan-out (`pkg/web/group.go:247`).**
   Writes a bidirectional `is-subgroup`/`is-parent` pair post-commit,
   non-fatally. The `parent_group_key` column is already written
   in-transaction alongside the group row. *Fix:* delete the call
   (one line); no replacement.

2. **`GET /connection/for/:groupKey` — ORCHESTRATOR GraphQL `connections`.**
   Resolver + `schema.graphqls` `Group.connections(...)`; runs only on a
   preload and is `PanicHandler`-wrapped, so it already degrades to empty.
   `parentGroup`/`childGroups`/`orgs` are served from GROUPS on the same query
   and are the exact equivalents (minus the unused per-connection locker).
   *Fix:* remove the resolver + field + preload; no client selects `connections`.

3. **`GET /connection/for/:groupKey` — RS-NOTES `LocateConnectedParentGroup`
   (`pkg/client/groupsclient.go:251`).** Mailer templates fetch the parent group
   for parent context. RS-NOTES already fetches `GET /group/:key` in
   `LocateGroup`; it just doesn't parse `parent_group_key`/`parent_group`.
   *Fix:* parse those two fields from the existing group JSON, then drop the
   connection call. Parse-only.

4. **`GET /connection/for/:groupKey` — RS-NOTIFICATIONS `GetParentGroup`
   (`pkg/services/connectionclient.go:15`, weekly summary cron).** Fetch the
   parent group key for the digest. *Fix:* read `parent_group_key` off a GROUPS
   response (reuse the notifications groups client), then delete the connection
   client.

5. **`GET /connection/report/created/subgroups/for/parent/...` — RS-NOTIFICATIONS
   `GetNewSubGroups` (`connectionclient.go:44`).** Weekly "new subgroups" count
   over an interval. *Fix:* only genuinely missing function — add a small GROUPS
   query (`SELECT count(*) FROM groups WHERE parent_group_key=$1 AND
   status='active' AND created BETWEEN $2 AND $3`); `groups.created` already
   exists.

### Dead surface (delete outright, zero callers)

- `POST /connection/groups` + its only caller `LocateBatchConnections`
- `GET /connection/subgroups/for/:groupKey` (stub handler)
- `GET /connection/parent/for/:groupKey` (stub handler)
- RS-GROUPS `LocateConnectionSubGroups` (superseded by `PGXGetSubgroupKeys`)
  and `DetermineGroupType` (only used by an offline backfill script)

## Files affected

- `modules/RS-GROUPS/pkg/web/group.go`, `pkg/client/connectionsclient.go`
- `modules/RS-NOTES/pkg/client/groupsclient.go`, mailer templates
- `modules/RS-NOTIFICATIONS/pkg/services/connectionclient.go`, `pkg/groups`
- `modules/ORCHESTRATOR/pkg/clients/connectionsclient.go`, `graph/schema.resolvers.go`, `graph/schema.graphqls`, `pkg/api/api.go` (routeMap)
- `docker-compose.yml`, `docker-compose-traefik.yml` (container `sr-rs-connections`)
- `RS-UTILS/httpclient/servicehost.go` (`"connections"` host mapping)

## Implementation order

1. Add the GROUPS interval query for `GetNewSubGroups` (#5).
2. Re-point RS-NOTES (#3) and RS-NOTIFICATIONS (#4) parent lookups; parse the
   parent fields from existing GROUPS reads.
3. Remove the ORCHESTRATOR GraphQL `connections` field (#2).
4. Delete the GROUPS subgroup fan-out write (#1) and the dead endpoints/clients.
5. Remove the `sr-rs-connections` container/routeMap/host entries.
6. Drop the `connections`/`connection_lockers`/`locker_items` tables (no foreign
   keys reference them from any other service).

Order matters: steps 5–6 must land *after* 1–4, or the three panic paths
(subgroup create, mailer, cron) 500 on an unreachable service.

## Risk

Low. All live readers have GROUPS equivalents; only the weekly-subgroups query
is new. No foreign keys couple the tables to other services. The one lost
concept is the generic `connection_type` vocabulary + connection locker —
unused today.

## Out of scope / preserved

The rich cross-group relationship model (arbitrary pairwise connections with
CRUD/routing/visibility policy) is **not** abandoned — it is tracked as the
policy-location question in
`modules/RS-GROUPS/issues/0007-redesign-groups-permission-as-policy.md`. This
issue only retires the dead `connections` store; the *concept* lives on in the
design issues, not in a running service.