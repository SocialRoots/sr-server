# AGENTS.md

This file provides guidance to AI coding assistants when working with code in this repository.

## Architecture Overview

SR-Server is a microservices-based social platform built with Go and Docker. The system consists of:

- **ORCHESTRATOR**: GraphQL API gateway that coordinates all microservices, handles authentication, and provides unified access
- **RS-USERS**: User management, authentication, and profile services
- **RS-GROUPS**: Group creation, membership management, and group-based permissions
- **RS-NOTES**: Note creation, messaging, and content management with email templating
- **RS-RESPONSES**: Response tracking, reactions, and reply management
- **RS-NOTIFICATIONS**: Notification aggregation — digests (cron), in-app state (touch/volume/mentions)
- **SR-EMAIL**: Email module — inbound Mailgun webhooks + reply parsing today; outbound (templates + SMTP from RS-NOTES `pkg/mailer`) is being consolidated here
- **RS-CONNECTIONS**: User connections and relationship management

Each microservice is a separate Go module with its own database, migrations, and API endpoints. Services communicate via HTTP APIs and share data through PostgreSQL databases and Redis caching.

### Shared Libraries

- **RS-UTILS** (`modules/RS-UTILS`): Shared utilities library providing common functionality across microservices including Nostr identity management, key generation, password hashing, storage interfaces, and the shared **authz** layer (membership lookups, roles, identity middleware). Used as a local dependency by other services to eliminate code duplication.

## Common Development Commands

### Environment Setup
```bash
# Load git submodules
git submodule update --init --recursive

# Set up databases (requires PostgreSQL running)
chmod +x bin/init-db.sh
./bin/init-db.sh
```

### Docker Operations
```bash
# Start PostgreSQL and Redis
docker-compose --env-file .env up postgres redis

# Start specific service (rebuild if code changed)
docker-compose --env-file .env up [SERVICE_NAME] --build

# Available services: orchestrator, rs-users, rs-groups, rs-connections, rs-notes, rs-notifications, rs-responses
```

### Database Management
```bash
# Run migrations for a specific module
cd modules/[MODULE_NAME]
./scripts/migrate.sh migrate

# Available modules: RS-USERS, RS-GROUPS, RS-NOTES, RS-RESPONSES, RS-NOTIFICATIONS, RS-CONNECTIONS
```

### Testing
```bash
# Run tests for a specific module
cd modules/[MODULE_NAME]
./scripts/test.sh

# Run specific test package
./scripts/test.sh [package_path]

# Test with race condition detection
./scripts/test_data_race.sh
```

### Service-Specific Commands
```bash
# Generate GraphQL code (ORCHESTRATOR only)
cd modules/ORCHESTRATOR
go run scripts/gqlgen.go

# Run individual Go commands in module context
cd modules/[MODULE_NAME]
go run cmd/web/main.go  # Start web server
go run cmd/script/main.go  # Run utility scripts
```

## Key Technical Details

### Service Communication
- ORCHESTRATOR runs on port defined by `ROOTSHOOT_ORCHESTRATOR_PORT`
- Each microservice exposes HTTP APIs on dedicated ports
- Services use internal Docker network (`sr-network`) for communication
- Service URLs follow pattern: `http://sr-rs-[service]:${PORT}`

### Database Structure
- Each service has its own PostgreSQL database
- Database names follow pattern: `DB_NAME_[SERVICE]` environment variable
- Migrations use `shmig` tool and are located in `db/migrations/` directories
- All services share connection to Redis for caching

### Configuration Management
- Main `.env` file contains shared configuration
- Each module has its own `.env` for service-specific settings
- Docker Compose uses environment variable substitution
- Database and Redis connections configured via environment variables

### Code Organization
- `/pkg/` contains business logic, database access, and service clients
- `/cmd/` contains application entry points (web servers, scripts, utilities)
- `/db/migrations/` contains SQL migration files
- `/scripts/` contains utility scripts for testing and database management
- `/settings/` contains configuration and service initialization

### Shared Library Integration
- **RS-UTILS** library is referenced as a local dependency using Go replace directives
- Microservices use `replace github.com/SocialRoots/rootshoots-utils => ../RS-UTILS` in go.mod
- Library provides common functionality: Nostr identity management, UUID key generation, password hashing, storage interfaces
- **`authz` is the security core**: membership lookups, role hierarchy, `RequireGroupMember`, `FilterActiveGroupKeys`, `FilterGroupContacts`, identity middleware (`ginmw`) — all authz decisions live here, never in handlers
- Eliminates code duplication and ensures consistent behavior across services

### Testing Framework
- Standard Go `testing` package (no Ginkgo/Gomega)
- Tests run with race condition detection enabled (`scripts/test_data_race.sh`)
- Test databases configured via `.env.test` files
- Each test package provisions its own isolated database via a `TestMain` that calls `utilsdb.SetupTestDB` (see `RS-USERS/pkg/db/main_test.go`) — this replaces the legacy `db.TestDB` / `x-socialroots-testmode` mechanism
- Integration tests communicate with other services via HTTP clients

### Testing Best Practices
- **IMPORTANT**: Tests use a dedicated test DATABASE (`rootshoot-tests`), NOT `_test` suffixed tables
- Do NOT use `TestCk()` or similar table suffix functions in tests - use the main table names
- The `.env.test` file points to the test database, so migrations create tables with normal names there
- **Test file organization**: name test files after the surface they cover, not the implementation file
  (e.g. `groupsinfo_test.go` for `GET /groups/info`, not `handlers_test.go`). Shared test helpers live in
  `pkg/dbtest/`; package-internal shared helpers live in `helpers_test.go`.
- **Batch endpoints**: when a batch endpoint may omit requested keys (authz filter, not-found), the response
  must include the omitted keys explicitly (e.g. `dropped: [...]`) so callers can distinguish "intentionally
  filtered" from a server error.
- **IMPORTANT**: The test database is shared across modules. Before running migrations for a module, you must reset the database:
  ```bash
  PGPASSWORD='th15.R00TZ' psql -U socialroots -h localhost -d rootshoot-tests -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO socialroots;"
  ```
- Then run migrations: `set -a && source .env.test && set +a && ./scripts/migrate.sh migrate`
- To run tests: `set -a && source .env.test && set +a && go test -v ./pkg/db`

### Security & Authentication

**The public API is migrating from GraphQL to spec-first OpenAPI (REST).
When the move finishes, the GraphQL layer is removed.** New endpoints are
spec-first (`pkg/api/openapi.yml`); legacy routes stay until migrated.

- **ORCHESTRATOR is the only edge.** All traffic goes through it:
  - `routeMap` forwards `/api/{service}/*` to the backend microservice
  - `publicPrefixes` (`pkg/auth/auth.go`) whitelists pre-auth paths and why:
    `/user/login`, `/user/authenticate/`, `/user/register/`, the capKey
    exchange, and each module's `/openapi.json`
  - `denyList` returns `410 Gone` for deprecated endpoints
- **Identity chain.** `ginmw.IdentityMiddleware` reads the user-key header →
  `ginmw.RequireUserSession` validates the session token → the handler reads
  the identity from `httpclient.UserKeyFromCtx`. Never trust a user key that
  did not come from ctx; batch endpoints re-check authz per key.
- **Session model.** Magic-link and register keys are one-time (deleted on
  use); auth sessions are rows upserted into the users DB; the returned
  `session_token` is cached in Redis (`session:<token>`) for fast
  orchestrator validation; the JWT carries the auth token as a claim.
- **Authz decisions live in `utils.authz` only** (`RequireGroupMember`,
  `FilterActiveGroupKeys`, `FilterGroupContacts`, `ConfigureMembershipLookup`).
  Handlers must not hand-roll membership SQL; configure a resolver (direct
  DB or HTTP) at startup instead.
- **Info-leak discipline.** Expose resource keys (`keys.MakeKey()`), never
  table PKs or emails; silent authz drops are reported explicitly
  (`dropped: [...]`); OpenAPI descriptions are consumer-facing and must not
  leak internals (locker items, table names); examples use realistic values.
- **Test-mode is deprecated / slated for removal.** `x-socialroots-testmode`
  header + `db.TestDB` is a legacy backdoor that must never be reachable in
  production; per-package `utilsdb.SetupTestDB` replaces it.
- Services validate requests through user tokens and service keys
- Database connections use dedicated PostgreSQL users
- Service-to-service communication secured within Docker network

### Monitoring & Caching
- Redis used for operation caching and performance optimization
- Profiling can be enabled via `PROFILING_ENABLED` environment variable
- Health check endpoints available on all services
- Slack notifications configured for monitoring alerts

## Working with Git Submodules

Each service module is a git submodule. When making changes:

1. Make changes within the specific module directory
2. Commit changes within the module (creates commit in submodule repo)
3. Commit the submodule reference update in the main repo
4. Use `git submodule update --remote` to pull latest changes from all submodules

## Filing Design Issues

Design discussions and proposals (e.g. new features, architectural changes) are captured as markdown files in `issues/` directories within each module, not GitHub Issues. This keeps design context co-located with the code.

### Convention

- **Location:** `modules/[MODULE_NAME]/issues/`
- **Filename:** `<numbered-prefix>-<kebab-case-slug>.md`
  - Prefix: zero-padded four digits (`0001`, `0002`, …). Next available number.
  - Slug: descriptive, kebab-case (e.g. `email-change-feature`).
- **Structure:** Sections with `##` headings. Common sections include:
  - `Summary` — what the issue proposes in 2-3 sentences
  - `Background` — context: schemas, code paths, constraints discovered during research
  - `Proposed flow` — step-by-step, often with a sequence diagram
  - `Data structures` — new or changed types, functions, DB columns
  - `API surface` — new endpoints, GraphQL mutations
  - `Security` — risks and mitigations
  - `Implementation order` — phased breakdown
  - `Test strategy` — unit, handler, integration tests
  - `Open questions` — unresolved design decisions
  - `Out of scope` — things explicitly not being addressed

### When to file

- After a design discussion where the path forward is clear but not yet implemented
- When research reveals a cross-module impact that needs documentation
- Before starting implementation of a non-trivial feature

### Examples

- `modules/ORCHESTRATOR/issues/0002-divergent-locatenotes-paths.md`
- `modules/RS-USERS/issues/0001-email-change-feature.md`

## OpenAPI-Based Public API

New public-facing REST endpoints are designed spec-first using OpenAPI 3.0.
The spec is the source of truth — Go types and server stubs are generated
from it, not written by hand.

### Where to find it

- **Spec:** `pkg/api/openapi.yml` in each microservice module
- **Generated code:** `pkg/api/server.gen.go` (check into repo, not .gitignore)
- **Manual handler:** `pkg/api/handlers.go` (implements the generated `ServerInterface`)

### Design principles

1. **Server owns resources, client owns views.** Endpoints return lean entities
   with key references, not embedded objects. The client composes higher-level
   views via batch endpoints.

2. **No locker contents.** Each endpoint returns only what its service owns.
   User profiles, group info, and per-user state are fetched separately via
   batch endpoints (`/users/batch`, `/groups/batch`, `/response/batch/note-stats`).

3. **Expose resource keys, never table PKs.** The integer `notes.id` / `users.id`
   are internal serial keys and must not leak to clients. Notes use their own
   non-enumerable key (`notes.link`, `keys.MakeKey()`) as the canonical
   external identifier; list responses carry key references, and the client
   opens detail (`GET /notes/{noteKey}`, `GET /notes/cap/{capKey}`) — not the
   integer id. Authz is checked at the detail endpoint.

4. **Authz is enforced in the handler, via `utils.authz`.** The generated Gin
   router (`RegisterHandlers`) is a mechanical byproduct of `openapi.yml` and
   must NOT be the source of truth for routes. `RegisterPublicAPI` wires:
   openapi.json route (public) → `ginmw.IdentityMiddleware` →
   `ginmw.RequireUserSession` → `RegisterHandlers(router, h)`. Each handler
   then re-checks its per-endpoint rule with `utils.authz`
   (`RequireGroupMember`, `FilterActiveGroupKeys`, `FilterGroupContacts`, …)
   reading identity from ctx. This replaces the old per-route GOPS
   middleware-table style; all modules use the same pattern once migrated to
   OpenAPI.

### Code generation

```bash
# Install the generator (once)
go install github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@latest

# Regenerate from the spec
cd modules/[MODULE_NAME]
./scripts/generate-api.sh
```

The generated file is checked into the repo so builds don't require the
generator tooling. The `scripts/generate-api.sh` script exists in each
module that has an OpenAPI spec.

### OpenAPI gotchas (learned the hard way)

- **Each module's `/openapi.json` needs an orchestrator `publicPrefixes`
  entry** — otherwise the spec is 401 from outside. Add it when a module
  first exposes an OpenAPI surface (RESPONSES and GROUPS both hit this).
- **First regen also needs `oapi-codegen/runtime` + `yaml.v3` in go.mod**
  plus `go mod vendor` — the generated `server.gen.go` won't build in
  vendor mode without them.
- **Spec descriptions are a public contract** — consumer-facing only; no
  internals (locker items, table origins). Examples must be realistic
  (32-char hex keys from `keys.MakeKey()`), not placeholder slugs.
- **Test files follow the surface they cover** (`groupsinfo_test.go`), not
  `handlers_test.go`; shared helpers live in `pkg/dbtest/`.

### Migration status

- **Live OpenAPI surfaces** (each has a generated `server.gen.go`, handler
  tests, and a public spec JSON):
  - USERS `/users/profiles`
  - GROUPS `/groups/info`
  - RESPONSES `/responses/status`
  - NOTES `/notes/{noteKey}` (detail), `/notes/user/{userKey}` (list),
    `/notes/group/{groupKey}` (group list)
- **Planned**: USERS login (`/users/login` + magic-key redeem), RESPONSES
  batch stats, later mutations/cap routes.
- **End state**: GraphQL layer in ORCHESTRATOR is removed once all
  migrated endpoints have REST equivalents.