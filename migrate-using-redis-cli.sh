#!/bin/bash

REDIS1_HOST="10.1.9.143"
REDIS1_PORT=6379
REDIS2_HOST="10.1.2.208"
REDIS2_PORT=6379
PASSWORD="MyRedisPass123"
CACERT="./redis1_ca.crt"

# Helper function to dump and pipe keys from source to target
migrate_redis() {
  local SRC_HOST=$1
  local SRC_PORT=$2
  local SRC_PASS=$3
  local DST_HOST=$4
  local DST_PORT=$5
  local DST_PASS=$6
  local DST_TLS=$7

  redis-cli -h $SRC_HOST -p $SRC_PORT -a $SRC_PASS --scan | while read key; do
    type=$(redis-cli -h $SRC_HOST -p $SRC_PORT -a $SRC_PASS TYPE "$key")
    case $type in
      string)
        val=$(redis-cli -h $SRC_HOST -p $SRC_PORT -a $SRC_PASS GET "$key")
        echo "SET \"$key\" \"$val\""
        ;;
      list)
        vals=$(redis-cli -h $SRC_HOST -p $SRC_PORT -a $SRC_PASS LRANGE "$key" 0 -1 | awk '{printf "\"%s\" ", $0}')
        echo "DEL \"$key\""
        echo "RPUSH \"$key\" $vals"
        ;;
      set)
        vals=$(redis-cli -h $SRC_HOST -p $SRC_PORT -a $SRC_PASS SMEMBERS "$key" | awk '{printf "\"%s\" ", $0}')
        echo "DEL \"$key\""
        echo "SADD \"$key\" $vals"
        ;;
      zset)
        vals=$(redis-cli -h $SRC_HOST -p $SRC_PORT -a $SRC_PASS ZRANGE "$key" 0 -1 WITHSCORES | awk '{printf "\"%s\" %s ", $1,$2}')
        echo "DEL \"$key\""
        echo "ZADD \"$key\" $vals"
        ;;
      hash)
        vals=$(redis-cli -h $SRC_HOST -p $SRC_PORT -a $SRC_PASS HGETALL "$key" | awk '{printf "\"%s\" \"%s\" ", $1,$2}')
        echo "DEL \"$key\""
        echo "HMSET \"$key\" $vals"
        ;;
    esac
  done | {
    if [ "$DST_TLS" = "yes" ]; then
      redis-cli -h $DST_HOST -p $DST_PORT -a $DST_PASS --tls --cacert $CACERT --pipe
    else
      redis-cli -h $DST_HOST -p $DST_PORT -a $DST_PASS --pipe
    fi
  }
}

echo "=== Step 1: Copying REDIS1 -> REDIS2 (non-TLS) ==="
migrate_redis $REDIS1_HOST $REDIS1_PORT $PASSWORD $REDIS2_HOST $REDIS2_PORT $PASSWORD "no"

echo "=== Step 1 complete. Enable TLS on REDIS1 and press any key to continue ==="
read -n 1 -s -r

echo "=== Step 2: Copying REDIS2 -> REDIS1 (TLS) ==="
migrate_redis $REDIS2_HOST $REDIS2_PORT $PASSWORD $REDIS1_HOST $REDIS1_PORT $PASSWORD "yes"

echo "=== Migration complete ==="
