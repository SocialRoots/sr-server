# 0001: Env var duplication between S3_* and AWS_* in docker-compose.yml

**Status:** Open
**Priority:** Medium
**Area:** Deployment / docker-compose.yml

## Problem

`docker-compose.yml` defines the same values under two different namespaces:

```
# MinIO init (mc commands) reads these:
S3_ACCESS_KEY_ID: ${S3_ACCESS_KEY_ID}
S3_SECRET_ACCESS_KEY: ${S3_SECRET_ACCESS_KEY}
S3_HOST: ${S3_HOST}
MINIO_DEFAULT_BUCKET: ${MINIO_DEFAULT_BUCKET}

# Microservices (AWS SDK) read these — same values mapped again:
AWS_ACCESS_KEY_ID: ${S3_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY: ${S3_SECRET_ACCESS_KEY}
AWS_IMAGE_BUCKET_NAME: ${MINIO_DEFAULT_BUCKET}
AWS_S3_ENDPOINT: ${S3_HOST}
```

This is error-prone — if a new service needs S3 access, you have to remember to add both. If one mapping drifts, services break silently.

## Proposed solution

Pick one namespace. Either:

1. **Use `S3_*` everywhere** — rename the env vars the microservices read to use the `S3_*` naming, dropping `AWS_*` from the compose file entirely. Update each microservice's `settings/config.go` to read `S3_*` instead of `AWS_*`.

2. **Use `AWS_*` everywhere** — swap MinIO init to read `AWS_*` vars (via shell variable expansion in the command).

3. **Alias at image build** — add a thin wrapper script inside each microservice image that maps one namespace to the other, keeping the compose file clean.

Option 1 seems cleanest since we're not on real AWS — no point pretending.

## Files affected

- `docker-compose.yml` — lines 105-107, 132-136
- Each microservice's `settings/config.go` that reads `AWS_*` vars:
  - RS-GROUPS `settings/config.go` (`AwsS3Endpoint`, `AwsAccessKeyID`, etc.)
  - RS-USERS `settings/config.go`
  - (check others)
- MinIO init command block (lines 111-116, 120)

## Related

- Issue 0001 in RS-GROUPS (UploadImage returns 200 on S3 failure)
- PR that added `AwsS3Endpoint` to RS-GROUPS