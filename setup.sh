#!/usr/bin/env bash
# =============================================================================
# Xost tayyorgarligi. Bir marta, root huquqi bilan ishlatiladi:
#   sudo ./setup-host.sh
# =============================================================================
set -euo pipefail

ELK_DATA_ROOT="${ELK_DATA_ROOT:-/var/lib/elk}"

if [[ $EUID -ne 0 ]]; then
  echo "root kerak:  sudo $0" >&2
  exit 1
fi

echo "==> 1/5  vm.max_map_count"
# Elasticsearch mmap ishlatadi. Busiz umuman ko'tarilmaydi:
#   "max virtual memory areas vm.max_map_count [65530] is too low"
cat > /etc/sysctl.d/99-elasticsearch.conf <<'EOF'
vm.max_map_count=262144
EOF
sysctl --system >/dev/null
echo "    vm.max_map_count = $(sysctl -n vm.max_map_count)"

echo "==> 2/5  swap o'chirilmoqda"
# Heap diskka tushsa GC pauzalari soniyalarga cho'ziladi va node "o'lgan"
# deb hisoblanadi. bootstrap.memory_lock buni oldini oladi, lekin swap
# butunlay o'chirilgani ishonchliroq.
swapoff -a || true
sed -i.bak '/[[:space:]]swap[[:space:]]/s/^\(.*\)$/#\1/' /etc/fstab
echo "    /etc/fstab zaxirasi: /etc/fstab.bak"

echo "==> 3/5  Docker log rotatsiyasi"
# Bu qadam ELK'ga emas, umuman serverga tegishli. Sozlanmasa
# /var/lib/docker/containers cheksiz o'sib root diskni to'ldiradi.
if [[ -f /etc/docker/daemon.json ]]; then
  echo "    /etc/docker/daemon.json allaqachon mavjud — qo'lda tekshiring:"
  echo '      "log-opts": { "max-size": "50m", "max-file": "3" }'
else
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
  systemctl restart docker
  echo "    daemon.json yozildi, docker qayta ishga tushirildi"
fi

echo "==> 4/5  Ma'lumot kataloglari: ${ELK_DATA_ROOT}"
mkdir -p "${ELK_DATA_ROOT}"/{esdata,kibanadata,filebeatdata,metricbeatdata,snapshots}

# Elasticsearch va Kibana konteyner ichida uid=1000, gid=0 bilan ishlaydi.
# Bu qadam o'tkazib yuborilsa ES "AccessDeniedException" bilan yiqiladi —
# bind mount'dagi eng ko'p uchraydigan xato.
chown -R 1000:0 "${ELK_DATA_ROOT}/esdata" \
                "${ELK_DATA_ROOT}/kibanadata" \
                "${ELK_DATA_ROOT}/snapshots"
chmod -R 770    "${ELK_DATA_ROOT}/esdata" \
                "${ELK_DATA_ROOT}/kibanadata" \
                "${ELK_DATA_ROOT}/snapshots"
echo "    tayyor"

echo "==> 5/5  Firewall eslatmasi"
# 9200 va 5601 compose'da 127.0.0.1 ga bog'langan — tashqaridan ko'rinmaydi.
# Kibana'ga kirish uchun SSH tunnel:
#   ssh -L 5601:127.0.0.1:5601 user@server
echo "    9200/5601 faqat localhost'da. Kirish uchun SSH tunnel ishlating."

echo
echo "Bajarildi. Endi:"
echo "  cp .env.example .env"
echo "  sed -i \"s/^ENCRYPTION_KEY=.*/ENCRYPTION_KEY=\$(openssl rand -hex 32)/\" .env"
echo "  chmod 600 .env"
echo "  docker compose up -d"