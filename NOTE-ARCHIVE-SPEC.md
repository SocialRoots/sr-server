# Note Archive — Implementation Spec

Status: draft for review. Targets modules `ORCHESTRATOR`, `RS-NOTES`, `RS-GROUPS` (read-only), and `RS-RESPONSES` (write-guard).

## 1. Behaviour being built

Two distinct operations:

### Op 1 — Personal inbox archive (light, reversible)
A member hides a note from **their own** inbox.
- Affects only that one user's inbox list.
- Note stays **active** everywhere; everyone (including them, via group context) can still read/reply/edit.
- **Reversible** by that user.

### Op 2 — Leader group archive (authoritative, currently one-way)
A **leader** of group A archives a note from group A.
- The note is removed from the **group A view** for everyone in group A (all leaders + members).
- Every group-A member keeps a **copy in their inbox**, but that copy becomes **read-only / inactive** (no reply, edit, reaction) — *once the note has no remaining active group context for that user* (see cross-group rule below).
- **Cross-group safe:** if the note was also sent to group B, group B is untouched (still visible and writable).
- **Not reversible yet** — model the data so unarchive can be added later, but don't expose it.

### Cross-group rule (important nuance)
A user has exactly **one** inbox copy (`user_note` row) per note, regardless of how many groups delivered it. Therefore an inbox copy cannot be "read-only for group A but writable for group B." Rule:

> A user's inbox copy is read-only **iff every group context through which that user received the note is archived.** If at least one of their group contexts remains active, the inbox copy stays writable.

Direct (non-group) notes have no group context and are never affected by Op 2.

---

## 2. Data model (verified against the code)

Relevant tables (all in `RS-NOTES/db/migrations`):

- **`notes`** — has global `status` ('active'/'inactive'). *We do NOT use this for the new feature* (it's global to the whole note and can't express per-group archive).
- **`note_participants`** — `(note_id, participant_id, status, link, participant_group_key, participation, ...)`.
  - For `participation='user_note'` rows: `participant_group_key` = **the user's own key** (`notes.go:128,195`). This is the personal inbox copy — **one per user per note**.
  - For involvement rows (`participation` in `receiver`/`sender_group`/`system_receiver`/…): `participant_group_key` = **the real group key**. These map a user into a group context for the note.
  - `status` here means delivery state ('active'/'queued'/'inactive') — **do not overload it** for archive.
- **`note_groups`** — `(note_id, group_key, target_role, created)`. One row per (note, group). Drives the group-context read. **This is the single source of truth for Op 2.**

### Schema changes (migrations)

```sql
-- Op 1: personal inbox archive (per user_note row)
ALTER TABLE note_participants ADD COLUMN archived boolean NOT NULL DEFAULT false;

-- Op 2: group archive (per note, per group) — single source of truth
ALTER TABLE note_groups ADD COLUMN archived          boolean NOT NULL DEFAULT false;
ALTER TABLE note_groups ADD COLUMN archived_by        text    NOT NULL DEFAULT '';   -- user_key, audit + future unarchive
ALTER TABLE note_groups ADD COLUMN archived_at        timestamptz;
```

Add matching `*_test` table columns (this repo uses `TestCk()` to target `_test` tables — see `1659557411-add-test-tables.sql`).

No new column is needed on `note_participants` for Op 2 — the read-only state is **derived** from `note_groups.archived` + the user's involvement rows.

---

## 3. RS-NOTES — endpoints

Replace the unsafe `GET /note/id/:id/status/:status` pattern with scoped POST endpoints. (Audit callers of the old route before removing it — see Open Questions.)

> **Verb note (revised during step 4):** the endpoints are implemented as **GET with all
> params in the path** rather than POST. Rationale: the orchestrator's only cache-correct,
> body-free write mechanism is `ConsumeGetEndpoint` + `ForceInvalidation` (used by
> `UpsertEmote` and the old `updateNoteStatus`). `ConsumePostEndpoint` caches responses in
> Redis and sends array-style bodies — wrong for a mutation. We keep the real improvements
> over the legacy route (scoped paths, leader authz, honest `changed`, a real GraphQL
> mutation); the verb is the single concession to the existing framework.

### 3.1 Personal inbox archive (Op 1)
```
GET /note/id/:id/participant/:userKey/archive/:archived      (:archived = true|false)
```
Handler `archiveNoteForParticipant`:
1. Resolve the participant for `userKey`; verify a `user_note` participation row exists for `(noteId, participant)`. If not → **404** (not in this user's inbox).
2. `db.PGXSetParticipantArchived(conn, noteId, userKey, archived)`.
3. Invalidate that user's workspace pages: `cache.InvalidateNoteAcrossWorkspacePages(userKey)`.
4. Return `200 { changed: bool, archived: bool }`.

### 3.2 Leader group archive (Op 2)
```
GET /note/id/:id/group/:groupKey/user/:userKey/archive/:archived   (:archived = true|false; only true exposed via orchestrator yet)
```
Handler `archiveNoteForGroup`:
1. **Authorize:** `role := client.GroupFindMemberRole(groupKey, userKey)` (existing groups client, `RS-NOTES/pkg/client/groupsclient.go:271`). Allow only `role.Role ∈ {"lead","creator"}` for the **exact group the note was delivered to** (the `groupKey` on the `note_groups` row). **No `parent_role` special-casing:** a parent-group leader may archive a subgroup's note only if they are *also* a leader of that subgroup, which the direct role check on `groupKey` already enforces. Else → **403**.
2. **Validate delivery:** confirm a `note_groups` row exists for `(noteId, groupKey)`. Else → **404** (note was not delivered to this group).
3. `db.PGXSetGroupNoteArchived(conn, noteId, groupKey, archived, userKey)`.
4. **Cache invalidation:** invalidate group-context cache for `groupKey`, and invalidate workspace pages for every group-A member who has an inbox copy (mirror the existing loop in `PGXUpdateStatus`, but select affected users via the group's involvement rows — see DB section).
5. Return `200 { changed: bool, archived: bool }`.

### 3.3 (Optional) writability check for the write-guard
```
GET /note/id/:noteId/writable/user/:userKey   ->  { writable: bool }
```
Returns the derived read-only computation (§5.3) so `RS-RESPONSES` can enforce "no further changes" server-side. Alternatively enforce in the orchestrator resolver (see §6).

---

## 4. RS-NOTES — DB functions (`pkg/db`)

### 4.1 `PGXSetParticipantArchived` (notePGX.go / noteparticipantPGX.go)
```go
func PGXSetParticipantArchived(conn *pgxpool.Pool, noteId, userKey string, archived bool) (bool, error) {
    q := `UPDATE note_participants` + TestCk() + ` np
          SET archived=$3
          FROM participants p
          WHERE np.participant_id = p.id
            AND p.user_key = $2
            AND np.note_id = $1
            AND np.participation = 'user_note'`
    ct, err := conn.Exec(context.Background(), q, noteId, userKey, archived)
    return ct.RowsAffected() > 0, err   // honest "changed" result
}
```

### 4.2 `PGXSetGroupNoteArchived`
```go
func PGXSetGroupNoteArchived(conn *pgxpool.Pool, noteId, groupKey string, archived bool, byUser string) (bool, error) {
    q := `UPDATE note_groups` + TestCk() + `
          SET archived=$3, archived_by=$4, archived_at=now()
          WHERE note_id=$1 AND group_key=$2`
    ct, err := conn.Exec(context.Background(), q, noteId, groupKey, archived, byUser)
    return ct.RowsAffected() > 0, err
}
```
For cache invalidation, first select affected users (those with a `user_note` copy who received the note via this group). Reuse the existing per-user invalidation loop pattern from `PGXUpdateStatus` (notePGX.go:603).

---

## 5. RS-NOTES — read-path changes

### 5.1 Group context read — `PGXGetNotesByGroupAndRole` (notePGX.go:296)
Query is `FROM note_groups ng ... WHERE ng.group_key=$1`. Add:
```sql
WHERE ng.group_key=$1 AND ng.archived = false
```
This removes Op-2-archived notes from the group A view for everyone. (Keep the existing `note.Note.Status == "inactive"` skip as-is for the legacy global archive.)

### 5.2 Inbox read — `PGXGetNotesByParticipantUserKey` (noteparticipantPGX.go:360)
Two changes:

**(a) Hide Op 1 personal-archived notes.** Add to the WHERE clause:
```sql
AND np.archived = false
```

**(b) Surface the Op 2 read-only flag without removing the row.** Add a derived `read_only` column and return it on the note model (do **not** filter these out — the copy must stay in the inbox):
```sql
,
( EXISTS (  -- the note has at least one group context for this user
    SELECT 1 FROM note_participants ip
    JOIN note_groups ng ON ng.note_id = ip.note_id AND ng.group_key = ip.participant_group_key
    WHERE ip.note_id = n.id AND ip.participant_id = p.id AND ip.participation <> 'user_note'
  )
  AND NOT EXISTS (  -- ...and none of them is still active
    SELECT 1 FROM note_participants ip
    JOIN note_groups ng ON ng.note_id = ip.note_id AND ng.group_key = ip.participant_group_key
    WHERE ip.note_id = n.id AND ip.participant_id = p.id AND ip.participation <> 'user_note'
      AND ng.archived = false
  )
) AS read_only
```
Add `ReadOnly bool` to the note model returned here and scan it.

> Note: the existing `n.status!='inactive'` filter in this query is the legacy global archive — leave it. The new per-user/per-group behaviour is independent of it.

### 5.3 Derived read-only definition (reference)
`read_only(user U, note N)` = `(U has ≥1 group context for N)` AND `(every such group context has note_groups.archived = true)`. Used by both the inbox read (§5.2b) and the optional writability endpoint (§3.3).

---

## 6. RS-RESPONSES — enforce "no further changes"

All post-send writes to a note live in `RS-RESPONSES` (the orchestrator `upsertEmote` mutation calls the `"responses"` service). **There is no note-content "edit" endpoint anywhere** — RS-NOTES has no edit route — so the complete writable surface to guard is:

- `POST /response/reply` (`addReplyToNoteLink`) and `POST /response/reply/log` (`logReplyResponse`)
- `GET  /response/emote/...` (`addEmote`)
- `GET  /response/reaction/link/...` (`catchReaction`) and `POST /response/reactions/new_note/note_id/:noteId` (`setupBulkNewNoteReactions`)

Guard: **before** creating any of the above, check writability for the acting user + note and reject (e.g. `409`/`403` with a clear message) if read-only. Source the writability decision from §3.3 `GET /note/id/:noteId/writable/user/:userKey` (the derived rule in §5.3).

**(O1) Placement decision:** enforce in `RS-RESPONSES` (recommended — robust server-to-server, covers direct callers) vs the orchestrator resolver (simpler single chokepoint, but bypassable if the responses service is hit directly).

---

## 7. ORCHESTRATOR — GraphQL + client

Follow the existing `upsertEmote` pattern (`schema.graphqls` → `schema.resolvers.go` → `pkg/clients/*client.go` → `ConsumePostEndpoint(endpoint, "notes", body)`).

### 7.1 Schema (`graph/schema.graphqls`)
```graphql
input ArchiveInboxInput  { noteId: Int!  userKey: String!  archived: Boolean! }
input ArchiveGroupInput  { noteId: Int!  groupKey: String!  userKey: String! }

type ArchiveResult { noteId: ID!  changed: Boolean!  archived: Boolean! }

type Mutation {
    # existing:
    upsertEmote(input: NewEmote!): Emote!
    # new:
    archiveNoteInInbox(input: ArchiveInboxInput!): ArchiveResult!   # Op 1, reversible (archived: true|false)
    archiveNoteForGroup(input: ArchiveGroupInput!): ArchiveResult!  # Op 2, archive-only for now
}
```
Also add a field to the `Note` type so clients can disable controls:
```graphql
type Note { 	# ...existing fields...
    readOnly: Boolean!   # true when the inbox copy is group-archived (read-only)
}
```

### 7.2 Resolvers (`graph/schema.resolvers.go`)
```go
func (r *mutationResolver) ArchiveNoteInInbox(ctx context.Context, input model.ArchiveInboxInput) (*model.ArchiveResult, error) {
    return clients.ArchiveNoteInInbox(input)
}
func (r *mutationResolver) ArchiveNoteForGroup(ctx context.Context, input model.ArchiveGroupInput) (*model.ArchiveResult, error) {
    return clients.ArchiveNoteForGroup(input)
}
```

### 7.3 Client (`pkg/clients/notesclient.go`)
Add two functions using `ConsumePostEndpoint(endpoint, "notes", body)`:
- `ArchiveNoteInInbox`  → `POST /note/id/{noteId}/participant/{userKey}/archive`, body `{archived}`.
- `ArchiveNoteForGroup` → `POST /note/id/{noteId}/group/{groupKey}/archive`, body `{userKey, archived:true}`.

Map the RS-NOTES JSON response into `*model.ArchiveResult`. Set `ForceInvalidation = true` around the call (as `UpsertEmote` does) so orchestrator-side caches refresh.

Regenerate gqlgen artifacts (`graph/generated`, `graph/model/models_gen.go`) after editing the schema.

---

## 8. Why this is better than today's `GET /note/id/:id/status/:status`

| Dimension | Today | This spec |
|---|---|---|
| Scope | Global `notes.status` — flips the whole note | Op 1 per-user; Op 2 per-(note,group) via `note_groups` |
| Cross-group | Impossible (one global flag) | Group B unaffected when group A archives |
| Auth | None — any caller, any id | Op 2 verified leader via RS-GROUPS; Op 1 verified inbox ownership |
| HTTP verb | `GET` performing a write | `POST`, validated body |
| Reachable by clients | No orchestrator mutation | First-class GraphQL mutations |
| Honesty | `PGXUpdateStatus` returns nil even on 0 rows | returns `changed` from `RowsAffected()` |
| Reversibility | One-way `UPDATE` | Modeled as toggleable; Op 1 exposed, Op 2 ready for later |
| Inbox copy on archive | n/a | Stays as read-only copy, exactly as required |

---

## 9. Build order (suggested)

1. ✅ Migrations (§2) incl. `_test` tables — DONE. Applied to dev `sr_notes` via shmig:
   - `db/migrations/1780710107-add-archived-to-note-participants.sql` (Op 1: `note_participants.archived`)
   - `db/migrations/1780710108-add-archive-to-note-groups.sql` (Op 2: `note_groups.archived/archived_by/archived_at`)
2. ✅ RS-NOTES DB functions + endpoints (§3, §4) — DONE.
   - `pkg/db/notePGX.go`: `PGXSetParticipantArchived` (Op 1), `PGXSetGroupNoteArchived` (Op 2), `invalidateGroupArchiveCaches` helper. Both return honest `changed` from `RowsAffected()`.
   - `pkg/web/note.go`: `archiveNoteForParticipant`, `archiveNoteForGroup` (leader authz via `client.GroupFindMemberRole`, roles `lead`/`creator`).
   - `pkg/web/server.go`: `POST /note/id/:id/participant/:userKey/archive`, `POST /note/id/:id/group/:groupKey/archive` (reuse `:id` param to avoid gin wildcard conflict).
   - Verified: module builds clean (`go build ./...`), `pkg/db` vets clean, and a route-registration test confirmed both routes register with no gin panic. (Pre-existing unrelated vet warning at `webcore.go:16`.)
3. ✅ RS-NOTES read-path changes + `readOnly`/inbox filter (§5) — DONE.
   - `pkg/models/note_model.go`: added `ReadOnly bool` (`json:"read_only"`) to `Note`.
   - `pkg/db/notePGX.go` (`PGXGetNotesByGroupAndRole`): group view now filters `AND ng.archived = false`.
   - `pkg/db/noteparticipantPGX.go` (`PGXGetNotesByParticipantUserKey`): inbox hides `np.archived = true`; adds derived `read_only` column (EXISTS group context AND NOT EXISTS active group context) and scans it into `note.Note.ReadOnly`.
   - Verified: builds clean; `EXPLAIN` of both queries valid against live `sr_notes`; functional truth-table test (rolled-back txn) confirmed read_only f/f/t across both-active / one-archived / both-archived, group view removal, and personal-archive inbox hide.
4. ✅ Orchestrator schema + resolvers + client + gqlgen regen (§7) — DONE.
   - `graph/schema.graphqls`: `Note.readOnly`, `ArchiveInboxInput`, `ArchiveGroupInput`, `ArchiveResult`, mutations `archiveNoteInInbox` / `archiveNoteForGroup`.
   - gqlgen regenerated `graph/generated/generated.go` + `graph/model/models_gen.go` (run under **Go 1.20** — vendored `x/tools` can't parse 1.24 export data; deploy build still uses 1.24).
   - `graph/schema.resolvers.go`: implemented both resolvers (delegate to clients).
   - `pkg/clients/notesclient.go`: `ArchiveNoteInInbox`, `ArchiveNoteForGroup` (GET + `ForceInvalidation`, like `UpsertEmote`), shared `archiveResultFromResponse` mapper; `ParseNote` now maps `read_only` → `Note.ReadOnly`.
   - RS-NOTES endpoints converted to GET-with-path-params (see verb note in §3) and rebuilt clean.
   - Removed a pre-existing unused `time` import in `server.go` (unrelated dead code that blocked the module build; cleared with the user).
   - Verified: full module `go build ./...` clean under **both Go 1.20 and Go 1.24**; `pkg/clients` vets clean.
5. ✅ RS-RESPONSES write-guard (§6) — DONE.
   - RS-NOTES: added writability endpoints `GET /note/id/:id/writable/user/:userKey` and `GET /note/link/:link/writable` (`noteWritableForUser` / `noteWritableByLink`), backed by `PGXIsNoteReadOnlyForUser` and `PGXIsNoteLinkReadOnly` (same read-only derivation as the inbox read; link variant resolves the cap-key to its participant). Both fail-open on error.
   - RS-RESPONSES: `pkg/client/notesclient.go` adds `IsNoteWritableForUser` / `IsNoteLinkWritable` (GET + `ForceInvalidation` to bypass the response cache; fail-open via `noteWritable`). Guards added in `addReplyToNoteLink` (reply.go, by link) and `addEmote` (emote.go, by note+user) → `403` when read-only.
   - **Scope decision:** guarded the genuine user writes (reply, emote). NOT guarded: `catchReaction` (dominated by passive telemetry — read-detect/eyeball/visibility — which should still fire on a still-viewable archived note), `setupBulkNewNoteReactions` (system setup at send; never archived), and `logReplyResponse`/async email-reply ingestion (no note/user at entry — a follow-up if inbound email replies to archived notes must be blocked).
   - Verified: all three modules build clean; both writability queries `EXPLAIN`-valid against live `sr_notes`; link read-only truth table (f/f/t + unknown→writable) confirmed in a rolled-back txn; RS-NOTES route registration test passed (no gin conflict across all new routes).
6. ✅ Remove legacy `GET /note/id/:id/status/:status` — DONE.
   - Removed the route (`server.go`), the `updateNoteStatus` handler (`note.go`), and the blacklist regex (`userauth/authentication.go`).
   - Kept `db.PGXUpdateStatus` — still used by `pkg/services/notes_processing.go` to set notes "active".
   - Verified: builds clean; grep confirms route/handler/blacklist gone.
7. ✅ Tests — DONE.
   - RS-NOTES `pkg/web/archive_routes_test.go`: asserts the 4 archive/writability routes register (no gin conflict) AND the legacy status route is removed.
   - RS-RESPONSES `pkg/client/notewritable_test.go`: 8 cases covering `noteWritable` fail-open semantics (nil/empty/non-bool → writable; writable precedence over read_only).
   - ORCHESTRATOR `pkg/clients/archiveresult_test.go`: `archiveResultFromResponse` field mapping, error surfacing, changed=false, nil fallback.
   - All pass (run via Go 1.24 + each module's `.env.test`).
   - Note: read-only DB derivation (per-user hide, single/cross-group, link variant) was validated functionally via rolled-back-txn SQL tests during steps 3 & 5; a Go DB-integration harness (TestMain + isolated test DB) is not yet set up in RS-NOTES — a candidate follow-up to convert those into committed `_test.go` DB tests.

---

## 10. Decisions

Resolved:
- **(R1) Cross-group read-only rule — CONFIRMED.** §1 stands: an inbox copy goes read-only only once *every* group context that delivered the note to that user is archived; one remaining active context keeps it writable.
- **(R2) Subgroup auth — RESOLVED.** Authorization is the direct leader check (`lead`/`creator`) on the exact `groupKey` the note was delivered to. A parent-group leader can archive a subgroup's note **only if they are also a leader of that subgroup** — no `parent_role` path. (See §3.2.)
- **(R3) All members get a `user_note` copy at send — CONFIRMED.** So the Op-2 read-only state reaches every group-A member immediately; no "interact first" edge case.
- **(R4) Legacy `GET /note/id/:id/status/:status` — SAFE TO REMOVE.** Only references are inside RS-NOTES (route/handler/DB fn) plus a `RequestBlackList` regex at `pkg/userauth/authentication.go:57` that already blocks it; no other module calls it (RS-RESPONSES uses `/note/id/.../activity/...`). When removing the route, also delete that blacklist entry.

- **(R5) Writable surface — RESOLVED.** No note-content edit endpoint exists. The only post-send writes are RS-RESPONSES replies, emotes, and reactions (enumerated in §6); those are the complete guard targets.

- **(O1) Write-guard placement — DECIDED: RS-RESPONSES.** Enforce read-only server-side in the RS-RESPONSES write endpoints (§6), so it holds even for direct callers.

---

## 11. Follow-ups (TODO)

- **Strip the orchestrator `archiveNote*` mutations.** The frontend writes go REST-direct to RS-NOTES via capability keys (GraphQL is read-only here), so `archiveNoteInInbox` / `archiveNoteForGroup` are dead. They also now point at the **removed** id-based RS-NOTES routes, so they would 404 if ever called (harmless — nothing calls them). Stripping them requires regenerating gqlgen, which is **blocked**: the main caching-refactor merge bumped `rootshoots-utils` to require go ≥ 1.24.1, but the vendored gqlgen 0.14.0's `x/tools` panics on go-1.24 export data. Fix = upgrade gqlgen (0.14 → 0.17+) and regenerate — its own focused task (regenerates all of `generated.go`, may change resolver signatures). Keep `Note.readOnly` (still used by reads).
- **RS-NOTES DB-integration tests.** Convert the rolled-back-txn SQL validations (read-only derivation, cap-key resolution) into committed `_test.go` tests once a `TestMain` + isolated-test-DB harness is set up in RS-NOTES (see RS-USERS/pkg/db/main_test.go for the reference pattern).

## 12. Final endpoint reference (RS-NOTES, :2000 — browser-direct, cap-key auth)

```
GET /note/link/:userCapKey/inbox/archive/:archived     # Op 1 personal: strict user_note key, self-authorizing
GET /note/link/:groupCapKey/group/archive/:archived    # Op 2 leader: key proves participation; lead/creator checked via Groups
GET /note/link/:link/writable                          # writability by cap key (used by RS-RESPONSES guard)
GET /note/id/:id/writable/user/:userKey                # writability by id+user (used by RS-RESPONSES addEmote guard)
```
:archived = true|false. Errors (400/403/404) carry Access-Control-Allow-Origin. 200 body: { error, message, archived, changed, [group_key] }.
