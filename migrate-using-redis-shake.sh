#!/bin/bash
set -e

# -------------------------
# Configuration
# -------------------------
REDIS1_ADDR="10.1.9.143:6379"
REDIS2_ADDR="10.1.2.208:6379"
REDIS_USER=""           # set correct username if using ACLs
REDIS_PASS="MyRedisPass123"
MAX_DBS_TO_CHECK=5       # Limit to checking only 5 databases

# NEW: make source/target type configurable
SOURCE_TYPE="standalone"   # options: standalone, cluster
TARGET_TYPE="standalone"   # options: standalone, cluster

# NEW: Track if redis1 has TLS enabled
REDIS1_TLS_ENABLED=false

SYNC_TIMEOUT=$((60 * 60)) # max wait time for sync (1 hour)
SHAKE_IMAGE="ghcr.io/tair-opensource/redisshake:latest"

# -------------------------
# Enhanced debug function
# -------------------------
debug_redis_connection() {
    local ADDR="$1"
    local NAME="$2"
    
    echo "🧪 Deep debugging connection to $NAME ($ADDR)..."
    local HOST="${ADDR%%:*}"
    local PORT="${ADDR##*:}"
    
    # Test basic connectivity
    echo "  Testing port connectivity:"
    if nc -zv -w 5 "$HOST" "$PORT" 2>&1; then
        echo "  ✅ Port $PORT is open on $HOST"
    else
        echo "  ❌ Port $PORT is closed or unreachable on $HOST"
        return 1
    fi
    
    # Test Redis connection with various methods
    echo "  Testing Redis connection methods:"
    
    # Method 1: Plain connection without auth
    echo "  Method 1: Plain connection without auth"
    if timeout 5 redis-cli -h "$HOST" -p "$PORT" PING 2>&1; then
        echo "  ✅ Success - No auth required"
    else
        echo "  ❌ Failed - Auth may be required"
    fi
    
    # Method 2: With password
    if [ -n "$REDIS_PASS" ]; then
        echo "  Method 2: With password auth"
        if timeout 5 redis-cli -h "$HOST" -p "$PORT" -a "$REDIS_PASS" PING 2>/dev/null; then
            echo "  ✅ Success - Password auth works"
        else
            echo "  ❌ Failed - Password auth failed"
        fi
    fi
    
    # Method 3: With TLS
    echo "  Method 3: With TLS"
    if timeout 5 redis-cli --tls --insecure -h "$HOST" -p "$PORT" PING 2>&1; then
        echo "  ✅ Success - TLS connection works"
        # If this is redis1, mark TLS as enabled
        if [ "$NAME" = "redis1" ]; then
            REDIS1_TLS_ENABLED=true
            echo "  🔐 TLS is enabled on redis1"
        fi
    else
        echo "  ❌ Failed - TLS connection failed"
    fi
    
    # Method 4: With TLS and password
    if [ -n "$REDIS_PASS" ]; then
        echo "  Method 4: With TLS and password"
        if timeout 5 redis-cli --tls --insecure -h "$HOST" -p "$PORT" -a "$REDIS_PASS" PING 2>/dev/null; then
            echo "  ✅ Success - TLS + password works"
            # If this is redis1, mark TLS as enabled
            if [ "$NAME" = "redis1" ]; then
                REDIS1_TLS_ENABLED=true
                echo "  🔐 TLS is enabled on redis1"
            fi
        else
            echo "  ❌ Failed - TLS + password failed"
        fi
    fi
    
    # Test Redis info command with TLS
    echo "  Testing INFO command with TLS:"
    if [ -n "$REDIS_PASS" ]; then
        if timeout 5 redis-cli --tls --insecure -h "$HOST" -p "$PORT" -a "$REDIS_PASS" INFO 2>/dev/null | head -5; then
            echo "  ✅ INFO command successful with TLS"
        else
            echo "  ❌ INFO command failed with TLS"
        fi
    else
        if timeout 5 redis-cli --tls --insecure -h "$HOST" -p "$PORT" INFO 2>/dev/null | head -5; then
            echo "  ✅ INFO command successful with TLS"
        else
            echo "  ❌ INFO command failed with TLS"
        fi
    fi
}

# -------------------------
# Function: detect TLS or plain Redis (enhanced)
# -------------------------
detect_tls() {
  local ADDR="$1"
  local HOST="${ADDR%%:*}"
  local PORT="${ADDR##*:}"

  echo "  Detecting connection mode for $ADDR..."
  
  # Special handling for redis1 if we know TLS is enabled
  if [ "$ADDR" = "$REDIS1_ADDR" ] && [ "$REDIS1_TLS_ENABLED" = "true" ]; then
    echo "  ✅ Using TLS (previously detected as enabled)"
    echo "tls"
    return
  fi
  
  # First try TLS with auth if password provided (for cases where plain is disabled but TLS works)
  if [ -n "$REDIS_PASS" ]; then
    if timeout 3 redis-cli --tls --insecure -h "$HOST" -p "$PORT" -a "$REDIS_PASS" PING 2>/dev/null; then
      echo "  ✅ Detected: TLS with password"
      # If this is redis1, mark TLS as enabled
      if [ "$ADDR" = "$REDIS1_ADDR" ]; then
        REDIS1_TLS_ENABLED=true
      fi
      echo "tls"
      return
    fi
  else
    # Try TLS without auth
    if timeout 3 redis-cli --tls --insecure -h "$HOST" -p "$PORT" PING 2>/dev/null; then
      echo "  ✅ Detected: TLS without auth"
      # If this is redis1, mark TLS as enabled
      if [ "$ADDR" = "$REDIS1_ADDR" ]; then
        REDIS1_TLS_ENABLED=true
      fi
      echo "tls"
      return
    fi
  fi

  # Then try plain connection with auth if password provided
  if [ -n "$REDIS_PASS" ]; then
    if timeout 3 redis-cli -h "$HOST" -p "$PORT" -a "$REDIS_PASS" PING 2>/dev/null; then
      echo "  ✅ Detected: plain with password"
      echo "plain"
      return
    fi
  else
    # Try plain without auth
    if timeout 3 redis-cli -h "$HOST" -p "$PORT" PING 2>/dev/null; then
      echo "  ✅ Detected: plain without auth"
      echo "plain"
      return
    fi
  fi

  echo "❌ Cannot connect to Redis at $ADDR with any method"
  echo "   Please check:"
  echo "   - Redis is running"
  echo "   - Password is correct"
  echo "   - Network connectivity"
  echo "   - Firewall rules"
  exit 1
}

# -------------------------
# Wrapper for redis-cli with auto TLS and auth (handles warnings)
# -------------------------
redis_cmd() {
  local ADDR="$1"
  local DB="$2"
  shift 2

  local HOST="${ADDR%%:*}"
  local PORT="${ADDR##*:}"
  local MODE
  MODE=$(detect_tls "$ADDR")

  local AUTH_CMD=""
  if [ -n "$REDIS_PASS" ]; then
    if [ -n "$REDIS_USER" ]; then
      AUTH_CMD="--user $REDIS_USER --pass $REDIS_PASS"
    else
      AUTH_CMD="-a $REDIS_PASS"
    fi
  fi

  if [ "$MODE" = "tls" ]; then
    # For TLS, run command and filter out warnings
    redis-cli --tls --insecure $AUTH_CMD -h "$HOST" -p "$PORT" -n "$DB" "$@" 2>/dev/null
  else
    # For plain, run command and filter out warnings
    redis-cli $AUTH_CMD -h "$HOST" -p "$PORT" -n "$DB" "$@" 2>/dev/null
  fi
}

# -------------------------
# Function to check if Redis is reachable (with TLS support)
# -------------------------
check_redis_running() {
  local ADDR="$1"
  local NAME="$2"

  echo "🔍 Checking $NAME at $ADDR ..."
  
  # Use a direct connection test that handles TLS properly
  local HOST="${ADDR%%:*}"
  local PORT="${ADDR##*:}"
  
  if [ "$REDIS1_TLS_ENABLED" = "true" ] && [ "$ADDR" = "$REDIS1_ADDR" ]; then
    # Use TLS for redis1
    if timeout 5 redis-cli --tls --insecure -h "$HOST" -p "$PORT" -a "$REDIS_PASS" PING 2>/dev/null; then
      echo "✅ $NAME is up (TLS)"
      return 0
    else
      echo "❌ $NAME ($ADDR) is not reachable with TLS!"
      return 1
    fi
  else
    # Use auto-detection for others
    if redis_cmd "$ADDR" 0 PING >/dev/null 2>&1; then
      echo "✅ $NAME is up"
      return 0
    else
      echo "❌ $NAME ($ADDR) is not reachable!"
      return 1
    fi
  fi
}

# -------------------------
# Function to write config for RedisShake
# -------------------------
write_shake_config() {
  local SRC_ADDR="$1"
  local DST_ADDR="$2"
  local TMP_FILE="$3"

  local SRC_MODE DST_MODE
  
  # For redis1, use TLS if enabled, otherwise auto-detect
  if [ "$SRC_ADDR" = "$REDIS1_ADDR" ] && [ "$REDIS1_TLS_ENABLED" = "true" ]; then
    SRC_MODE="tls"
  else
    SRC_MODE=$(detect_tls "$SRC_ADDR")
  fi
  
  if [ "$DST_ADDR" = "$REDIS1_ADDR" ] && [ "$REDIS1_TLS_ENABLED" = "true" ]; then
    DST_MODE="tls"
  else
    DST_MODE=$(detect_tls "$DST_ADDR")
  fi

  # Determine cluster settings
  local SRC_CLUSTER="false"
  local DST_CLUSTER="false"
  
  if [ "$SOURCE_TYPE" = "cluster" ]; then
    SRC_CLUSTER="true"
  fi
  
  if [ "$TARGET_TYPE" = "cluster" ]; then
    DST_CLUSTER="true"
  fi

  cat > "$TMP_FILE" <<EOF
[scan_reader]
cluster = $SRC_CLUSTER
address = "$SRC_ADDR"
username = "$REDIS_USER"
password = "$REDIS_PASS"
tls = $( [ "$SRC_MODE" = "tls" ] && echo true || echo false )
scan_key_number = 100

[redis_writer]
cluster = $DST_CLUSTER
address = "$DST_ADDR"
username = "$REDIS_USER"
password = "$REDIS_PASS"
tls = $( [ "$DST_MODE" = "tls" ] && echo true || echo false )

[filter]
block_key_prefix = ["temp:", "cache:"]

[advanced]
dir = "data"
log_file = "shake.log"
log_level = "info"
EOF
}

# -------------------------
# Function to run RedisShake in Docker (with better error handling)
# -------------------------
run_sync_separate() {
  local SRC="$1"
  local DST="$2"
  local DESC="$3"

  echo "➡️ Starting sync: $DESC"

  # Test connections first with better error messages
  echo "🧪 Testing source connection..."
  if ! check_redis_running "$SRC" "source"; then
    return 1
  fi
  
  echo "🧪 Testing target connection..."
  if ! check_redis_running "$DST" "target"; then
    return 1
  fi

  # Temporary config file
  local TMP_CONFIG
  TMP_CONFIG=$(mktemp)
  TMP_CONFIG_ABS=$(realpath "$TMP_CONFIG")
  write_shake_config "$SRC" "$DST" "$TMP_CONFIG_ABS"

  echo "📋 Using config:"
  cat "$TMP_CONFIG_ABS"
  echo ""

  echo "🐳 Running RedisShake in Docker..."
  if docker run --rm --network host \
      -e SYNC=true \
      -v "$TMP_CONFIG_ABS":/app/shake_sync_env.toml \
      $SHAKE_IMAGE \
      scan -conf /app/shake_sync_env.toml; then
    echo "✅ Sync completed successfully"
  else
    echo "❌ Sync failed with error code $?"
    echo "   Common issues:"
    echo "   - Authentication problems"
    echo "   - Network connectivity"
    echo "   - Redis configuration (bind address, protected mode)"
    return 1
  fi
}

# -------------------------
# Helper: check number of keys in first 5 DBs for a given Redis instance
# -------------------------
check_all_dbs() {
  local ADDR="$1"
  local NAME="$2"

  echo "🔍 Checking first $MAX_DBS_TO_CHECK DBs on $NAME ($ADDR)..."
  
  for ((db=0; db<MAX_DBS_TO_CHECK; db++)); do
    local COUNT
    COUNT=$(redis_cmd "$ADDR" $db DBSIZE 2>&1 | tail -n1)  # Get last line to avoid warnings
    
    if [[ "$COUNT" == *NOAUTH* ]] || [[ "$COUNT" == *Authentication* ]]; then
      echo "  DB[$db] → ❌ Authentication required"
      continue
    fi
    if [[ "$COUNT" =~ ^[0-9]+$ ]]; then
      echo "  DB[$db] → $COUNT keys"
    else
      echo "  DB[$db] → 0 keys (or unexpected response: '$COUNT')"
    fi
  done
}

# -------------------------
# Function to check Redis version
# -------------------------
check_redis_version() {
  local ADDR="$1"
  local NAME="$2"

  echo "🔍 Checking $NAME version..."

  local VERSION
  VERSION=$(redis_cmd "$ADDR" 0 INFO SERVER | grep 'redis_version:' | cut -d: -f2 | tr -d '[:space:]')

  if [ -n "$VERSION" ]; then
    echo "✅ $NAME Redis version: $VERSION"
  else
    echo "❌ Could not determine $NAME version"
  fi
}

# -------------------------
# Function to manually set TLS mode for redis1
# -------------------------
force_redis1_tls() {
    echo "🔐 Manually enabling TLS mode for redis1"
    REDIS1_TLS_ENABLED=true
    echo "✅ redis1 will now use TLS connections"
}

# -------------------------
# Main flow
# -------------------------
echo "🚀 Starting Redis migration script"
echo "=================================="

# First run deep debugging
debug_redis_connection "$REDIS1_ADDR" "redis1"
debug_redis_connection "$REDIS2_ADDR" "redis2"

echo "✅ Checking if Redis instances are running..."
check_redis_running "$REDIS1_ADDR" "redis1"
check_redis_running "$REDIS2_ADDR" "redis2"

echo "✅ Checking Redis versions..."
check_redis_version "$REDIS1_ADDR" "redis1"
check_redis_version "$REDIS2_ADDR" "redis2"

echo "✅ Initial key counts:"
check_all_dbs "$REDIS1_ADDR" "redis1"
check_all_dbs "$REDIS2_ADDR" "redis2"

read -p "⏸️ Press Enter to start the first sync (redis1 → redis2) or Ctrl+C to cancel..."

# Step 1: Copy from REDIS1 -> REDIS2 (pre-TLS)
run_sync_separate "$REDIS1_ADDR" "$REDIS2_ADDR" "redis1 → redis2 (before TLS)"

read -p "⏸️ Press Enter once you have manually enabled TLS and restarted redis1 to continue..."

# After TLS is enabled on redis1, force TLS mode
force_redis1_tls

# Re-check redis1 connection with TLS
echo "🔍 Re-checking redis1 connection with TLS..."
debug_redis_connection "$REDIS1_ADDR" "redis1"
check_redis_running "$REDIS1_ADDR" "redis1"

# Step 2: Copy from REDIS2 -> REDIS1 (post-TLS)
run_sync_separate "$REDIS2_ADDR" "$REDIS1_ADDR" "redis2 → redis1 (after TLS)"

echo "✅ Final key counts on redis1:"
check_all_dbs "$REDIS1_ADDR" "redis1"

echo "✅ Final key counts on redis2:"
check_all_dbs "$REDIS2_ADDR" "redis2"

echo "🎉 Migration complete!"