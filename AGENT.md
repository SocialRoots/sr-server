# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
chmod +x init-db.sh
./init-db.sh
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

## RS-UTILS Refactoring TODOs

The following code duplications have been identified across microservices and should be refactored into RS-UTILS. **MANDATORY PROCEDURE** for each refactoring:

1. **Add unit tests** to functions that USE the component being moved (in the original module)
2. **Move component** to RS-UTILS with appropriate package structure
3. **Create unit tests** for the moved component in RS-UTILS
4. **Verify** that tests in the original module (created in step 1) are still passing
5. **Update imports** in all affected services
6. **Run all service tests** to ensure no regressions

### Priority 1: Critical Duplications

####  TODO 1.1: Combined Redis and Cache Utilities
**Status**: Not Started
**Impact**: 465 lines duplicated across 7 services (315 Redis + 150 Cache Invalidation)
**Affected Services**: ALL (ORCHESTRATOR, RS-USERS, RS-GROUPS, RS-NOTES, RS-RESPONSES, RS-NOTIFICATIONS, RS-CONNECTIONS)

  Current Locations:
   - modules/RS-GROUPS/pkg/rdclient/client.go
   - modules/RS-USERS/pkg/rdclient/client.go
   - modules/RS-NOTIFICATIONS/pkg/rdclient/client.go
   - modules/RS-CONNECTIONS/pkg/rdclient/client.go
   - modules/RS-NOTES/pkg/rdclient/client.go
   - modules/RS-RESPONSES/pkg/rdclient/client.go
   - modules/ORCHESTRATOR/pkg/rdclient/client.go
   - modules/RS-GROUPS/pkg/cache/cacheupdater.go
   - modules/RS-USERS/pkg/cache/cacheupdater.go
   - modules/RS-NOTIFICATIONS/pkg/cache/cacheupdater.go
   - modules/RS-CONNECTIONS/pkg/cache/cacheupdater.go
   - modules/RS-NOTES/pkg/cache/cacheupdater.go
   - modules/RS-RESPONSES/pkg/cache/cacheupdater.go

  Target Location: modules/RS-UTILS/cache/cache.go

  Functions to Move:
   - GetClient() *redis.Client
   - SetKey(rdb *redis.Client, key string, value string) error
   - GetKey(rdb *redis.Client, key string) (string, error)
   - HashKeyFNV(key string) string
   - InvalidateByKey(service string, endpoint string, params ...string) error
   - InvalidateByPattern(pattern string) error
   - InvalidateMatchingKeys(matchPattern string) error
   - InvalidateAllKeys() error
   - BuildCacheKey(service string, endpoint string, params ...string) string
   - GetRedisClient() *redis.Client
   - GetCacheKeyHash(key string) string
   - InitCache(config CacheConfig) error
   - GetCacheConfig() CacheConfig

  Struct Definitions:

   1 type CacheConfig struct {
   2     Host     string
   3     Port     string
   4     Password string
   5     DB       int
   6     PoolSize int
   7 }

  Notes: 100% identical code. Must handle settings package dependency (pass config as parameter or use interface).

---

#### TODO 1.2: HTTP Service Client Utilities
**Status**: Not Started
**Impact**: 1,140 lines duplicated across 6 services
**Affected Services**: RS-USERS, RS-GROUPS, RS-NOTES, RS-NOTIFICATIONS, RS-CONNECTIONS, ORCHESTRATOR

**Current Locations**: `pkg/client/clientutilites.go` in each service

**Target Location**:
- `modules/RS-UTILS/client/http.go`
- `modules/RS-UTILS/client/service_discovery.go`

**Functions to Move**:
- `GetServiceHost(service string) string`
- `ConsumeGetEndpoint(endpoint string, service string) map[string]interface{}`
- `ConsumePostEndpoint(endpoint string, service string, sendBody interface{}) map[string]interface{}`
- `checkBypass(service string) bool`
- `srGet(endpoint string) (*http.Response, error)`
- `srPost(endpoint string, contentType string, body io.Reader) (*http.Response, error)`

**Global Variables**:
- `ForceInvalidation bool`
- `TestMode bool`

**Notes**: Must handle settings package dependency. Consider configuration injection pattern.

---

### Priority 2: Quick Wins (Already in RS-UTILS)

#### TODO 2.1: UUID Key Generator
**Status**: DONE
Summary of completed work:
- ✅ RS-CONNECTIONS: 4 usages migrated, 1 duplicate file removed
- ✅ RS-NOTIFICATIONS: 8 usages migrated, 1 duplicate file removed
- ✅ RS-USERS: 9 usages migrated, 2 duplicate files removed (keygenerator.go + MakeKey() in db.go)
- ✅ RS-GROUPS: 7 usages migrated, 1 duplicate file removed

**Total impact: ~26 usages migrated, ~78 lines of duplicate code eliminated across 4 modules!**

---

#### TODO 2.2: LockerItem Model
**Status**: Not Started
**Impact**: ~13 lines duplicated in 4 services
**Affected Services**: RS-GROUPS, RS-USERS, RS-CONNECTIONS, RS-NOTES

**Current Locations**:
- `modules/RS-GROUPS/pkg/models/lockeritem_model.go`
- `modules/RS-USERS/pkg/models/lockeritem_model.go`
- `modules/RS-CONNECTIONS/pkg/model/lockeritem_model.go`
- `modules/RS-NOTES/pkg/models/lockeritem_model.go`

**Already Exists**: `modules/RS-UTILS/models/locker.go` has `LockerItem` struct

**Action Required**:
1. Add tests to code using local `LockerItem` in each service
2. Reconcile minor field ordering differences (semantically identical)
3. Update imports to use `github.com/SocialRoots/sr-microservices-utils/models`
4. Remove local duplicates
5. Verify tests pass

---

### Priority 3: Low Impact / Easy Wins

#### TODO 3.1: HTTP Request Body Parser
**Status**: Not Started
**Impact**: ~20 lines duplicated in 2+ services
**Affected Services**: RS-GROUPS, RS-USERS, RS-CONNECTIONS (likely others)

**Current Locations**: `pkg/web/webcore.go` in multiple services

**Target Location**: `modules/RS-UTILS/web/utilities.go`

**Function**:
```go
func getPostData(c *gin.Context) map[string]interface{}
```

**Notes**: Near-identical implementation, only minor logging differences.

---

#### TODO 3.2: Health Check Handler
**Status**: Not Started
**Impact**: 11 lines duplicated across ALL services
**Affected Services**: ALL microservices

**Current Locations**: `pkg/web/health_check.go` in each service

**Target Location**: `modules/RS-UTILS/web/handlers.go`

**Function**:
```go
func HealthCheck(c *gin.Context) {
    c.JSON(200, gin.H{"message": "ok!"})
}
```

**Notes**: Exact duplication. Trivial to move but good for consistency.

---

### Recommended RS-UTILS Package Structure

After completing refactoring, RS-UTILS should have:

```
modules/RS-UTILS/
├── cache/
│   ├── cache.go              # Combined Redis and cache utilities (TODO 1.1)
│   ├── cache_test.go         # Tests for cache utilities
├── client/
│   ├── http.go               # HTTP client utilities (TODO 1.2)
│   ├── http_test.go          # Tests for HTTP client
│   ├── service_discovery.go  # GetServiceHost and related (TODO 1.2)
│   └── service_discovery_test.go
├── crypto/
│   ├── passwords.go          # ✓ Already exists
│   └── passwords_test.go     # ✓ Add if missing
├── keys/
│   ├── generator.go          # ✓ Already exists (TODO 2.1 - use it!)
│   └── generator_test.go     # ✓ Add if missing
├── models/
│   ├── locker.go             # ✓ Already exists (TODO 2.2 - use it!)
│   ├── locker_test.go        # ✓ Add if missing
│   └── interfaces.go         # ✓ Already exists
├── nostr/
│   └── ...                   # ✓ Already exists
└── web/
    ├── handlers.go           # Health check (TODO 4.2)
    ├── handlers_test.go      # Tests for handlers
    ├── utilities.go          # getPostData (TODO 4.1)
    └── utilities_test.go     # Tests for utilities
```

---

### Migration Tracking

Use this checklist format when working on each TODO:

- [ ] **TODO X.Y: [Component Name]**
  - [ ] Step 1: Add unit tests to functions using the component in original modules
  - [ ] Step 2: Move component to RS-UTILS with proper package structure
  - [ ] Step 3: Create unit tests for moved component in RS-UTILS
  - [ ] Step 4: Update imports in affected services
  - [ ] Step 5: Verify original module tests still pass
  - [ ] Step 6: Run full test suite for all affected services
  - [ ] Step 7: Update go.mod files if needed
  - [ ] Step 8: Document any breaking changes or migration notes

---

## Infrastructure & Deployment

### NGINX Configuration

**Current Setup**: Host NGINX proxies directly to Docker containers on localhost ports.

**Planned Enhancement - Two-Tier NGINX**:
- **Host NGINX**: Handles SSL termination, multiple domains, rate limiting, and forwards to Docker NGINX
- **Docker NGINX** (in docker-compose): Handles microservice routing, CORS headers, and load balancing
- Benefits: Easier local development, cleaner separation of concerns, portable configuration

**CORS Configuration**:
- Shared CORS config stored in `/etc/nginx/snippets/cors.conf`
- Handles preflight OPTIONS requests with 204 response
- Allows methods: GET, POST, PUT, DELETE, PATCH, OPTIONS
- Allows headers: x-socialroots-userauth, x-socialroots-testmode, Content-Type, Accept, Origin
- Included in each service location block with `include /etc/nginx/snippets/cors.conf;`

---

## Code Quality & Refactoring TODOs

### TODO: Refactor RS-NOTIFICATIONS Summary Processing Algorithm
**Status**: Not Started
**Priority**: High
**Impact**: Code maintainability, testability, debugging edge cases
**Location**: `modules/RS-NOTIFICATIONS/cmd/cron/notifications/summarynotifications.go`

**Current Issues**:
- The `SummaryNotifications()` function contains a massive 280+ line for-loop
- Multiple levels of nested logic make it difficult to understand and test
- Edge case debugging is difficult (stale data, missing users, network errors)
- No panic recovery means one bad summary can crash the entire cron job
- Difficult to unit test individual steps in isolation

**Proposed Refactoring**:

Break the monolithic loop into smaller, focused, testable functions:

1. **`processSummary(summary, config) (emailData, error)`**
   - Main orchestrator for processing a single summary
   - Handles panic recovery internally
   - Returns structured error types for better logging

2. **`validateSummaryReady(summary, currentTime) (bool, string)`**
   - Time-based filtering logic
   - Returns whether ready + reason for skip/process

3. **`applyCatchupLogic(summary, currentTime) Summary`**
   - Handles the "2x overdue" reset logic
   - Pure function, easy to test

4. **`gatherSummaryData(summary, timeWindow) (SummaryData, error)`**
   - Fetches all external data (users, notes, replies, invitations)
   - Centralizes all HTTP calls that could fail
   - Returns structured data or error

5. **`buildDailySummary(data) EmailSummaryData`**
   - Transforms raw data into daily email format
   - Pure function, no side effects

6. **`buildWeeklySummary(data) EmailSummaryData`**
   - Transforms raw data into weekly email format with group changes
   - Pure function, no side effects

7. **`shouldSendSummary(emailData, summaryType) bool`**
   - Determines if summary has enough content to send
   - Extracts the "has content" logic into testable function

8. **`sendAndUpdateSummary(emailData, summary, alterUpdate) error`**
   - Handles email sending and database timestamp update
   - Centralizes the send/update logic

**Benefits**:
- Each function can be unit tested independently
- Easier to add logging/metrics at each step
- Panic recovery can be added to individual steps
- Clearer separation of concerns (data gathering vs. formatting vs. sending)
- Easier to debug edge cases by testing functions in isolation
- Better error handling with structured error types

**Example Structure**:
```go
for _, summary := range checkSummaries {
    if err := processSummaryWithRecovery(summary, config); err != nil {
        log.Printf("Failed to process summary ID=%d: %v", summary.ID, err)
        continue // Don't crash the whole job
    }
}

func processSummaryWithRecovery(summary Summary, config Config) (err error) {
    defer func() {
        if r := recover(); r != nil {
            err = fmt.Errorf("panic: %v", r)
        }
    }()
    return processSummary(summary, config)
}

func processSummary(summary Summary, config Config) error {
    ready, reason := validateSummaryReady(summary, config.CurrentTime)
    if !ready {
        log.Printf("Skipping summary ID=%d: %s", summary.ID, reason)
        return nil
    }

    summary = applyCatchupLogic(summary, config.CurrentTime)

    data, err := gatherSummaryData(summary, config.TimeWindow)
    if err != nil {
        return fmt.Errorf("gather data: %w", err)
    }

    var emailData EmailSummaryData
    if summary.SummaryTemplate == "daily" {
        emailData = buildDailySummary(data)
    } else {
        emailData = buildWeeklySummary(data)
    }

    if !shouldSendSummary(emailData, summary.SummaryTemplate) {
        log.Printf("No content for summary ID=%d", summary.ID)
        return updateSummaryTimestamp(summary, config)
    }

    return sendAndUpdateSummary(emailData, summary, config)
}
```

**Testing Strategy**:
- Unit tests for each pure function (validate, catchup, build, shouldSend)
- Integration tests for data gathering (with mocked HTTP clients)
- End-to-end tests for full processSummary flow
- Edge case tests for panic scenarios

**Migration Path**:
1. Add comprehensive integration tests to current code
2. Extract one function at a time (start with pure functions)
3. Run tests after each extraction
4. Gradually build up the new structure
5. Switch to new implementation once all tests pass

---
