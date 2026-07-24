#!/usr/bin/env bash
# =============================================================================
# `docker compose up -d` dan KEYIN bir marta ishlatiladi:
#   ./bootstrap.sh
#
# Qiladi:
#   1. ILM retention siyosati (busiz disk to'ladi)
#   2. Snapshot repozitoriysi
#   3. Kunlik avtomatik snapshot (SLM)
# =============================================================================
set -euo pipefail

ES="http://localhost:9200"
AUTH="elastic:${ELASTIC_PASSWORD:?ELASTIC_PASSWORD kerak: export ELASTIC_PASSWORD=... yoki  set -a; source .env; set +a}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
SHARD_SIZE="${SHARD_SIZE:-10gb}"

echo "==> Elasticsearch kutilmoqda..."
for i in $(seq 1 60); do
  if curl -sf -u "${AUTH}" "${ES}/_cluster/health?wait_for_status=yellow&timeout=2s" >/dev/null; then
    echo "    tayyor"
    break
  fi
  [[ $i -eq 60 ]] && { echo "ES ko'tarilmadi. docker compose logs es01" >&2; exit 1; }
  sleep 5
done

# -----------------------------------------------------------------------------
# 1. ILM
#
# Filebeat/Metricbeat o'z siyosatlarini yaratadi, lekin ularda o'chirish fazasi
# yo'q — ya'ni loglar abadiy saqlanadi. Buni almashtiramiz.
#
# Single-node klasterda warm/cold fazalar KERAK EMAS: ular ma'lumotni boshqa
# hardware profilidagi node'larga ko'chirish uchun, sizda ko'chiradigan joy yo'q.
# -----------------------------------------------------------------------------
apply_ilm() {
  local policy="$1"
  echo "==> ILM: ${policy} (${RETENTION_DAYS} kun)"
  curl -sf -u "${AUTH}" -X PUT "${ES}/_ilm/policy/${policy}" \
    -H 'Content-Type: application/json' \
    -d "{
      \"policy\": {
        \"phases\": {
          \"hot\": {
            \"actions\": {
              \"rollover\": {
                \"max_primary_shard_size\": \"${SHARD_SIZE}\",
                \"max_age\": \"1d\"
              }
            }
          },
          \"delete\": {
            \"min_age\": \"${RETENTION_DAYS}d\",
            \"actions\": { \"delete\": {} }
          }
        }
      }
    }" >/dev/null
  echo "    ok"
}

apply_ilm filebeat
apply_ilm metricbeat

# -----------------------------------------------------------------------------
# 2. Snapshot repozitoriysi
#
# DIQQAT: ishlab turgan ES ning data katalogini tar/rsync bilan nusxalash
# BACKUP EMAS. Lucene segmentlari o'zgarib turadi — yarim yozilgan, tiklab
# bo'lmaydigan nusxa olasiz. Faqat snapshot API ishonchli.
# -----------------------------------------------------------------------------
echo "==> Snapshot repozitoriysi"
curl -sf -u "${AUTH}" -X PUT "${ES}/_snapshot/local" \
  -H 'Content-Type: application/json' \
  -d '{
    "type": "fs",
    "settings": {
      "location": "/usr/share/elasticsearch/snapshots",
      "compress": true
    }
  }' >/dev/null
echo "    ok"

# -----------------------------------------------------------------------------
# 3. SLM — kunlik snapshot (basic litsenziyada bepul)
#
# Snapshot'lar inkremental: birinchisi to'liq, keyingilari faqat o'zgargan
# segmentlarni qo'shadi. Disk hajmi ikki barobar oshmaydi.
# -----------------------------------------------------------------------------
echo "==> SLM: har kuni 02:30"
curl -sf -u "${AUTH}" -X PUT "${ES}/_slm/policy/daily" \
  -H 'Content-Type: application/json' \
  -d '{
    "schedule": "0 30 2 * * ?",
    "name": "<daily-{now/d}>",
    "repository": "local",
    "config": {
      "indices": ["*"],
      "include_global_state": true
    },
    "retention": {
      "expire_after": "30d",
      "min_count": 5,
      "max_count": 30
    }
  }' >/dev/null
echo "    ok"

echo
echo "==> Tekshiruv"
curl -s -u "${AUTH}" "${ES}/_cluster/health?pretty" | grep -E '"(status|number_of_nodes)"'
echo
curl -s -u "${AUTH}" "${ES}/_cat/indices?v&s=index" | head -20
echo
echo "Snapshot'ni qo'lda sinash:"
echo "  curl -u elastic:PAROL -X POST ${ES}/_slm/policy/daily/_execute"
echo "  curl -s -u elastic:PAROL ${ES}/_snapshot/local/_all?pretty | head -30"