#!/bin/bash
set -e

# -------------------------
# Configuration
# -------------------------
REDIS_ADDR="10.1.9.143:6379"
REDIS_USER=""
REDIS_PASS="MyRedisPass123"

# Number of sample keys to create
SAMPLE_KEYS_COUNT=50

# -------------------------
# Function to execute Redis commands
# -------------------------
redis_cmd() {
    local DB="$1"
    shift
    local HOST="${REDIS_ADDR%%:*}"
    local PORT="${REDIS_ADDR##*:}"
    
    local AUTH_CMD=""
    if [ -n "$REDIS_PASS" ]; then
        AUTH_CMD="-a $REDIS_PASS"
    fi
    
    redis-cli $AUTH_CMD -h "$HOST" -p "$PORT" -n "$DB" "$@" 2>/dev/null
}

# -------------------------
# Function to check if Redis is reachable
# -------------------------
check_redis_running() {
    echo "🔍 Checking Redis connection to $REDIS_ADDR..."
    if redis_cmd 0 PING >/dev/null 2>&1; then
        echo "✅ Redis is reachable"
        return 0
    else
        echo "❌ Redis is not reachable!"
        return 1
    fi
}

# -------------------------
# Function to add simple string data
# -------------------------
add_simple_data() {
    echo "📝 Adding simple string data to Redis..."
    
    # Database 0: Simple string values
    echo "   Adding string values to DB 0..."
    for i in $(seq 1 $SAMPLE_KEYS_COUNT); do
        redis_cmd 0 SET "key$i" "value$i" >/dev/null
    done
    echo "   ✅ Added $SAMPLE_KEYS_COUNT simple string keys"
    
    # Database 1: Some additional simple data
    echo "   Adding more simple data to DB 1..."
    for i in $(seq 1 $((SAMPLE_KEYS_COUNT / 2))); do
        redis_cmd 1 SET "data:$i" "sample_value_$i" >/dev/null
    done
    echo "   ✅ Added $((SAMPLE_KEYS_COUNT / 2)) more simple keys"
}

# -------------------------
# Function to show current data statistics
# -------------------------
show_data_stats() {
    echo ""
    echo "📊 Current Data Statistics:"
    echo "==========================="
    
    for db in {0..1}; do
        local count
        count=$(redis_cmd "$db" DBSIZE)
        if [[ "$count" =~ ^[0-9]+$ ]]; then
            echo "DB $db: $count keys"
        else
            echo "DB $db: 0 keys"
        fi
    done
    
    # Show some sample keys
    echo ""
    echo "🔍 Sample Keys:"
    echo "---------------"
    for db in {0..1}; do
        echo "DB $db sample keys:"
        redis_cmd "$db" KEYS "*" | head -5 | while read -r key; do
            if [ -n "$key" ]; then
                echo "  - $key"
            fi
        done
        echo ""
    done
}

# -------------------------
# Function to flush all data (optional)
# -------------------------
flush_all_data() {
    read -p "⚠️  Do you want to flush ALL data from Redis? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🗑️  Flushing all data..."
        redis_cmd 0 FLUSHALL
        echo "✅ All data flushed"
    else
        echo "❌ Flush cancelled"
    fi
}

# -------------------------
# Function to flush specific database
# -------------------------
flush_database() {
    local db="$1"
    echo "🗑️  Flushing database $db..."
    redis_cmd "$db" FLUSHDB
    echo "✅ Database $db flushed"
}

# -------------------------
# Main menu
# -------------------------
show_menu() {
    echo ""
    echo "🎯 Redis Data Management Script"
    echo "==============================="
    echo "Redis: $REDIS_ADDR"
    echo ""
    echo "1. Add simple data"
    echo "2. Show data statistics"
    echo "3. Flush all data (DANGER!)"
    echo "4. Flush specific database"
    echo "5. Test connection"
    echo "6. Exit"
    echo ""
}

# -------------------------
# Main execution
# -------------------------
echo "🚀 Starting Redis Data Management Script"
echo "========================================"

# Check connection first
if ! check_redis_running; then
    exit 1
fi

while true; do
    show_menu
    read -p "Select an option (1-6): " choice
    
    case $choice in
        1)
            add_simple_data
            ;;
        2)
            show_data_stats
            ;;
        3)
            flush_all_data
            ;;
        4)
            read -p "Enter database number to flush (0-1): " db_num
            if [[ "$db_num" =~ ^[0-1]$ ]]; then
                flush_database "$db_num"
            else
                echo "❌ Invalid database number"
            fi
            ;;
        5)
            check_redis_running
            ;;
        6)
            echo "👋 Exiting..."
            exit 0
            ;;
        *)
            echo "❌ Invalid option. Please try again."
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
done