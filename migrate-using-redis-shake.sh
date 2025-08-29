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

# make source/target type configurable
SOURCE_TYPE="standalone"   # options: standalone, cluster
TARGET_TYPE="standalone"   # options: standalone, cluster

# Track if redis1 has TLS enabled
REDIS1_TLS_ENABLED=false

SYNC_TIMEOUT=$((60 * 60)) # max wait time for sync (1 hour)
SHAKE_IMAGE="ghcr.io/tair-opensource/redisshake:latest"

# -------------------------
# Function: detect TLS or plain Redis
# -------------------------
detect_tls() {
  local ADDR="$1"
  local HOST="${ADDR%%:*}"
  local PORT="${ADDR##*:}"

  # Special handling for redis1 if we know TLS is enabled
  if [ "$ADDR" = "$REDIS1_ADDR" ] && [ "$REDIS1_TLS_ENABLED" = "true" ]; then
    echo "tls"
    return
  fi
  
  # First try TLS with auth if password provided
  if [ -n "$REDIS_PASS" ]; then
    if timeout 3 redis-cli --tls --insecure -h "$HOST" -p "$PORT" -a "$REDIS_PASS" PING 2>/dev/null; then
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
      echo "plain"
      return
    fi
  else
    # Try plain without auth
    if timeout 3 redis-cli -h "$HOST" -p "$PORT" PING 2>/dev/null; then
      echo "plain"
      return
    fi
  fi

  echo "❌ Cannot connect to Redis at $ADDR with any method"
  exit 1
}

# -------------------------
# Wrapper for redis-cli with auto TLS and auth
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
    redis-cli --tls --insecure $AUTH_CMD -h "$HOST" -p "$PORT" -n "$DB" "$@" 2>/dev/null
  else
    redis-cli $AUTH_CMD -h "$HOST" -p "$PORT" -n "$DB" "$@" 2>/dev/null
  fi
}

# -------------------------
# Function to check if Redis is reachable
# -------------------------
check_redis_running() {
  local ADDR="$1"
  local NAME="$2"

  echo "🔍 Checking $NAME at $ADDR ..."
  
  local HOST="${ADDR%%:*}"
  local PORT="${ADDR##*:}"
  
  if [ "$REDIS1_TLS_ENABLED" = "true" ] && [ "$ADDR" = "$REDIS1_ADDR" ]; then
    if timeout 5 redis-cli --tls --insecure -h "$HOST" -p "$PORT" -a "$REDIS_PASS" PING 2>/dev/null; then
      echo "✅ $NAME is up (TLS)"
      return 0
    else
      echo "❌ $NAME ($ADDR) is not reachable with TLS!"
      return 1
    fi
  else
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
# Function to run RedisShake in Docker
# -------------------------
run_sync_separate() {
  local SRC="$1"
  local DST="$2"
  local DESC="$3"

  echo "➡️ Starting sync: $DESC"

  if ! check_redis_running "$SRC" "source"; then
    return 1
  fi
  
  if ! check_redis_running "$DST" "target"; then
    return 1
  fi

  local TMP_CONFIG
  TMP_CONFIG=$(mktemp)
  TMP_CONFIG_ABS=$(realpath "$TMP_CONFIG")
  write_shake_config "$SRC" "$DST" "$TMP_CONFIG_ABS"

  echo "🐳 Running RedisShake in Docker..."
  if docker run --rm --network host \
      -e SYNC=true \
      -v "$TMP_CONFIG_ABS":/app/shake_sync_env.toml \
      $SHAKE_IMAGE \
      scan -conf /app/shake_sync_env.toml; then
    echo "✅ Sync completed successfully"
  else
    echo "❌ Sync failed with error code $?"
    return 1
  fi
}

# -------------------------
# Helper: check number of keys in first 5 DBs
# -------------------------
check_all_dbs() {
  local ADDR="$1"
  local NAME="$2"

  echo "🔍 Checking first $MAX_DBS_TO_CHECK DBs on $NAME ($ADDR)..."
  
  for ((db=0; db<MAX_DBS_TO_CHECK; db++)); do
    local COUNT
    COUNT=$(redis_cmd "$ADDR" $db DBSIZE 2>&1 | tail -n1)
    
    if [[ "$COUNT" == *NOAUTH* ]] || [[ "$COUNT" == *Authentication* ]]; then
      echo "  DB[$db] → ❌ Authentication required"
      continue
    fi
    if [[ "$COUNT" =~ ^[0-9]+$ ]]; then
      echo "  DB[$db] → $COUNT keys"
    else
      echo "  DB[$db] → 0 keys"
    fi
  done
}

# -------------------------
# Function to check Redis version
# -------------------------
check_redis_version() {
  local ADDR="$1"
  local NAME="$2"

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
    REDIS1_TLS_ENABLED=true
    echo "✅ redis1 will now use TLS connections"
}

# -------------------------
# Function to flush redis2
# -------------------------
flush_redis2() {
    echo "🧹 Flushing all data from redis2..."
    if redis_cmd "$REDIS2_ADDR" 0 FLUSHALL >/dev/null 2>&1; then
        echo "✅ redis2 flushed successfully"
    else
        echo "❌ Failed to flush redis2"
        exit 1
    fi
}

# -------------------------
# Main flow
# -------------------------
echo "🚀 Starting Redis migration script"
echo "=================================="

# Flush redis2 at the beginning
flush_redis2

check_redis_running "$REDIS1_ADDR" "redis1"
check_redis_running "$REDIS2_ADDR" "redis2"

check_redis_version "$REDIS1_ADDR" "redis1"
check_redis_version "$REDIS2_ADDR" "redis2"

echo "✅ Initial key counts:"
check_all_dbs "$REDIS1_ADDR" "redis1"
check_all_dbs "$REDIS2_ADDR" "redis2"

read -p "⏸️ Press Enter to start the first sync (redis1 → redis2) or Ctrl+C to cancel..."

run_sync_separate "$REDIS1_ADDR" "$REDIS2_ADDR" "redis1 → redis2 (before TLS)"

read -p "⏸️ Press Enter once you have manually enabled TLS and restarted redis1 to continue..."

force_redis1_tls

check_redis_running "$REDIS1_ADDR" "redis1"

run_sync_separate "$REDIS2_ADDR" "$REDIS1_ADDR" "redis2 → redis1 (after TLS)"

echo "✅ Final key counts on redis1:"
check_all_dbs "$REDIS1_ADDR" "redis1"

echo "✅ Final key counts on redis2:"
check_all_dbs "$REDIS2_ADDR" "redis2"

echo "🎉 Migration complete!"