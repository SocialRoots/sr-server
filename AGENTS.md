# AGENTS.md

This file provides guidance to AI coding assistants when working with code in this repository.

## Architecture Overview

SR-Server is a microservices-based social platform built with Go and Docker. The system consists of:

- **ORCHESTRATOR**: GraphQL API gateway that coordinates all microservices, handles authentication, and provides unified access
- **RS-USERS**: User management, authentication, and profile services
- **RS-GROUPS**: Group creation, membership management, and group-based permissions
- **RS-NOTES**: Note creation, messaging, and content management with email templating
- **RS-RESPONSES**: Response tracking, reactions, and reply management
- **RS-NOTIFICATIONS**: Notification delivery, summaries, and in-app notifications
- **RS-CONNECTIONS**: User connections and relationship management

Each microservice is a separate Go module with its own database, migrations, and API endpoints. Services communicate via HTTP APIs and share data through PostgreSQL databases and Redis caching.

### Shared Libraries

- **RS-UTILS** (`modules/RS-UTILS`): Shared utilities library providing common functionality across microservices including Nostr identity management, key generation, password hashing, and storage interfaces. Used as a local dependency by other services to eliminate code duplication.

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
- Microservices use `replace github.com/SocialRoots/sr-microservices-utils => ../RS-UTILS` in go.mod
- Library provides common functionality: Nostr identity management, UUID key generation, password hashing, storage interfaces
- Eliminates code duplication and ensures consistent behavior across services

### Testing Framework
- Uses Ginkgo BDD testing framework with Gomega matchers
- Tests run with race condition detection enabled
- Test databases configured via `.env.test` files
- Integration tests communicate with other services via HTTP clients

### Testing Best Practices
- **IMPORTANT**: Tests use a dedicated test DATABASE (`rootshoot-tests`), NOT `_test` suffixed tables
- Do NOT use `TestCk()` or similar table suffix functions in tests - use the main table names
- The `.env.test` file points to the test database, so migrations create tables with normal names there
- **IMPORTANT**: The test database is shared across modules. Before running migrations for a module, you must reset the database:
  ```bash
  PGPASSWORD='th15.R00TZ' psql -U socialroots -h localhost -d rootshoot-tests -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO socialroots;"
  ```
- Then run migrations: `set -a && source .env.test && set +a && ./scripts/migrate.sh migrate`
- To run tests: `set -a && source .env.test && set +a && go test -v ./pkg/db`

### Security & Authentication
- ORCHESTRATOR handles authentication and authorization
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

3. **No capability keys in list responses.** The client opens a note by its
   stable `id`; the server checks authz at the detail endpoint.

4. **Authz follows the RS-GROUPS pattern.** IdentityMiddleware reads
   `X-User-Key` header (set by orchestrator), per-route middleware gates
   access (`requireSelf`, `requireAuth`), handler-level checks enforce
   fine-grained rules.

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