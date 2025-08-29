#!/bin/bash
set -e

# -------------------------
# Config
# -------------------------
REDIS_USER="myuser"
REDIS_PASS="MyRedisPass123"
CERTS_DIR="$(pwd)/redis-certs"

# -------------------------
# Cleanup old setup
# -------------------------
echo "Cleaning up old containers and certs..."
docker rm -f redis1 redis2 2>/dev/null || true
rm -rf "$CERTS_DIR"
mkdir -p "$CERTS_DIR"

# -------------------------
# Generate TLS certs with proper SAN for localhost
# -------------------------
cd "$CERTS_DIR"

echo "Generating CA..."
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 \
  -subj "/CN=RedisTestCA" -out ca.crt

# OpenSSL config with SAN
cat > openssl.cnf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = localhost

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = redis1
DNS.3 = redis2
IP.1 = 127.0.0.1
EOF

for name in redis1 redis2; do
  echo "Generating cert for $name with SAN..."
  openssl genrsa -out $name.key 2048
  openssl req -new -key $name.key -config openssl.cnf -out $name.csr
  openssl x509 -req -in $name.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out $name.crt -days 365 -sha256 -extensions v3_req -extfile openssl.cnf
done

cd -

# -------------------------
# Start Redis with TLS only
# -------------------------
echo "Starting Redis instances with TLS..."

docker run -d --name redis1 -p 6379:6379 \
  -v "$CERTS_DIR:/certs" \
  redis:7 \
  redis-server \
    --tls-port 6379 \
    --port 0 \
    --requirepass "$REDIS_PASS" \
    --tls-cert-file /certs/redis1.crt \
    --tls-key-file /certs/redis1.key \
    --tls-ca-cert-file /certs/ca.crt \
    --tls-auth-clients optional

docker run -d --name redis2 -p 6380:6379 \
  -v "$CERTS_DIR:/certs" \
  redis:7 \
  redis-server \
    --tls-port 6379 \
    --port 0 \
    --requirepass "$REDIS_PASS" \
    --tls-cert-file /certs/redis2.crt \
    --tls-key-file /certs/redis2.key \
    --tls-ca-cert-file /certs/ca.crt \
    --tls-auth-clients optional

echo "Waiting for Redis instances to start..."
sleep 10

# -------------------------
# Setup ACL user
# -------------------------
echo "Setting up ACL user on redis1..."
docker exec redis1 redis-cli \
  --tls \
  --cacert /certs/ca.crt \
  --no-auth-warning \
  -a "$REDIS_PASS" \
  ACL SETUSER "$REDIS_USER" on ">$REDIS_PASS" allkeys allcommands

echo "Setting up ACL user on redis2..."
docker exec redis2 redis-cli \
  --tls \
  --cacert /certs/ca.crt \
  --no-auth-warning \
  -a "$REDIS_PASS" \
  ACL SETUSER "$REDIS_USER" on ">$REDIS_PASS" allkeys allcommands

# -------------------------
# Add test keys in multiple DBs
# -------------------------
echo "Adding keys to redis1..."
for db in 0 1 2; do
  for key in key1 key2; do
    docker exec redis1 redis-cli \
      --tls \
      --cacert /certs/ca.crt \
      --no-auth-warning \
      -a "$REDIS_PASS" \
      -n "$db" \
      SET "db${db}_${key}" "value_db${db}_${key}"
  done
done

# -------------------------
# Verify keys
# -------------------------
for db in 0 1 2; do
  echo "Keys in redis1 - DB $db:"
  docker exec redis1 redis-cli \
    --tls \
    --cacert /certs/ca.crt \
    --no-auth-warning \
    -a "$REDIS_PASS" \
    -n "$db" KEYS "*"
done

echo "Redis TLS-only setup complete!"
echo "redis1: rediss://$REDIS_USER:$REDIS_PASS@localhost:6379"
echo "redis2: rediss://$REDIS_USER:$REDIS_PASS@localhost:6380"
echo "CA cert: $CERTS_DIR/ca.crt"
