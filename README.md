# SR-SERVER

This repository is intended as an easy way to bootstrap a full Socialroots 
server. It uses Docker and Compose to start all the needed components:

  - NginX as an HTTP proxy
  - Postgres database
  - Redis cache database
  - Minio S3 storage provider
  - SR Orchestrator
  - SR Users microservice
  - SR Groups microservice
  - SR Notifications microservice
  - SR Connections microservice
  - SR-Email — the email module: inbound (Mailgun webhooks → reply parsing →
    inbox) today; outbound (templates + SMTP) is being consolidated into it
  - SR Utils (a shared library with commonly used stuff, including the shared
    authz layer)

(*) Obs: All SR services are added as Git Submodules.

**Note:** Some modules referenced as submodules are not yet publicly available. We are open-sourcing the project incrementally.

## Directory structure

  - `.`: The most relevant files in the home directory are the 
    `docker-compose` and the `.env` which are used to configure and start 
    the server.
  - `data`: all the services in the server are configured to store and log 
    relevant information inside the `data` directory
  - `modules`: where all the git submodules are cloned into.

## How to get it running?

### Requirements

  - You need to have **Docker** and **docker-compose** installed and 
    accessible by the user that is running the commands below;
  - You need to have **git** and the Postgresql client **psql** available 
    on your path;

### Steps

  1. Cloning this repository and get inside its directory using a terminal;
  2. Then, load all the submodules by executing `git submodule update --init`;
  3. Bootstrap a brand-new database:
     1. start the Postgres server: `docker-compose --env-file .env up postgres -d`
     2. create the Socialroots databases: `./bin/init-db.sh` *(you may need to
        add execution permissions to the bash script first: `chmod +x bin/init-db.sh`)*
  4. Start the services: `docker-compose --env-file .env up NAME_OF_SERVICE 
  [--build] [-d]` 
     1. ... where `--build` is only needed if you want to rebuild the image in case you 
        made changes to the code and `-d` if you want the container to execute in detached mode.*
     2. ... you can add all the services in a single command call
     3. **The services available are:**
        1. redis
        2. minio-init
        3. orchestrator
        4. rs-users
        5. rs-groups
        6. rs-connections
        7. rs-notes
        8. rs-notifications
        9. rs-responses
       10. sr-email

  5. Configure name resolving of your computer to see the services by name.
     (There are many ways to do that, and this is the easiest one for Linux/MaxOS)

     Edit the `/etc/hosts` file to ADD the lines to point to `127.0.0.1`:
```
     127.0.0.1 sr-postgres
     127.0.0.1 sr-redis
     127.0.0.1 sr-s3-minio
     127.0.0.1 sr-orchestrator
     127.0.0.1 sr-rs-users
     127.0.0.1 sr-rs-groups
     127.0.0.1 sr-rs-connections
     127.0.0.1 sr-rs-notes
     127.0.0.1 sr-rs-notifications
     127.0.0.1 sr-rs-responses
     127.0.0.1 sr-email
```

### Observations

The configuration of all these services are made through the `.env` file and 
the default configuration is focused on a development environment, so, you
will need to adjust it accordingly.

- **S3-minio:** You want to be thoughtful about the host URL you configure
  as the uploaded files will be saved to the database pointing to that URL.
  The best case scenario here is that you will have a permanent, public 
  facing name (like https://images.socialroots.io).

## Public API

The public API is **migrating from GraphQL to a spec-first OpenAPI (REST)
surface**. New endpoints are designed in each microservice's
`pkg/api/openapi.yml` (the spec is the source of truth; Go types are
generated). **When the migration is complete, the GraphQL layer is
removed.**

- All traffic flows through the ORCHESTRATOR: `/api/{service}/*` is
  forwarded to the backend microservice (see `routeMap` in
  `modules/ORCHESTRATOR/pkg/api/api.go`).
- Live specs (public, no auth needed):
  - `/api/users/openapi.json`
  - `/api/groups/openapi.json`
  - `/api/responses/openapi.json`
  - `/api/notes/openapi.json`
- Auth: login/register exchanges a one-time magic key for a `session_token`
  (JWT + Redis session cache); subsequent requests send it as a bearer
  token. Pre-auth paths (login, register, capKey exchange, spec files) are
  whitelisted in `publicPrefixes` in
  `modules/ORCHESTRATOR/pkg/auth/auth.go`.

## Deprecating an HTTP endpoint

When an endpoint has no remaining callers (verified by grepping `sr-server`,
`sr-next`, `sr-client`, including dynamically-built URLs), retire it in
small reversible steps so unknown callers (admin tools, ops scripts) surface
loudly rather than break silently:

1. **Block at the orchestrator proxy** — add a row to `denyList` in
   `modules/ORCHESTRATOR/pkg/api/api.go` (returns `410 Gone` before
   forwarding). Reverse with one comment if needed.
2. **Mark the handler in the owning microservice** with a `// Deprecated:`
   Godoc comment plus a `log.Printf("[DEPRECATED-HANDLER] ...")` line at
   the top of the function body. The Godoc tag triggers `gopls`/
   `staticcheck` warnings on any caller; the log line catches direct
   internal-network hits the proxy can't see.
3. **Annotate frontend wrappers** (e.g. in `sr-client`) with `@deprecated`
   JSDoc so editors flag new uses.
4. **Bake.** Grep `[DEPRECATED-HANDLER]` in service logs over a deprecation
   window. If zero hits, replace the handler body with a `c.JSON(410, ...)`
   response (defense-in-depth).
5. **Bake again.** If still no breakage reports, remove the route
   registration in `server.go`.
6. **Delete the handler function.**

The greppable tags (`Deprecated:`, `[DEPRECATED-HANDLER]`, `denyList`,
`@deprecated`) make each cleanup sweep mechanical.
