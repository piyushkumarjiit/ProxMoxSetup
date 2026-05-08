#!/bin/bash
# -------------------------------------------------------------------------
# FILE: create-cip-infra.sh (Target ID 106)
# ROLE: CIP Platform Infrastructure with Immutable Audit Ledger
# -------------------------------------------------------------------------

TARGET_ID=106
NAME="cip-infra"
STORAGE="nvme_fast"
TEMPLATE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

# --- NETWORK CONFIG ---
STATIC_IP="192.168.2.184/24"
GATEWAY="192.168.2.1"

echo "--- Step 1: Cleaning Ghost/Old $TARGET_ID ---"
pct stop $TARGET_ID 2>/dev/null
pct destroy $TARGET_ID --purge 2>/dev/null

echo "--- Step 2: Creating Infrastructure LXC ---"
pct create $TARGET_ID "$TEMPLATE" \
  --arch amd64 --ostype ubuntu --hostname "$NAME" \
  --password "Proxmox123!" --net0 name=eth0,bridge=vmbr0,ip=$STATIC_IP,gw=$GATEWAY \
  --storage "$STORAGE" --rootfs 50 --memory 4096 --cores 2 \
  --features nesting=1,keyctl=1 --unprivileged 0

pct start $TARGET_ID
echo "Waiting for network..." && sleep 10

echo "--- Step 3: Installing Docker & Tools ---"
pct exec $TARGET_ID -- bash -c "apt update && apt install -y docker.io docker-compose-v2"

echo "--- Step 4: Generating Configurations ---"
pct exec $TARGET_ID -- mkdir -p /opt/cip-stack

# --- 4a. NEW: Audit Ledger Schema (Pharma/Banking Compliance) ---
cat <<EOF > /tmp/init-audit-ledger.sql
-- Extension for UUID generation if needed
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS audit_ledger (
    audit_id SERIAL PRIMARY KEY,
    manifest_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    actor_id TEXT NOT NULL,          -- Service/Worker Name
    action_type TEXT NOT NULL,       -- ENTITY_EXTRACTION, VECTOR_INGEST, etc.
    entity_ref TEXT,                 -- Reference to entities table
    
    -- Chain of Custody Data
    previous_state JSONB,            -- Pre-action snapshot
    current_state JSONB,             -- Post-action snapshot
    inference_metadata JSONB,        -- Model version, GPU temp, Confidence
    
    -- Cryptographic Chaining (Tamper Evidence)
    prev_hash TEXT,                  -- Hash of the record before this one
    row_hash TEXT NOT NULL           -- SHA-256(this_row + prev_hash)
);

CREATE INDEX idx_audit_manifest ON audit_ledger(manifest_id);
CREATE INDEX idx_audit_timestamp ON audit_ledger(timestamp);

-- Optional: Protect from accidental deletes (requires superuser to drop)
REVOKE DELETE ON audit_ledger FROM cip_user;
EOF

# --- 4b. Prometheus Config ---
cat <<EOF > /tmp/prometheus.yml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'nvidia'
    static_configs:
      - targets: ['192.168.2.57:9835']
EOF

# --- 4c. Docker Compose (Updated with Postgres Init Volume) ---
cat <<EOF > /tmp/cip-infra-compose.yml
services:
  redis:
    image: redis:7-alpine
    container_name: cip_redis
    command: ["redis-server", "--maxmemory", "512mb", "--maxmemory-policy", "allkeys-lru"]
    ports: ["6379:6379"]
    security_opt:
      - apparmor:unconfined
    restart: always

  postgres:
    image: postgres:15-alpine
    container_name: cip_postgres
    environment:
      POSTGRES_USER: cip_user
      POSTGRES_PASSWORD: cip_password
      POSTGRES_DB: cip_entities
    volumes:
      - postgres_data:/var/lib/postgresql/data
      # AUTOMATIC SCHEMA INJECTION
      - ./init-audit-ledger.sql:/docker-entrypoint-initdb.d/init-audit-ledger.sql
    ports: ["5432:5432"]
    security_opt:
      - apparmor:unconfined
    restart: always

  qdrant:
    image: qdrant/qdrant:latest
    container_name: cip_qdrant
    volumes:
      - qdrant_data:/qdrant/storage
    ports: ["6333:6333", "6334:6334"]
    security_opt:
      - apparmor:unconfined
    restart: always

  minio:
    image: minio/minio
    container_name: cip_minio
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: admin
      MINIO_ROOT_PASSWORD: password123
    volumes:
      - minio_data:/data
    ports: ["9000:9000", "9001:9001"]
    security_opt:
      - apparmor:unconfined
    restart: always

  prometheus:
    image: prom/prometheus:latest
    container_name: cip_prometheus
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    ports: ["9090:9090"]
    security_opt:
      - apparmor:unconfined
    restart: always

  grafana:
    image: grafana/grafana:latest
    container_name: cip_grafana
    ports: ["3000:3000"]
    security_opt:
      - apparmor:unconfined
    depends_on:
      - prometheus
    restart: always

  loki:
    image: grafana/loki:latest
    container_name: cip_loki
    ports: ["3100:3100"]
    security_opt:
      - apparmor:unconfined
    command: -config.file=/etc/loki/local-config.yaml
    restart: always

volumes:
  postgres_data:
  qdrant_data:
  minio_data:
EOF

# Push configs to LXC
pct push $TARGET_ID /tmp/prometheus.yml /opt/cip-stack/prometheus.yml
pct push $TARGET_ID /tmp/cip-infra-compose.yml /opt/cip-stack/docker-compose.yml
pct push $TARGET_ID /tmp/init-audit-ledger.sql /opt/cip-stack/init-audit-ledger.sql

echo "--- Step 5: Launching Stack ---"
pct exec $TARGET_ID -- bash -c "cd /opt/cip-stack && docker compose up -d"

echo "--- Cleanup ---"
rm /tmp/prometheus.yml /tmp/cip-infra-compose.yml /tmp/init-audit-ledger.sql

echo "Infrastructure deployed successfully with Audit Ledger!"
pct exec $TARGET_ID -- ip -4 addr show eth0 | grep inet