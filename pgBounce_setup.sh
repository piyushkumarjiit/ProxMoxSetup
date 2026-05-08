#!/bin/bash
# -------------------------------------------------------------------------
# FILE: deploy-pgbouncer.sh
# ROLE: Adds PgBouncer to an existing CIP stack without breaking it
# -------------------------------------------------------------------------

TARGET_ID=106
STACK_PATH="/opt/cip-stack"

echo "--- Step 0: Directory Setup ---"

# mkdir -p is natively idempotent. Running it via pct exec is the safest 
# way to ensure the directory exists inside the container without complex checks.
echo "Ensuring $STACK_PATH exists inside LXC $TARGET_ID..."
if pct exec $TARGET_ID -- mkdir -p "$STACK_PATH"; then
    echo "✅ Directory ready inside container."
else
    echo "❌ Failed to create or access directory $STACK_PATH inside LXC!"
    exit 1
fi

echo "--- Step 1: Creating docker-compose.override.yml ---"
# We create this on the PVE host temporarily
cat <<EOF > /tmp/docker-compose.override.yml
services:
  pgbouncer:
    image: edoburu/pgbouncer:latest
    container_name: cip_pgbouncer
    environment:
      # Connects using the internal Docker DNS name of your postgres service
      DB_HOST: postgres
      DB_USER: cip_user
      DB_PASSWORD: cip_password
      DB_NAME: cip_entities
      POOL_MODE: transaction
      MAX_CLIENT_CONN: 2000
      DEFAULT_POOL_SIZE: 40
      IGNORE_STARTUP_PARAMETERS: extra_float_digits
      # Fix for PostgreSQL 14+ password encryption mismatch
      AUTH_TYPE: scram-sha-256
    ports: 
      - "6432:5432"
    depends_on:
      - postgres
    security_opt:
      - apparmor:unconfined
    restart: always
EOF

# Push new config file from PVE host to LXC
echo "Pushing configuration to LXC..."
pct push $TARGET_ID /tmp/docker-compose.override.yml "$STACK_PATH/docker-compose.override.yml"

echo "--- Step 2: Applying the Update ---"
# Docker Compose automatically merges docker-compose.yml and docker-compose.override.yml
# when you run 'up' without specifying -f files.
echo "Restarting stack to include PgBouncer..."
pct exec $TARGET_ID -- bash -c "cd $STACK_PATH && docker compose up -d"

echo "--- Step 3: Cleanup ---"
rm /tmp/docker-compose.override.yml

echo "--- SUCCESS ---"
echo "PgBouncer is now running and proxying traffic to Postgres."
echo "Verify logs with: pct exec $TARGET_ID -- docker logs cip_pgbouncer"