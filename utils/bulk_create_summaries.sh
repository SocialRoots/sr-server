#!/bin/bash

# Bulk Summary Notifications Creator
# Reads user_keys from a file and creates daily + weekly summary notifications for each user
# Usage: ./bulk_create_summaries.sh --file <user_keys.txt> [options]

# Don't use set -e - we handle errors explicitly
set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEFAULT_DAILY_FREQUENCY=1440    # 24 hours in minutes
DEFAULT_WEEKLY_FREQUENCY=10080  # 7 days in minutes
DEFAULT_TIME="01:00:00 PST"   # 1 AM PST

# Print colored message
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 --file <user_keys.txt> --endpoint <url> --start-date <date> --daily-status <status> --weekly-status <status> [options]

Required Arguments:
  --file <path>              Path to file containing user_keys (one per line)
  --endpoint <url>           API endpoint URL (e.g., http://localhost:2100)
  --start-date <date>        Start date (format: YYYY-MM-DD)
  --daily-status <status>    Initial status for daily summaries (active/inactive)
  --weekly-status <status>   Initial status for weekly summaries (active/inactive)

Optional Arguments:
  --test-mode                Enable test mode (uses test database tables)
  --help                     Show this help message

Defaults:
  Daily frequency:           $DEFAULT_DAILY_FREQUENCY minutes (24 hours)
  Weekly frequency:          $DEFAULT_WEEKLY_FREQUENCY minutes (7 days)
  Start time:                $DEFAULT_TIME (PST)

Examples:
  # Basic usage - creates both daily and weekly summaries for all users
  $0 \\
    --file user_keys.txt \\
    --endpoint http://localhost:2100 \\
    --start-date 2025-01-20 \\
    --daily-status inactive \\
    --weekly-status active

  # With test mode enabled
  $0 \\
    --file user_keys.txt \\
    --endpoint http://localhost:2100 \\
    --start-date 2025-01-20 \\
    --daily-status active \\
    --weekly-status active \\
    --test-mode

File Format:
  One user_key per line. Lines starting with # are treated as comments.

  Example user_keys.txt:
    # Production users
    user-abc-123
    user-def-456
    user-ghi-789

Notes:
  - Creates BOTH daily and weekly summaries for each user
  - Daily summaries: Every 24 hours ($DEFAULT_DAILY_FREQUENCY minutes)
  - Weekly summaries: Every 7 days ($DEFAULT_WEEKLY_FREQUENCY minutes)
  - Start time defaults to 1:00 AM PST ($DEFAULT_TIME)

EOF
    exit 0
}

# Initialize variables
USER_KEYS_FILE=""
API_ENDPOINT=""
START_DATE=""
DAILY_STATUS=""
WEEKLY_STATUS=""
TEST_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --file)
            USER_KEYS_FILE="$2"
            shift 2
            ;;
        --endpoint)
            API_ENDPOINT="$2"
            shift 2
            ;;
        --start-date)
            START_DATE="$2"
            shift 2
            ;;
        --daily-status)
            DAILY_STATUS="$2"
            shift 2
            ;;
        --weekly-status)
            WEEKLY_STATUS="$2"
            shift 2
            ;;
        --test-mode)
            TEST_MODE=true
            shift
            ;;
        --help)
            show_usage
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
MISSING_ARGS=()

if [ -z "$USER_KEYS_FILE" ]; then
    MISSING_ARGS+=("--file")
fi
if [ -z "$API_ENDPOINT" ]; then
    MISSING_ARGS+=("--endpoint")
fi
if [ -z "$START_DATE" ]; then
    MISSING_ARGS+=("--start-date")
fi
if [ -z "$DAILY_STATUS" ]; then
    MISSING_ARGS+=("--daily-status")
fi
if [ -z "$WEEKLY_STATUS" ]; then
    MISSING_ARGS+=("--weekly-status")
fi

if [ ${#MISSING_ARGS[@]} -gt 0 ]; then
    print_error "Missing required arguments: ${MISSING_ARGS[*]}"
    echo ""
    echo "Use --help for usage information"
    exit 1
fi

# Validate file exists
if [ ! -f "$USER_KEYS_FILE" ]; then
    print_error "File not found: $USER_KEYS_FILE"
    exit 1
fi

# Validate status values
if [[ ! "$DAILY_STATUS" =~ ^(active|inactive)$ ]]; then
    print_error "Invalid --daily-status: $DAILY_STATUS (must be 'active' or 'inactive')"
    exit 1
fi

if [[ ! "$WEEKLY_STATUS" =~ ^(active|inactive)$ ]]; then
    print_error "Invalid --weekly-status: $WEEKLY_STATUS (must be 'active' or 'inactive')"
    exit 1
fi

# Validate date format (YYYY-MM-DD)
if [[ ! "$START_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    print_error "Invalid date format: $START_DATE (must be YYYY-MM-DD)"
    exit 1
fi

# Build full datetime string in required format: "2006-01-02 15:04:05 MST"
START_UPDATE="$START_DATE $DEFAULT_TIME"

# Count lines in file (excluding empty and comment lines)
TOTAL_USERS=$(grep -v '^[[:space:]]*$' "$USER_KEYS_FILE" | grep -v '^[[:space:]]*#' | wc -l | tr -d ' ')
if [ "$TOTAL_USERS" -eq 0 ]; then
    print_error "No valid user keys found in: $USER_KEYS_FILE"
    exit 1
fi

# Display configuration
echo "=========================================="
echo "  Bulk Summary Notification Configuration"
echo "=========================================="
echo "File:                 $USER_KEYS_FILE"
echo "Total Users:          $TOTAL_USERS"
echo "Endpoint:             $API_ENDPOINT"
echo ""
echo "Daily Summaries:"
echo "  Frequency:          $DEFAULT_DAILY_FREQUENCY minutes (24 hours)"
echo "  Status:             $DAILY_STATUS"
echo ""
echo "Weekly Summaries:"
echo "  Frequency:          $DEFAULT_WEEKLY_FREQUENCY minutes (7 days)"
echo "  Status:             $WEEKLY_STATUS"
echo ""
echo "Start Date/Time:      $START_UPDATE"
echo "Test Mode:            $TEST_MODE"
echo "=========================================="
echo ""
echo "This will create 2 summaries per user (daily + weekly)"
echo "Total summaries to create: $((TOTAL_USERS * 2))"
echo ""

read -p "Proceed with bulk creation? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_warning "Operation cancelled by user"
    exit 0
fi

echo ""
print_info "Starting bulk creation..."
echo ""

# Counters
DAILY_SUCCESS=0
DAILY_ERROR=0
DAILY_SKIPPED=0
WEEKLY_SUCCESS=0
WEEKLY_ERROR=0
WEEKLY_SKIPPED=0

# Create log file immediately
LOG_FILE="bulk_summary_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE" || {
    print_error "Failed to create log file: $LOG_FILE"
    exit 1
}
print_info "Logging to: $LOG_FILE"
echo "=== Bulk Summary Creation Log ===" > "$LOG_FILE"
echo "Started: $(date)" >> "$LOG_FILE"
echo "File: $USER_KEYS_FILE" >> "$LOG_FILE"
echo "Endpoint: $API_ENDPOINT" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
echo ""

# Function to create summary
create_summary() {
    local USER_KEY=$1
    local FREQUENCY=$2
    local TEMPLATE=$3
    local STATUS=$4
    local SUMMARY_TYPE=$5  # "Daily" or "Weekly" for display

    # Build JSON payload
    local JSON_PAYLOAD=$(cat <<EOF
{
  "user_key": "$USER_KEY",
  "update_frequency": $FREQUENCY,
  "summary_template": "$TEMPLATE",
  "start_update": "$START_UPDATE",
  "status": "$STATUS"
}
EOF
)

    # Make API call
    local RESPONSE
    if [ "$TEST_MODE" = true ]; then
        RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "$API_ENDPOINT/notifications/summary/new" \
            -H "Content-Type: application/json" \
            -H "x-socialroots-testmode: test" \
            -d "$JSON_PAYLOAD" 2>&1)
    else
        RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "$API_ENDPOINT/notifications/summary/new" \
            -H "Content-Type: application/json" \
            -d "$JSON_PAYLOAD" 2>&1)
    fi

    # Extract HTTP code
    local HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
    local RESPONSE_BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

    # Log full response
    echo "[$SUMMARY_TYPE] User: $USER_KEY | HTTP: $HTTP_CODE | Response: $RESPONSE_BODY" >> "$LOG_FILE"

    # Return status: 0=success, 1=error, 2=skipped
    if [ "$HTTP_CODE" == "200" ]; then
        return 0
    elif echo "$RESPONSE_BODY" | grep -q "id"; then
        # Already exists (InsertSummary returns existing ID if user+template combo exists)
        return 2
    else
        return 1
    fi
}

# Process each user key
LINE_NUM=0
PROCESSED=0

print_info "DEBUG: Starting to read file: $USER_KEYS_FILE"
echo "DEBUG: Starting to read file" >> "$LOG_FILE"

while IFS= read -r USER_KEY || [ -n "$USER_KEY" ]; do
    LINE_NUM=$((LINE_NUM + 1))

    echo "DEBUG: Read line $LINE_NUM: '$USER_KEY'" >> "$LOG_FILE"

    # Skip empty lines and lines starting with #
    if [ -z "$USER_KEY" ] || [[ "$USER_KEY" =~ ^[[:space:]]*# ]]; then
        echo "DEBUG: Skipping line $LINE_NUM (empty or comment)" >> "$LOG_FILE"
        continue
    fi

    # Trim whitespace
    USER_KEY=$(echo "$USER_KEY" | xargs)
    echo "DEBUG: Trimmed user_key: '$USER_KEY'" >> "$LOG_FILE"

    PROCESSED=$((PROCESSED + 1))

    print_info "[$PROCESSED/$TOTAL_USERS] Processing user: $USER_KEY"
    echo "=== Processing user $PROCESSED/$TOTAL_USERS: $USER_KEY ===" >> "$LOG_FILE"

    # Create DAILY summary
    print_info "  Creating daily summary..."
    create_summary "$USER_KEY" "$DEFAULT_DAILY_FREQUENCY" "daily" "$DAILY_STATUS" "Daily" || true
    DAILY_RESULT=$?

    case $DAILY_RESULT in
        0)
            print_success "    ✓ Daily summary created (status: $DAILY_STATUS)"
            DAILY_SUCCESS=$((DAILY_SUCCESS + 1))
            ;;
        2)
            print_warning "    ⚠ Daily summary already exists"
            DAILY_SKIPPED=$((DAILY_SKIPPED + 1))
            ;;
        *)
            print_error "    ✗ Daily summary failed (exit code: $DAILY_RESULT)"
            DAILY_ERROR=$((DAILY_ERROR + 1))
            ;;
    esac

    # Create WEEKLY summary
    print_info "  Creating weekly summary..."
    create_summary "$USER_KEY" "$DEFAULT_WEEKLY_FREQUENCY" "weekly" "$WEEKLY_STATUS" "Weekly" || true
    WEEKLY_RESULT=$?

    case $WEEKLY_RESULT in
        0)
            print_success "    ✓ Weekly summary created (status: $WEEKLY_STATUS)"
            WEEKLY_SUCCESS=$((WEEKLY_SUCCESS + 1))
            ;;
        2)
            print_warning "    ⚠ Weekly summary already exists"
            WEEKLY_SKIPPED=$((WEEKLY_SKIPPED + 1))
            ;;
        *)
            print_error "    ✗ Weekly summary failed (exit code: $WEEKLY_RESULT)"
            WEEKLY_ERROR=$((WEEKLY_ERROR + 1))
            ;;
    esac

    # Small delay to avoid overwhelming the service
    sleep 0.1

done < "$USER_KEYS_FILE"

# Summary
echo ""
echo "=========================================="
echo "  Bulk Creation Summary"
echo "=========================================="
echo "Total Users Processed: $PROCESSED"
echo ""
echo "Daily Summaries ($DEFAULT_DAILY_FREQUENCY min):"
echo "  Successful:          $DAILY_SUCCESS"
echo "  Skipped:             $DAILY_SKIPPED"
echo "  Errors:              $DAILY_ERROR"
echo ""
echo "Weekly Summaries ($DEFAULT_WEEKLY_FREQUENCY min):"
echo "  Successful:          $WEEKLY_SUCCESS"
echo "  Skipped:             $WEEKLY_SKIPPED"
echo "  Errors:              $WEEKLY_ERROR"
echo "=========================================="
echo ""
print_info "Full log saved to: $LOG_FILE"

TOTAL_ERRORS=$((DAILY_ERROR + WEEKLY_ERROR))
if [ $TOTAL_ERRORS -gt 0 ]; then
    print_warning "Some operations failed. Check log file for details."
    exit 1
else
    print_success "All operations completed successfully!"
    exit 0
fi
