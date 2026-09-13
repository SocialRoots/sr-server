# 0003: API routing: move from server/api subroutes to a dedicated api.server subdomain

**Status:** Open
**Priority:** Medium
**Area:** Infrastructure / edge routing (docker-compose-traefik.yml, service API_BASE env vars)

## Problem

Every public frontend on an sr-server host currently reaches the API through a
**host-relative subroute**: Traefik routes `<host>/api/*` to the orchestrator's
`sr-orc` service. This entangles the API with its clients in three ways:

- **No access boundary.** The API lives inside the client's origin: same
  cookies, no CORS, no host-level assertion — any XSS in a client is full API
  access. There is nothing that says *what* a client may reach and *where* the
  API actually is; we depend on the client's good behavior.
- **Per-service, per-host routing.** One API router per subdomain, and because
  label-defined services are scoped to their own container (a router on one
  container cannot resolve `sr-orc@docker` from another — observed), every
  API router must live on the orchestrator's labels. Redeploys flap
  cross-container routers until their own container is re-emitted (observed on
  alpha: `web.<host>/api/*` served the SPA fallback until sr-web restarted).
- The GraphQL edge route (`/query` → `sr-orc-query`) is the same class of
  orchestrator-coupled edge and is being retired with GraphQL.

## Goal

A dedicated API origin — `api.<host>` — where the boundary between the API
server and its clients is explicit:

- **One router** on the orchestrator container: `Host(api.${SR_PUBLIC_HOST})`
  → `sr-orc` (intra-container reference, no per-host rules).
- **Prefix-free public API.** Clients call `https://api.<host>/notes/...`;
  a Traefik PathRewrite (v3) maps it to `/api/notes/...` internally, so the
  orchestrator contract is unchanged — during the transition and after.
  Dropping the prefix is an edge rewrite, not a protocol change.
- **All clients** (sr-next, sr-web — which moves into the main deploy cycle,
  see below) point one env var at the API origin.

## Client access model — decision required first

Who talks to `api.<host>`?

- **Browser-direct** (sr-web's current model): config.js → `api.<host>`.
  Real browser-level separation, but CORS is load-bearing and the session
  cookie becomes a cross-origin credential — new auth surface.
- **Client-proxied** (sr-next's BFF model): browser → client → `api.<host>`.
  No CORS, no cookie change, but the separation is architectural only.

The two clients currently embody both models. The move forces the choice; it
shapes the CORS, cookie, and allow-list work below.

## Migration checklist

1. DNS record for `api.<host>` (or wildcard) — required before ACME.
2. TLS cert for the new host via the existing certresolver.
3. Router + PathRewrite on the orchestrator; `API_BASE=https://api.<host>`
   in the traefik overlay (overriding the base default).
4. CORS on the orchestrator for each app origin (allow-listed) and session
   handling per the access-model decision above.
5. **Non-client caller:** the inbound email webhook (`/api/email/*`,
   called by Mailgun) — re-point the provider-side URL; it does not move
   for free with the clients.
6. Retire the per-host API subroutes and `/query` from the overlay once
   nothing references them.

## Related: consolidate sr-web into the main deploy cycle

sr-web will replace sr-next; it should deploy with the main stack, not as a
separate sidecar. Move it into `docker-compose.yml` (image + API_BASE env) +
`docker-compose-traefik.yml` (labels/networks), delete
`docker-compose.sr-web.yml`, and until `api.<host>` is live, keep the
transitional `web.<host>/api` router on the orchestrator's labels
(intra-container service ref).

## References

- Alpha symptom: `web.alpha.socialroots.io/api/*` served the SPA fallback
  (nginx `text/html`) — `sr-web-api` router dropped.
- Traefik logs: `ERR error="the service \"sr-orc@docker\" does not exist"
  routerName=sr-web-api@docker`.