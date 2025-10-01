# GraphQL Performance Profiling Guide

## Overview

The Orchestrator includes a built-in profiling system to track GraphQL query performance and identify bottlenecks. This guide explains how to enable profiling and interpret the results.

## Enabling Profiling

### 1. Enable in Environment Variables

Edit `.env` file:

```bash
PROFILING_ENABLED=true
```

### 2. Restart the Orchestrator

```bash
docker-compose --env-file .env up orchestrator --build
```

Or if running locally:
```bash
cd modules/ORCHESTRATOR
go run cmd/web/main.go
```

## Understanding the Output

When profiling is enabled, each GraphQL query will log detailed performance metrics:

### Example Output

```
========================================
GraphQL Operation Started: GetUserNotes
Query: query GetUserNotes { ... }
========================================

========================================
✅ GraphQL Operation: GetUserNotes
========================================
📊 Request Summary:
   • GET Requests:  12
   • POST Requests: 2
   • Total Requests: 14
📦 Cache Performance:
   • Cache Hits:   8 (57.1%)
   • Cache Misses: 6
⏱️  Endpoint Performance:
   🔴 GET:/note/user/abc123
      Calls: 5 | Total: 1500ms | Avg: 300ms
   🟡 GET:/group/xyz789
      Calls: 3 | Total: 450ms | Avg: 150ms
      GET:/user/key/def456
      Calls: 4 | Total: 200ms | Avg: 50ms
⏰ Total Query Time: 2150ms
========================================
```

### Performance Indicators

- **✅ (Green)**: Query completed in < 500ms (Good performance)
- **🟡 MODERATE**: Query took 500-1000ms (Acceptable, but watch for trends)
- **🔴 SLOW**: Query took > 1000ms (Needs optimization)

### Endpoint Performance Icons

- **🔴 (Red endpoint)**: Average response time > 200ms (Critical - N+1 query likely)
- **🟡 (Yellow endpoint)**: Average response time > 100ms (Watch for optimization opportunities)
- **No icon**: Average response time < 100ms (Good)

## Common Performance Issues

### 1. High Number of Requests (N+1 Queries)

**Symptom**: 50+ requests for a single GraphQL query

**Example**:
```
📊 Request Summary:
   • Total Requests: 75
   🔴 GET:/user/key/...
      Calls: 50 | Total: 5000ms | Avg: 100ms
```

**Cause**: Looping through entities and making individual calls instead of using bulk endpoints.

**Solution**: Use batch loading or DataLoader pattern (see optimization guide).

### 2. Low Cache Hit Rate

**Symptom**: Cache hit rate < 30%

**Example**:
```
📦 Cache Performance:
   • Cache Hits:   5 (10.0%)
   • Cache Misses: 45
```

**Cause**:
- `noCache: true` parameter in GraphQL query
- `DISABLE_CACHE=true` in environment
- Redis connection issues
- Unique query parameters preventing cache reuse

**Solution**:
- Remove `noCache` parameter unless debugging
- Ensure Redis is running: `docker-compose up redis`
- Check Redis connection in logs

### 3. Slow Individual Endpoints

**Symptom**: Single endpoint with very high average time

**Example**:
```
🔴 GET:/note/user/abc123/full
   Calls: 1 | Total: 3000ms | Avg: 3000ms
```

**Cause**:
- Database query not optimized
- Missing indexes
- Over-fetching data
- Slow microservice response

**Solution**:
- Check microservice logs for the slow endpoint
- Review database query performance
- Consider pagination or field selection

## Profiling Best Practices

### 1. Testing in Development

Always enable profiling in development to catch issues early:

```bash
# .env
ENV=development
LOCALENV=true
PROFILING_ENABLED=true
DISABLE_CACHE=true  # For accurate testing
```

### 2. Production Monitoring

In production, enable profiling selectively or with sampling:

```bash
# .env
ENV=production
PROFILING_ENABLED=true  # Consider adding log filtering
```

**Note**: Profiling adds minimal overhead (~5-10ms per query) but can increase log volume.

### 3. Comparing Performance

To compare before/after optimization:

1. Run query with profiling enabled
2. Save the output (copy from logs)
3. Make optimization changes
4. Rebuild: `docker-compose up orchestrator --build`
5. Run same query again
6. Compare metrics

## Interpreting Results for Common Queries

### User Query with Memberships

**Expected Performance**:
- Fast query (<100ms): 1-2 bulk requests for user + memberships
- Slow query (>500ms): Separate request per membership

**Good Pattern**:
```
📊 Request Summary:
   • Total Requests: 3
   GET:/user/key/abc123          | Calls: 1 | Avg: 50ms
   POST:/user/bulk/users         | Calls: 1 | Avg: 30ms
   GET:/group/user/abc123        | Calls: 1 | Avg: 40ms
⏰ Total Query Time: 120ms
```

**Bad Pattern (N+1)**:
```
📊 Request Summary:
   • Total Requests: 25
   GET:/user/key/abc123          | Calls: 1 | Avg: 50ms
   GET:/group/xyz1               | Calls: 1 | Avg: 80ms
   GET:/group/xyz2               | Calls: 1 | Avg: 85ms
   ... (20 more group calls)
⏰ Total Query Time: 1800ms
```

### Notes Query

**Expected Performance**:
- Fast query (<200ms): Bulk fetching of notes, users, groups
- Slow query (>1000ms): Individual queries per note

**Good Pattern**:
```
📊 Request Summary:
   • Total Requests: 5
   GET:/note/user/abc/group/xyz  | Calls: 1 | Avg: 100ms
   POST:/user/bulk/users         | Calls: 1 | Avg: 40ms
   GET:/group/groups/xyz1,xyz2   | Calls: 1 | Avg: 60ms
⏰ Total Query Time: 200ms
```

## Next Steps

After identifying slow queries using profiling:

1. **Document the issue**: Save the profiling output
2. **Analyze the pattern**: Identify N+1 queries or slow endpoints
3. **Check the microservice**: Look at logs for the slow microservice
4. **Implement fixes**: See optimization guides for common patterns
5. **Verify improvement**: Re-run with profiling and compare

## Troubleshooting

### Profiling Not Working

1. Check environment variable:
   ```bash
   docker-compose exec orchestrator env | grep PROFILING
   ```
   Should show: `PROFILING_ENABLED=true`

2. Check logs for startup message:
   ```
   ⚡ PROFILING ENABLED - Performance metrics will be logged
   ```

3. Rebuild container:
   ```bash
   docker-compose up orchestrator --build
   ```

### No Profiling Output for Query

- Ensure you're making a GraphQL query (not REST)
- Check that query reached the resolver (no early errors)
- Verify logs are not being filtered

### High Memory Usage with Profiling

Profiling stores request metadata in memory during query execution. For very long queries (1000+ requests), consider:
- Optimizing the query first
- Using pagination
- Temporarily disabling profiling for that specific query
