#!/usr/bin/env bash
# =============================================================================
#  bootstrap-1st-install.sh — Day-0 First-Install Bootstrap untuk
#  Sovereign PostgreSQL DBaaS v3 (Ansible + Docker Swarm + OpenVPN + Pola 1)
# =============================================================================
#  Menjembatani kondisi VM/server baru ("kosongan") hingga siap menjalankan
#  `ansible-playbook site.yml` secara penuh tanpa konfigurasi manual berulang:
#
#    MODE 1: --managed  (Jalankan di tiap VM baru: backup, db1..dbN, monitoring)
#      - Set hostname OS (opsional via --hostname <nama>)
#      - Pasang prasyarat minimum Ansible Managed Node:
#        openssh-server, openssh-client, python3, python3-apt, sudo, acl, curl,
#        ca-certificates, gnupg
#      - Tanamkan SSH public key Control Node (--pubkey-file / --pubkey-string /
#        PUBKEY_FILE / PUBKEY_STRING) SEBELUM sshd diubah (anti-lockout)
#      - Aktifkan PubkeyAuthentication; PermitRootLogin prohibit-password HANYA
#        bila public key berhasil ditanam (jika tidak, login password root
#        dibiarkan agar ssh-copy-id dari Control Node tetap bisa dipakai)
#      - Preflight: OS (Debian/Ubuntu), RAM, Disk /var/lib, konektivitas mirror
#
#    MODE 2: --control  (Jalankan di Control Node / Bastion / atau di `backup`)
#      - Pasang sshpass, unzip, python3, git, dll + ansible-core >= 2.15
#        (venv /opt/ansible-venv bila versi sistem tidak ada/terlalu lama)
#      - Pasang Ansible Galaxy collections (community.docker, general, posix)
#      - Generate SSH ed25519 keypair (~/.ssh/id_ed25519) bila belum ada
#      - Validasi input (IP, port, nama, duplikat) & kuorum Swarm Manager
#        (wajib ganjil >= 3: mis. backup, db1, db2; override: ALLOW_BAD_QUORUM=1)
#      - Tolak nilai placeholder/contoh (TEST-NET, vpn.domain-lo.com) kecuali
#        ALLOW_PLACEHOLDER=1
#      - Otomatis ekstrak `ansible-pg-dbaas-swarm-v3.zip` ke WORK_DIR
#      - Auto-generate `inventory/hosts.yml` & patch `ovpn_public_endpoint`,
#        `ovpn_port`, `ovpn_proto`, serta `store_nodes` pada
#        `inventory/group_vars/all.yml` (idempoten, backup di .bootstrap-backup/)
#      - Distribusikan SSH key ke seluruh host (`ssh-copy-id` / `sshpass`) +
#        raw-SSH bootstrap `python3`, `python3-apt`, `acl`, `sudo` bila kosongan
#      - Jalankan preflight `ansible all -m ping`
#      - Jika `--auto-deploy` aktif -> langsung eksekusi `ansible-playbook site.yml`
#
#  OPSI:
#    --managed | --control        Pilih mode (wajib salah satu)
#    --hostname <nama>            (managed) set hostname
#    --pubkey-file <path>         (managed) file public key Control Node
#    --pubkey-string "<key>"      (managed) public key sebagai string
#    --zip <file.zip>             (control) arsip proyek Ansible
#    --work-dir <dir>             (control) tujuan ekstrak proyek
#    --auto-deploy                (control) lanjut `ansible-playbook site.yml`
#    --skip-ssh-bootstrap         (control) lewati distribusi SSH key (ping tetap jalan)
#    --dry-run                    Tampilkan rencana tanpa mengubah sistem
#    -h | --help                  Bantuan ini
#
#  CONTOH PEMAKAIAN CEPAT:
#    # A. Di setiap VM baru (opsional jika root SSH password sudah aktif, cukup langsung ke B):
#    sudo ./bootstrap-1st-install.sh --managed --hostname node-db1 --pubkey-file ./control.pub
#
#    # B. Di Control Node (1 perintah siapkan semua + auto-deploy!):
#    export OVPN_PUBLIC_ENDPOINT="vpn.domain-lo.com"
#    export BACKUP_SSH_IP="203.0.113.10"  BACKUP_VPN_IP="10.88.0.1"
#    export MON_SSH_IP="198.51.100.20"    MON_VPN_IP="10.88.0.20"
#    export DB_HOSTS="1:db1:198.51.100.11:10.88.0.11:manager:100:yes,2:db2:198.51.100.12:10.88.0.12:manager:90:yes,3:db3:198.51.100.13:10.88.0.13:worker:0:no"
#    export STORE_LIST_SPEC="STR01:store1:monitoring:8069:odoo_store1,STR02:store2:monitoring:8070:odoo_store2,STR03:store3:monitoring:8071:odoo_store3"
#    # Opsional untuk distribusi SSH key tanpa prompt interaktif:
#    # export SSH_PASS="PasswordRootSementara"
#    # Catatan: node DB pertama di DB_HOSTS dijadikan primary (is_primary: true).
#
#    sudo -E ./bootstrap-1st-install.sh --control --zip ./ansible-pg-dbaas-swarm-v3.zip --auto-deploy
# =============================================================================
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 022

# ============================ KONFIGURASI ====================================
WORK_DIR="${WORK_DIR:-/opt/ansible-pg-dbaas-swarm-v3}"
ANSIBLE_ZIP="${ANSIBLE_ZIP:-./ansible-pg-dbaas-swarm-v3.zip}"

# Endpoint publik OpenVPN Hub (IP statis atau DDNS node backup)
OVPN_PUBLIC_ENDPOINT="${OVPN_PUBLIC_ENDPOINT:-vpn.domain-lo.com}"
OVPN_PORT="${OVPN_PORT:-1194}"
OVPN_PROTO="${OVPN_PROTO:-udp}"

# Node Backup (Hub OpenVPN + Swarm Manager-1) & Monitoring/App
BACKUP_SSH_IP="${BACKUP_SSH_IP:-203.0.113.10}"
BACKUP_VPN_IP="${BACKUP_VPN_IP:-10.88.0.1}"
MON_SSH_IP="${MON_SSH_IP:-198.51.100.20}"
MON_VPN_IP="${MON_VPN_IP:-10.88.0.20}"

# Format DB_HOSTS: "id:name:ssh_ip:vpn_ip:swarm_role:priority:sync_eligible"
DB_HOSTS="${DB_HOSTS:-1:db1:198.51.100.11:10.88.0.11:manager:100:yes,2:db2:198.51.100.12:10.88.0.12:manager:90:yes,3:db3:198.51.100.13:10.88.0.13:worker:0:no}"

# Format STORE_LIST_SPEC (Pola 1 DB-per-Store): "code:name:swarm_host:http_port:db_name[:db_user]"
# Catatan: tanpa titik-dua (:-) agar STORE_LIST_SPEC="" bisa dipakai untuk MENONAKTIFKAN Pola 1.
STORE_LIST_SPEC="${STORE_LIST_SPEC-STR01:store1:monitoring:8069:odoo_store1,STR02:store2:monitoring:8070:odoo_store2,STR03:store3:monitoring:8071:odoo_store3}"

# Koneksi SSH Day-0
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
SSH_PASS="${SSH_PASS:-}"                          # Opsional: untuk sshpass non-interaktif saat 1st install
SSH_KEY_PATH="${SSH_KEY_PATH:-/root/.ssh/id_ed25519}"

# Opsi Mode Managed Node
NODE_HOSTNAME="${NODE_HOSTNAME:-}"
PUBKEY_STRING="${PUBKEY_STRING:-}"
PUBKEY_FILE="${PUBKEY_FILE:-}"
ALLOW_ROOT_PUBKEY="${ALLOW_ROOT_PUBKEY:-1}"
CONNECTIVITY_HOST="${CONNECTIVITY_HOST:-}"        # Override host uji konektivitas (mis. mirror internal)

# Opsi Mode Control Node
ANSIBLE_CORE_MIN="${ANSIBLE_CORE_MIN:-2.15}"
ANSIBLE_VENV="${ANSIBLE_VENV:-/opt/ansible-venv}"
ALLOW_PLACEHOLDER="${ALLOW_PLACEHOLDER:-0}"
ALLOW_BAD_QUORUM="${ALLOW_BAD_QUORUM:-0}"

# Flags runtime
DRY_RUN="${DRY_RUN:-0}"
AUTO_DEPLOY="${AUTO_DEPLOY:-0}"
SKIP_SSH_BOOTSTRAP="${SKIP_SSH_BOOTSTRAP:-0}"

# Runtime state
PUBKEY_INSTALLED=0
CLEANUP_PATHS=()
SSH_OPTS=(-p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
APT_ENV=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a)
APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3)

# Runtime topology arrays
DB_NAMES=()
declare -A DB_ID=() DB_SSH_IP=() DB_VPN_IP=() DB_SWARM_ROLE=() DB_PRIO=() DB_SYNC=()
STORE_NAMES=()
declare -A ST_CODE=() ST_HOST=() ST_PORT=() ST_DB=() ST_USER=()

# Skrip yang dikirim via SSH ke target Day-0 (POSIX sh; dijalankan sebagai root / sudo -n)
read -r -d '' REMOTE_PREP <<'EOF' || true
set -e
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
need=""
command -v python3 >/dev/null 2>&1 || need="$need python3"
for p in python3-apt acl sudo; do
  dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
done
if [ -n "$need" ]; then
  apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update -qq
  # shellcheck disable=SC2086
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq $need
fi
EOF

# ============================== UTILITAS =====================================
if [[ -t 2 ]]; then C_B=$'\033[1;34m'; C_G=$'\033[1;32m'; C_R=$'\033[1;31m'; C_Y=$'\033[1;33m'; C_0=$'\033[0m'; else C_B=""; C_G=""; C_R=""; C_Y=""; C_0=""; fi
log()  { printf '%s[bootstrap]%s %s\n' "$C_B" "$C_0" "$*" >&2; }
ok()   { printf '%s[bootstrap OK]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s[bootstrap WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[bootstrap ERROR]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

on_err() {
  local rc=$1 line=$2 cmd=$3
  printf '%s[bootstrap] gagal di baris %s (exit %s): %s%s\n' "$C_R" "$line" "$rc" "$cmd" "$C_0" >&2
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

cleanup() {
  local p
  for p in "${CLEANUP_PATHS[@]:-}"; do
    if [[ -n "$p" ]]; then rm -rf -- "$p"; fi
  done
}
trap cleanup EXIT

run_or_dry() {
  if (( DRY_RUN )); then log "[DRY-RUN] $*"; return 0; fi
  "$@"
}

apt_update()  { run_or_dry "${APT_ENV[@]}" apt-get "${APT_OPTS[@]}" update -qq; }
apt_install() { run_or_dry "${APT_ENV[@]}" apt-get "${APT_OPTS[@]}" install -y -qq "$@"; }

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_ipv4() {
  local o
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}
is_port()           { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_name()           { [[ $1 =~ ^[a-z][a-z0-9_-]{0,62}$ ]]; }
is_pg_ident()       { [[ $1 =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }
is_placeholder_ip() { [[ $1 == 203.0.113.* || $1 == 198.51.100.* || $1 == 192.0.2.* ]]; }
is_hostname() {
  (( ${#1} <= 253 )) || return 1
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

version_ge() {  # true bila $1 >= $2 (urutan versi)
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n '1p')" == "$2" ]]
}

check_debian_os() {
  command -v apt-get >/dev/null 2>&1 || die "Skrip ini membutuhkan OS berbasis Debian/Ubuntu (apt-get)."
  local pretty="Debian/Ubuntu" id="" id_like=""
  if [[ -r /etc/os-release ]]; then
    IFS='|' read -r pretty id id_like < <(. /etc/os-release; printf '%s|%s|%s\n' "${PRETTY_NAME:-Debian/Ubuntu}" "${ID:-}" "${ID_LIKE:-}")
    log "OS terdeteksi: ${pretty}"
    case " ${id} ${id_like} " in
      *" debian "*|*" ubuntu "*) ;;
      *) warn "ID OS '${id}' bukan Debian/Ubuntu murni; dilanjutkan karena apt-get tersedia." ;;
    esac
  fi
}

preflight_resources() {
  local mem_mb disk_gb
  mem_mb=$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)
  disk_gb=$(df -BG --output=avail /var/lib 2>/dev/null | awk 'NR==2 {gsub(/[^0-9]/,"",$1); print $1}' || true)
  [[ ${mem_mb:-} =~ ^[0-9]+$ ]]  || mem_mb=0
  [[ ${disk_gb:-} =~ ^[0-9]+$ ]] || disk_gb=0
  log "Preflight Resource Lokal: RAM=${mem_mb}MB | Free Disk /var/lib=${disk_gb}GB"
  if (( mem_mb > 0 && mem_mb < 1500 )); then
    warn "RAM < 1.5GB (${mem_mb}MB) — untuk DB/Swarm disarankan min. 2GB RAM, Monitoring ELK min. 8GB RAM."
  fi
  if (( disk_gb > 0 && disk_gb < 10 )); then
    warn "Free disk /var/lib < 10GB (${disk_gb}GB) — image Docker & data PostgreSQL membutuhkan ruang lebih."
  fi
}

preflight_connectivity() {
  local host="$CONNECTIVITY_HOST" id="" port
  if [[ -z "$host" ]]; then
    id=$( . /etc/os-release 2>/dev/null && printf '%s' "${ID:-}" ) || true
    case "$id" in
      ubuntu) host="archive.ubuntu.com" ;;
      *)      host="deb.debian.org" ;;
    esac
  fi
  if ! getent hosts "$host" >/dev/null 2>&1; then
    warn "Preflight konektivitas: DNS '${host}' gagal resolve — apt/pip/galaxy kemungkinan gagal (set CONNECTIVITY_HOST bila memakai mirror internal)."
    return 0
  fi
  for port in 443 80; do
    if timeout 6 bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null; then
      ok "Preflight konektivitas: ${host}:${port} dapat dijangkau."
      return 0
    fi
  done
  warn "Preflight konektivitas: ${host} resolve tetapi port 443/80 tidak dapat dijangkau."
  return 0
}

# ==================== VALIDASI & PARSING TOPOLOGI ============================
parse_cluster_specs() {
  DB_NAMES=(); STORE_NAMES=()
  DB_ID=(); DB_SSH_IP=(); DB_VPN_IP=(); DB_SWARM_ROLE=(); DB_PRIO=(); DB_SYNC=()
  ST_CODE=(); ST_HOST=(); ST_PORT=(); ST_DB=(); ST_USER=()

  local raw entry id name sip vip srole prio sync mgr_count=1
  local code sname shost sport sdb suser
  local -a raw_entries=() entries=() sentries=()
  local -A seen_id=() seen_sip=() seen_vip=() seen_code=() seen_hostport=()

  seen_vip["$BACKUP_VPN_IP"]="backup"
  seen_vip["$MON_VPN_IP"]="monitoring"

  IFS=',' read -ra raw_entries <<< "$DB_HOSTS"
  for raw in "${raw_entries[@]:-}"; do
    entry=$(trim "$raw")
    if [[ -n "$entry" ]]; then entries+=("$entry"); fi
  done
  (( ${#entries[@]} >= 2 )) || die "DB_HOSTS minimal berisi 2 node DB."

  for entry in "${entries[@]}"; do
    IFS=':' read -r id name sip vip srole prio sync <<< "$entry"
    id=$(trim "${id:-}"); name=$(trim "${name:-}"); sip=$(trim "${sip:-}"); vip=$(trim "${vip:-}")
    srole=$(trim "${srole:-}"); prio=$(trim "${prio:-}"); sync=$(trim "${sync:-}")
    srole="${srole:-worker}"; prio="${prio:-100}"; sync="${sync:-yes}"

    [[ -n $id && -n $name && -n $sip && -n $vip ]] \
      || die "Format DB_HOSTS salah: '${entry}' (butuh id:name:ssh_ip:vpn_ip:swarm_role:priority:sync)"
    [[ $id =~ ^[0-9]+$ ]]            || die "DB_HOSTS '${entry}': id harus angka."
    is_name "$name"                  || die "DB_HOSTS '${entry}': name '${name}' tidak valid (huruf kecil, angka, '-', '_'; diawali huruf)."
    [[ $name != "backup" && $name != "monitoring" ]] \
                                     || die "DB_HOSTS '${entry}': nama '${name}' dicadangkan untuk node backup/monitoring."
    is_ipv4 "$sip"                   || die "DB_HOSTS '${entry}': ssh_ip '${sip}' bukan IPv4 valid."
    is_ipv4 "$vip"                   || die "DB_HOSTS '${entry}': vpn_ip '${vip}' bukan IPv4 valid."
    [[ $srole == "manager" || $srole == "worker" ]] \
                                     || die "DB_HOSTS '${entry}': swarm_role harus manager|worker."
    [[ $prio =~ ^[0-9]+$ ]]          || die "DB_HOSTS '${entry}': priority harus angka."
    [[ $sync == "yes" || $sync == "no" ]] \
                                     || die "DB_HOSTS '${entry}': sync_eligible harus yes|no."

    [[ -z ${DB_ID[$name]:-} ]]       || die "DB_HOSTS: nama node duplikat '${name}'."
    [[ -z ${seen_id[$id]:-} ]]       || die "DB_HOSTS: id duplikat '${id}' (${seen_id[$id]:-} & ${name})."
    [[ -z ${seen_sip[$sip]:-} ]]     || die "DB_HOSTS: ssh_ip duplikat '${sip}' (${seen_sip[$sip]:-} & ${name})."
    [[ -z ${seen_vip[$vip]:-} ]]     || die "DB_HOSTS: vpn_ip duplikat '${vip}' (${seen_vip[$vip]:-} & ${name})."
    seen_id[$id]="$name"; seen_sip[$sip]="$name"; seen_vip[$vip]="$name"

    DB_NAMES+=("$name")
    DB_ID[$name]="$id"; DB_SSH_IP[$name]="$sip"; DB_VPN_IP[$name]="$vip"
    DB_SWARM_ROLE[$name]="$srole"; DB_PRIO[$name]="$prio"; DB_SYNC[$name]="$sync"
    if [[ "$srole" == "manager" ]]; then
      mgr_count=$(( mgr_count + 1 ))
    fi
  done

  # Validasi kuorum Raft Docker Swarm (backup = manager-1 + manager di db_nodes)
  if (( mgr_count < 3 || mgr_count % 2 == 0 )); then
    local qmsg="Jumlah Swarm Manager = ${mgr_count} (backup + manager di DB_HOSTS). Kuorum Raft wajib GANJIL dan >= 3 (mis. backup + db1 + db2 = 3)."
    if [[ "$ALLOW_BAD_QUORUM" == "1" ]]; then
      warn "${qmsg} Dilanjutkan karena ALLOW_BAD_QUORUM=1."
    else
      die "${qmsg} Perbaiki swarm_role di DB_HOSTS, atau set ALLOW_BAD_QUORUM=1 untuk lab/non-HA."
    fi
  else
    ok "Validasi kuorum Raft Swarm: ${mgr_count} Managers (ganjil, aman terhadap kegagalan $(( (mgr_count - 1) / 2 )) manager)."
  fi

  if [[ -n "$(trim "$STORE_LIST_SPEC")" ]]; then
    IFS=',' read -ra raw_entries <<< "$STORE_LIST_SPEC"
    for raw in "${raw_entries[@]:-}"; do
      entry=$(trim "$raw")
      if [[ -n "$entry" ]]; then sentries+=("$entry"); fi
    done
    for entry in "${sentries[@]}"; do
      IFS=':' read -r code sname shost sport sdb suser <<< "$entry"
      code=$(trim "${code:-}"); sname=$(trim "${sname:-}"); shost=$(trim "${shost:-}")
      sport=$(trim "${sport:-}"); sdb=$(trim "${sdb:-}"); suser=$(trim "${suser:-}")

      [[ -n $code && -n $sname && -n $shost && -n $sport && -n $sdb ]] \
        || die "Format STORE_LIST_SPEC salah: '${entry}' (butuh code:name:swarm_host:http_port:db_name[:db_user])"
      [[ $code =~ ^[A-Za-z0-9_-]+$ ]] || die "STORE_LIST_SPEC '${entry}': code hanya boleh [A-Za-z0-9_-]."
      is_name "$sname"                || die "STORE_LIST_SPEC '${entry}': name '${sname}' tidak valid."
      is_port "$sport"                || die "STORE_LIST_SPEC '${entry}': http_port '${sport}' tidak valid."
      is_pg_ident "$sdb"              || die "STORE_LIST_SPEC '${entry}': db_name '${sdb}' bukan identifier PostgreSQL aman (huruf kecil/angka/_)."
      suser="${suser:-$sdb}"
      is_pg_ident "$suser"            || die "STORE_LIST_SPEC '${entry}': db_user '${suser}' bukan identifier PostgreSQL aman."

      [[ -z ${ST_CODE[$sname]:-} ]]        || die "STORE_LIST_SPEC: nama store duplikat '${sname}'."
      [[ -z ${seen_code[$code]:-} ]]       || die "STORE_LIST_SPEC: code duplikat '${code}'."
      [[ -z ${seen_hostport["${shost}:${sport}"]:-} ]] \
                                           || die "STORE_LIST_SPEC: bentrok port ${sport} pada host '${shost}' (${seen_hostport["${shost}:${sport}"]:-} & ${sname})."
      seen_code[$code]="$sname"; seen_hostport["${shost}:${sport}"]="$sname"

      if [[ $shost != "backup" && $shost != "monitoring" && -z ${DB_ID[$shost]:-} ]]; then
        warn "STORE_LIST_SPEC '${sname}': swarm_host '${shost}' tidak ada di inventory (backup/monitoring/${DB_NAMES[*]})."
      fi

      STORE_NAMES+=("$sname")
      ST_CODE[$sname]="$code"; ST_HOST[$sname]="$shost"
      ST_PORT[$sname]="$sport"; ST_DB[$sname]="$sdb"; ST_USER[$sname]="$suser"
    done
  fi
}

validate_control_config() {
  [[ $SSH_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "SSH_USER '${SSH_USER}' tidak valid."
  is_port "$SSH_PORT"                    || die "SSH_PORT '${SSH_PORT}' tidak valid."
  [[ $SSH_KEY_PATH == /* ]]              || die "SSH_KEY_PATH harus path absolut (saat ini: '${SSH_KEY_PATH}')."
  [[ $SSH_KEY_PATH =~ ^[A-Za-z0-9_./+@~-]+$ ]] \
                                         || die "SSH_KEY_PATH hanya boleh berisi karakter [A-Za-z0-9_./+@~-]."
  [[ $OVPN_PUBLIC_ENDPOINT =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
                                         || die "OVPN_PUBLIC_ENDPOINT '${OVPN_PUBLIC_ENDPOINT}' tidak valid (hostname/IPv4)."
  is_port "$OVPN_PORT"                   || die "OVPN_PORT '${OVPN_PORT}' tidak valid."
  [[ $OVPN_PROTO == "udp" || $OVPN_PROTO == "tcp" ]] || die "OVPN_PROTO harus udp|tcp."
  is_ipv4 "$BACKUP_SSH_IP"               || die "BACKUP_SSH_IP '${BACKUP_SSH_IP}' bukan IPv4 valid."
  is_ipv4 "$BACKUP_VPN_IP"               || die "BACKUP_VPN_IP '${BACKUP_VPN_IP}' bukan IPv4 valid."
  is_ipv4 "$MON_SSH_IP"                  || die "MON_SSH_IP '${MON_SSH_IP}' bukan IPv4 valid."
  is_ipv4 "$MON_VPN_IP"                  || die "MON_VPN_IP '${MON_VPN_IP}' bukan IPv4 valid."
  [[ "$BACKUP_VPN_IP" != "$MON_VPN_IP" ]] || die "BACKUP_VPN_IP dan MON_VPN_IP tidak boleh sama (${BACKUP_VPN_IP})."
  return 0
}

check_placeholders() {
  local -a hits=()
  local d
  if [[ "$OVPN_PUBLIC_ENDPOINT" == "vpn.domain-lo.com" ]]; then hits+=("OVPN_PUBLIC_ENDPOINT=${OVPN_PUBLIC_ENDPOINT}"); fi
  if is_placeholder_ip "$BACKUP_SSH_IP"; then hits+=("BACKUP_SSH_IP=${BACKUP_SSH_IP}"); fi
  if is_placeholder_ip "$MON_SSH_IP"; then hits+=("MON_SSH_IP=${MON_SSH_IP}"); fi
  for d in "${DB_NAMES[@]}"; do
    if is_placeholder_ip "${DB_SSH_IP[$d]}"; then hits+=("${d}=${DB_SSH_IP[$d]}"); fi
  done
  (( ${#hits[@]} > 0 )) || return 0

  local msg="Nilai masih berupa placeholder/contoh (TEST-NET / vpn.domain-lo.com): ${hits[*]}"
  if (( DRY_RUN )) || [[ "$ALLOW_PLACEHOLDER" == "1" ]]; then
    warn "${msg} (dilanjutkan: dry-run/ALLOW_PLACEHOLDER=1)"
  else
    die "${msg}. Isi environment dengan nilai sebenarnya, atau set ALLOW_PLACEHOLDER=1 bila memang disengaja."
  fi
}

# ==================== MODE 1: MANAGED NODE DAY-0 PREP ========================
configure_hostname() {
  [[ -n "$NODE_HOSTNAME" ]] || return 0
  is_hostname "$NODE_HOSTNAME" || die "Hostname '${NODE_HOSTNAME}' tidak valid (RFC 1123)."

  log "Mengatur hostname sistem menjadi: ${NODE_HOSTNAME}"
  if (( DRY_RUN )); then
    log "[DRY-RUN] hostnamectl set-hostname ${NODE_HOSTNAME}; sinkronkan 127.0.1.1 di /etc/hosts; preserve_hostname cloud-init"
    return 0
  fi

  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$NODE_HOSTNAME"
  else
    printf '%s\n' "$NODE_HOSTNAME" > /etc/hostname
    hostname "$NODE_HOSTNAME"
  fi

  local short="${NODE_HOSTNAME%%.*}" hosts_line
  hosts_line="127.0.1.1 ${NODE_HOSTNAME}"
  if [[ "$short" != "$NODE_HOSTNAME" ]]; then hosts_line+=" ${short}"; fi
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s|^127\.0\.1\.1[[:space:]].*|${hosts_line}|" /etc/hosts
  else
    printf '%s\n' "$hosts_line" >> /etc/hosts
  fi

  # Cegah cloud-init mengembalikan hostname lama saat reboot
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
  fi
}

enable_ssh_service() {
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    warn "systemd tidak aktif (container?) — lewati 'systemctl enable --now ssh'."
    return 0
  fi
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd \
    || die "Gagal mengaktifkan service SSH (ssh/sshd)."
}

reload_ssh_service() {
  local svc
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    for svc in ssh sshd; do
      if systemctl is-active --quiet "$svc"; then
        systemctl reload "$svc" && return 0
      fi
    done
  fi
  warn "Service SSH tidak aktif/tidak ditemukan — reload dilewati."
  return 0
}

install_control_pubkey() {
  local pub="" line tmpk added=0
  if [[ -n "$PUBKEY_FILE" ]]; then
    [[ -r "$PUBKEY_FILE" ]] || die "File pubkey tidak dapat dibaca: ${PUBKEY_FILE}"
    pub="$(cat "$PUBKEY_FILE")"
  elif [[ -n "$PUBKEY_STRING" ]]; then
    pub="$PUBKEY_STRING"
  fi
  pub="${pub//$'\r'/}"
  [[ -n "$(trim "$pub")" ]] || return 0

  log "Menanamkan SSH public key Control Node ke /root/.ssh/authorized_keys..."
  if (( DRY_RUN )); then
    log "[DRY-RUN] Validasi & tambahkan public key ke /root/.ssh/authorized_keys"
    PUBKEY_INSTALLED=1
    return 0
  fi

  install -d -m 0700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  tmpk=$(mktemp); CLEANUP_PATHS+=("$tmpk")

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(trim "$line")
    if [[ -z "$line" || "$line" == \#* ]]; then continue; fi
    printf '%s\n' "$line" > "$tmpk"
    ssh-keygen -l -f "$tmpk" >/dev/null 2>&1 || die "Public key tidak valid: '${line:0:40}...'"
    if ! grep -qxF -- "$line" /root/.ssh/authorized_keys; then
      printf '%s\n' "$line" >> /root/.ssh/authorized_keys
    fi
    added=$(( added + 1 ))
  done <<< "$pub"

  (( added > 0 )) || die "Tidak ada public key valid yang ditemukan pada input pubkey."
  PUBKEY_INSTALLED=1
  ok "${added} public key terpasang di /root/.ssh/authorized_keys."
}

configure_sshd() {
  if [[ "$ALLOW_ROOT_PUBKEY" != "1" ]]; then
    log "ALLOW_ROOT_PUBKEY!=1 — konfigurasi sshd tidak diubah."
    return 0
  fi

  local conf=/etc/ssh/sshd_config.d/00-ansible-bootstrap.conf
  local legacy=/etc/ssh/sshd_config.d/99-ansible-bootstrap.conf
  local main=/etc/ssh/sshd_config main_bak=/etc/ssh/sshd_config.bak-bootstrap
  local main_modified=0 sshd_bin eff

  if (( DRY_RUN )); then
    log "[DRY-RUN] Tulis ${conf} (PubkeyAuthentication yes$( (( PUBKEY_INSTALLED )) && printf ', PermitRootLogin prohibit-password' )), sshd -t, reload ssh"
    return 0
  fi

  sshd_bin=$(command -v sshd || true); sshd_bin="${sshd_bin:-/usr/sbin/sshd}"
  [[ -x "$sshd_bin" ]] || die "Binary sshd tidak ditemukan."
  install -d -m 0755 /run/sshd /etc/ssh/sshd_config.d

  # Drop-in dibaca urut leksikal & first-match-wins -> prefix 00- agar menang atas file lain.
  rm -f -- "$legacy"
  {
    printf 'PubkeyAuthentication yes\n'
    if (( PUBKEY_INSTALLED )); then
      printf 'PermitRootLogin prohibit-password\n'
    fi
  } > "$conf"
  if (( ! PUBKEY_INSTALLED )); then
    warn "Tidak ada public key yang ditanam -> PermitRootLogin TIDAK diubah (agar ssh-copy-id via password dari Control Node tetap bisa)."
  fi

  # Distro lama (mis. Ubuntu 20.04) tidak punya Include untuk sshd_config.d
  if [[ -f "$main" ]] && ! grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$main"; then
    log "sshd_config tidak memuat sshd_config.d — menambahkan Include di baris pertama (backup: ${main_bak})."
    if [[ ! -f "$main_bak" ]]; then cp -a "$main" "$main_bak"; fi
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$main"
    main_modified=1
  fi

  if ! "$sshd_bin" -t; then
    rm -f -- "$conf"
    if (( main_modified )) && [[ -f "$main_bak" ]]; then cp -a "$main_bak" "$main"; fi
    die "Validasi 'sshd -t' gagal — perubahan konfigurasi SSH dibatalkan (rollback)."
  fi
  reload_ssh_service

  eff=$("$sshd_bin" -T 2>/dev/null || true)
  if ! grep -qi '^pubkeyauthentication yes' <<< "$eff"; then
    warn "Konfigurasi efektif sshd belum menunjukkan PubkeyAuthentication yes — periksa 'sshd -T' & file di sshd_config.d."
  fi
  ok "sshd dikonfigurasi (${conf})."
}

run_managed_bootstrap() {
  (( DRY_RUN || EUID == 0 )) || die "Mode --managed harus dijalankan sebagai root (gunakan sudo)."
  check_debian_os
  preflight_resources
  preflight_connectivity
  configure_hostname

  log "Memasang paket minimum Day-0 Ansible Managed Node..."
  apt_update
  apt_install --no-install-recommends \
    openssh-server openssh-client python3 python3-apt sudo acl curl ca-certificates gnupg

  enable_ssh_service
  # Urutan penting: public key ditanam SEBELUM sshd diubah (anti-lockout)
  install_control_pubkey
  configure_sshd

  if (( DRY_RUN )); then
    ok "[DRY-RUN] Selesai — tidak ada perubahan pada sistem."
  else
    ok "Managed Node '$(hostname -s)' SIAP dikelola Ansible dari Control Node!"
  fi
}

# ==================== MODE 2: CONTROL NODE DAY-0 PREP ========================
ansible_core_version() {
  command -v ansible >/dev/null 2>&1 || return 0
  ansible --version 2>/dev/null | sed -n '1s/.*\[core \([0-9][0-9.]*\)\].*/\1/p' || true
}

install_ansible_venv() {
  log "Membuat venv ${ANSIBLE_VENV} & memasang ansible-core>=${ANSIBLE_CORE_MIN} dari PyPI..."
  python3 -m venv "$ANSIBLE_VENV"
  "$ANSIBLE_VENV/bin/pip" install --quiet --upgrade pip
  "$ANSIBLE_VENV/bin/pip" install --quiet "ansible-core>=${ANSIBLE_CORE_MIN}"
  local b
  for b in ansible ansible-playbook ansible-galaxy ansible-vault ansible-inventory ansible-config ansible-doc; do
    if [[ -x "$ANSIBLE_VENV/bin/$b" ]]; then ln -sf "$ANSIBLE_VENV/bin/$b" "/usr/local/bin/$b"; fi
  done
  hash -r
}

ensure_ansible_core() {
  local ver
  ver=$(ansible_core_version)
  if [[ -n "$ver" ]] && version_ge "$ver" "$ANSIBLE_CORE_MIN"; then
    log "Ansible core ${ver} sudah memadai (>= ${ANSIBLE_CORE_MIN})."
    return 0
  fi
  log "Ansible core ${ver:-tidak terpasang/versi lama} tidak memenuhi >= ${ANSIBLE_CORE_MIN}."
  install_ansible_venv
  ver=$(ansible_core_version)
  [[ -n "$ver" ]] || die "Instalasi ansible-core gagal (ansible --version tidak terbaca)."
  version_ge "$ver" "$ANSIBLE_CORE_MIN" || die "ansible-core ${ver} < ${ANSIBLE_CORE_MIN} setelah instalasi."
  ok "Ansible core ${ver} siap ($(command -v ansible))."
}

install_ansible_control_deps() {
  log "[1/6] Memasang prasyarat Ansible Control Node (ansible-core, sshpass, unzip, python3)..."
  apt_update
  apt_install python3 python3-pip python3-venv sshpass openssh-client git curl unzip ca-certificates

  if (( DRY_RUN )); then
    log "[DRY-RUN] Pastikan ansible-core >= ${ANSIBLE_CORE_MIN} (venv ${ANSIBLE_VENV} bila perlu)"
  else
    ensure_ansible_core
  fi

  log "[2/6] Memasang Ansible Galaxy collections (community.docker, community.general, ansible.posix)..."
  run_or_dry ansible-galaxy collection install community.docker community.general ansible.posix
}

ensure_control_ssh_key() {
  log "[3/6] Menyiapkan SSH keypair Control Node (${SSH_KEY_PATH})..."
  if (( DRY_RUN )); then
    log "[DRY-RUN] Pastikan ${SSH_KEY_PATH} ada (ssh-keygen -t ed25519)"
    return 0
  fi
  install -d -m 0700 "$(dirname "$SSH_KEY_PATH")"
  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "ansible-dbaas@$(hostname -s)" -f "$SSH_KEY_PATH"
    ok "SSH keypair baru dibuat: ${SSH_KEY_PATH}"
  else
    chmod 600 "$SSH_KEY_PATH"
    log "Menggunakan SSH keypair yang sudah ada: ${SSH_KEY_PATH}"
  fi
  if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
    log "File ${SSH_KEY_PATH}.pub tidak ada — diturunkan dari private key."
    ssh-keygen -y -f "$SSH_KEY_PATH" > "${SSH_KEY_PATH}.pub" \
      || die "Gagal menurunkan public key (private key ber-passphrase?). Buat ${SSH_KEY_PATH}.pub secara manual."
    chmod 644 "${SSH_KEY_PATH}.pub"
  fi
}

unpack_ansible_project() {
  log "[4/6] Menyiapkan direktori proyek Ansible di ${WORK_DIR}..."
  if [[ -f "${WORK_DIR}/site.yml" ]]; then
    log "Proyek Ansible sudah ada di ${WORK_DIR} (melewati ekstraksi zip)."
  elif [[ -f "$ANSIBLE_ZIP" ]]; then
    if (( DRY_RUN )); then
      log "[DRY-RUN] unzip -qo ${ANSIBLE_ZIP} -> ${WORK_DIR}"
      return 0
    fi
    local tmpu src
    local -a tops=()
    tmpu=$(mktemp -d); CLEANUP_PATHS+=("$tmpu")
    unzip -qo "$ANSIBLE_ZIP" -d "$tmpu"
    src="$tmpu"
    if [[ ! -f "${src}/site.yml" ]]; then
      mapfile -t tops < <(find "$tmpu" -mindepth 1 -maxdepth 1 ! -name '__MACOSX')
      if (( ${#tops[@]} == 1 )) && [[ -d "${tops[0]}" ]]; then src="${tops[0]}"; fi
    fi
    [[ -f "${src}/site.yml" ]] || die "site.yml tidak ditemukan di dalam ${ANSIBLE_ZIP} (struktur arsip tidak sesuai)."
    mkdir -p "$WORK_DIR"
    cp -a "${src}/." "${WORK_DIR}/"
    ok "Arsip ${ANSIBLE_ZIP} diekstrak ke ${WORK_DIR}"
  else
    if (( DRY_RUN )); then
      log "[DRY-RUN] Asumsikan proyek Ansible diekstrak ke ${WORK_DIR} dari ${ANSIBLE_ZIP}"
      return 0
    fi
    die "File ${ANSIBLE_ZIP} tidak ditemukan dan ${WORK_DIR}/site.yml belum ada. Berikan path lewat --zip <file.zip>."
  fi

  if (( DRY_RUN )); then return 0; fi

  # Ansible mengabaikan ansible.cfg pada direktori world-writable (zip dari Windows sering 777)
  chmod -R go-w "$WORK_DIR"

  local req
  for req in "${WORK_DIR}/requirements.yml" "${WORK_DIR}/collections/requirements.yml"; do
    if [[ -f "$req" ]]; then
      log "Memasang collections dari ${req}..."
      ansible-galaxy collection install -r "$req"
      break
    fi
  done
}

emit_inventory() {
  local d is_pri sync_b
  cat <<EOF
---
# Auto-generated by bootstrap-1st-install.sh — akan ditimpa saat skrip dijalankan ulang
all:
  vars:
    ansible_user: "${SSH_USER}"
    ansible_port: ${SSH_PORT}
    ansible_ssh_private_key_file: "${SSH_KEY_PATH}"
    ansible_python_interpreter: /usr/bin/python3
EOF
  if [[ "$SSH_USER" != "root" ]]; then
    printf '    ansible_become: true\n'
  fi
  cat <<EOF
  children:
    backup_nodes:
      hosts:
        backup:
          ansible_host: "${BACKUP_SSH_IP}"
          vpn_ip: "${BACKUP_VPN_IP}"
          swarm_role: manager

    db_nodes:
      hosts:
EOF
  for d in "${DB_NAMES[@]}"; do
    is_pri="false"; sync_b="false"
    if [[ "$d" == "${DB_NAMES[0]}" ]]; then is_pri="true"; fi
    if [[ "${DB_SYNC[$d]}" == "yes" ]]; then sync_b="true"; fi
    cat <<EOF
        ${d}:
          ansible_host: "${DB_SSH_IP[$d]}"
          vpn_ip: "${DB_VPN_IP[$d]}"
          swarm_role: ${DB_SWARM_ROLE[$d]}
          repmgr_node_id: ${DB_ID[$d]}
          repmgr_priority: ${DB_PRIO[$d]}
          is_primary: ${is_pri}
          sync_eligible: ${sync_b}
EOF
  done
  cat <<EOF

    monitoring_nodes:
      hosts:
        monitoring:
          ansible_host: "${MON_SSH_IP}"
          vpn_ip: "${MON_VPN_IP}"
          swarm_role: worker

    app_nodes:
      hosts:
        monitoring:
          ansible_host: "${MON_SSH_IP}"
          vpn_ip: "${MON_VPN_IP}"
          swarm_role: worker
EOF
}

emit_store_block() {
  local s
  echo "# BEGIN bootstrap-managed store_nodes (Pola 1 DB-per-Store) — auto-generated by bootstrap-1st-install.sh"
  echo "store_nodes:"
  for s in "${STORE_NAMES[@]}"; do
    cat <<EOF
  - code: "${ST_CODE[$s]}"
    name: "${s}"
    swarm_host: "${ST_HOST[$s]}"
    http_port: ${ST_PORT[$s]}
    db_name: "${ST_DB[$s]}"
    db_user: "${ST_USER[$s]}"
EOF
  done
  echo "# END bootstrap-managed store_nodes"
}

yaml_set_scalar() {  # file key value(sudah berformat YAML & tervalidasi) — ganti bila ada, tambah bila belum
  local f=$1 k=$2 v=$3
  if grep -Eq "^${k}:" "$f"; then
    sed -i -E "s|^${k}:.*|${k}: ${v}|" "$f"
  else
    printf '%s: %s\n' "$k" "$v" >> "$f"
  fi
}

patch_group_vars() {
  local vars_file=$1 bak_dir=$2 tmp_all
  if [[ ! -f "$vars_file" ]]; then
    warn "${vars_file} tidak ada — dibuat baru."
    printf -- '---\n' > "$vars_file"
  elif [[ ! -f "${bak_dir}/all.yml.orig" ]]; then
    cp -a "$vars_file" "${bak_dir}/all.yml.orig"
  fi

  yaml_set_scalar "$vars_file" ovpn_public_endpoint "\"${OVPN_PUBLIC_ENDPOINT}\""
  yaml_set_scalar "$vars_file" ovpn_port "${OVPN_PORT}"
  yaml_set_scalar "$vars_file" ovpn_proto "\"${OVPN_PROTO}\""

  if (( ${#STORE_NAMES[@]} > 0 )); then
    tmp_all=$(mktemp); CLEANUP_PATHS+=("$tmp_all")
    # Hapus blok bertanda BEGIN/END milik skrip ini, lalu blok `store_nodes:` bawaan zip
    # (termasuk item list di kolom-0 & baris kosong di dalam blok). Komentar yang mendahului key berikutnya dipertahankan.
    awk '
      /^# BEGIN bootstrap-managed store_nodes/ { mskip=1; next }
      mskip { if ($0 ~ /^# END bootstrap-managed store_nodes/) mskip=0; next }
      /^store_nodes:/ { skip=1; buf=""; next }
      skip {
        if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]/ || $0 ~ /^-/) { buf=""; next }
        if ($0 ~ /^#/) { buf = buf $0 "\n"; next }
        skip=0; printf "%s", buf; buf=""
      }
      { print }
    ' "$vars_file" > "$tmp_all"
    # Buang baris kosong di akhir file (cegah penumpukan baris kosong tiap dijalankan ulang)
    sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$tmp_all"
    { echo ""; emit_store_block; } >> "$tmp_all"
    cat "$tmp_all" > "$vars_file"   # cat (bukan mv) agar mode/owner file asli terjaga
    ok "Daftar Pola 1 (${#STORE_NAMES[@]} stores) ditulis langsung ke ${vars_file}"
  fi
}

generate_inventory_and_vars() {
  log "[5/6] Men-generate inventory/hosts.yml & menyelaraskan group_vars/all.yml..."
  local inv_file="${WORK_DIR}/inventory/hosts.yml"
  local vars_file="${WORK_DIR}/inventory/group_vars/all.yml"
  local bak_dir="${WORK_DIR}/.bootstrap-backup"   # di luar inventory/ agar tidak terbaca Ansible

  if (( DRY_RUN )); then
    log "[DRY-RUN] Generate ${inv_file} (backup=${BACKUP_SSH_IP}, dbs=${DB_NAMES[*]}, mon=${MON_SSH_IP})"
    log "[DRY-RUN] Update ovpn_public_endpoint=${OVPN_PUBLIC_ENDPOINT}, ovpn_port, ovpn_proto & ${#STORE_NAMES[@]} store_nodes di ${vars_file}"
    return 0
  fi

  mkdir -p "${WORK_DIR}/inventory/group_vars" "$bak_dir"

  local tmp_inv
  tmp_inv=$(mktemp); CLEANUP_PATHS+=("$tmp_inv")
  emit_inventory > "$tmp_inv"
  if [[ -f "$inv_file" ]] && ! cmp -s "$tmp_inv" "$inv_file"; then
    cp -a "$inv_file" "${bak_dir}/hosts.yml.$(date +%Y%m%d%H%M%S)"
    log "hosts.yml lama dibackup ke ${bak_dir}/"
  fi
  install -m 0644 "$tmp_inv" "$inv_file"

  patch_group_vars "$vars_file" "$bak_dir"
  ok "Inventory siap di ${inv_file}"
}

distribute_to_target() {  # NB: dipanggil dalam `if` -> set -e nonaktif, gunakan `|| return 1` eksplisit
  local tname=$1 tip=$2 pfx=""
  if [[ "$SSH_USER" != "root" ]]; then pfx="sudo -n "; fi

  # 1. Uji apakah key-based SSH sudah jalan
  if ! ssh "${SSH_OPTS[@]}" -i "$SSH_KEY_PATH" -o BatchMode=yes "${SSH_USER}@${tip}" true 2>/dev/null; then
    log "Memasang SSH key ke ${tname} (${SSH_USER}@${tip})..."
    if [[ -n "$SSH_PASS" ]]; then
      SSHPASS="$SSH_PASS" sshpass -e ssh-copy-id "${SSH_OPTS[@]}" -i "${SSH_KEY_PATH}.pub" "${SSH_USER}@${tip}" || {
        warn "ssh-copy-id ke ${tname} (${tip}) gagal. Jika host key berubah (VM di-reinstall): ssh-keygen -R ${tip}"
        return 1
      }
    else
      ssh-copy-id "${SSH_OPTS[@]}" -i "${SSH_KEY_PATH}.pub" "${SSH_USER}@${tip}" || {
        warn "ssh-copy-id ke ${tname} (${tip}) gagal. Jika host key berubah (VM di-reinstall): ssh-keygen -R ${tip}"
        return 1
      }
    fi
  fi

  # 2. Raw SSH bootstrap python3 + python3-apt + acl + sudo jika VM benar-benar minimal
  ssh "${SSH_OPTS[@]}" -i "$SSH_KEY_PATH" -o BatchMode=yes "${SSH_USER}@${tip}" "${pfx}sh -s" <<< "$REMOTE_PREP" || {
    warn "Raw-bootstrap python3/acl di ${tname} (${tip}) gagal (cek koneksi apt/sudo NOPASSWD di target)."
    return 1
  }
  ok "Target ${tname} (${tip}): SSH key + Python3 siap!"
  return 0
}

distribute_ssh_keys() {
  if (( SKIP_SSH_BOOTSTRAP )); then
    log "[6/6] Melewati distribusi SSH key (--skip-ssh-bootstrap)."
    return 0
  fi

  log "[6/6] Distribusi SSH key & raw-bootstrap Python3 ke seluruh target host..."
  local -a targets=("backup:${BACKUP_SSH_IP}" "monitoring:${MON_SSH_IP}") failed=()
  local d item tname tip
  for d in "${DB_NAMES[@]}"; do
    targets+=("${d}:${DB_SSH_IP[$d]}")
  done

  for item in "${targets[@]}"; do
    tname="${item%%:*}"; tip="${item#*:}"
    if (( DRY_RUN )); then
      log "[DRY-RUN] ssh-copy-id -> ${SSH_USER}@${tip} (${tname}) + raw check python3/python3-apt/acl/sudo"
      continue
    fi
    if ! distribute_to_target "$tname" "$tip"; then
      failed+=("${tname}(${tip})")
    fi
  done

  unset SSH_PASS || true   # jangan biarkan password sementara terbawa ke proses Ansible
  (( ${#failed[@]} == 0 )) || die "Distribusi SSH gagal untuk: ${failed[*]}. Perbaiki lalu jalankan ulang (skrip idempoten)."
  return 0
}

preflight_ansible_ping() {
  log "Menjalankan preflight verifikasi: ansible all -m ping..."
  if (( DRY_RUN )); then
    log "[DRY-RUN] (cd ${WORK_DIR} && ansible -i inventory/hosts.yml all -m ping)"
    return 0
  fi
  if ( cd "$WORK_DIR" && ansible -i inventory/hosts.yml all -m ping ); then
    ok "Seluruh node merespons PONG dari Ansible!"
  else
    die "Ansible ping gagal pada satu/lebih node (lihat output di atas)."
  fi
}

run_deploy() {
  local -a args=(-i inventory/hosts.yml site.yml)
  local vault_file="${WORK_DIR}/inventory/group_vars/vault.yml"

  if (( DRY_RUN )); then
    log "[DRY-RUN] (cd ${WORK_DIR} && ansible-playbook ${args[*]})"
    return 0
  fi

  # shellcheck disable=SC2016  # '$' literal pada header vault
  if [[ -f "$vault_file" ]] && head -c 32 "$vault_file" | grep -q '^\$ANSIBLE_VAULT'; then
    if [[ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
      log "vault.yml terenkripsi — memakai ANSIBLE_VAULT_PASSWORD_FILE."
    elif [[ -t 0 ]]; then
      args+=(--ask-vault-pass)
    else
      warn "vault.yml terenkripsi & tidak ada TTY/ANSIBLE_VAULT_PASSWORD_FILE — playbook gagal kecuali ansible.cfg mengatur vault_password_file."
    fi
  fi

  ( cd "$WORK_DIR" && ansible-playbook "${args[@]}" )
  ok "Deployment penuh DBaaS v3 selesai!"
}

run_control_bootstrap() {
  (( DRY_RUN || EUID == 0 )) || die "Mode --control harus dijalankan sebagai root (gunakan sudo -E)."
  check_debian_os
  preflight_resources
  preflight_connectivity
  parse_cluster_specs
  validate_control_config
  check_placeholders
  install_ansible_control_deps
  ensure_control_ssh_key
  unpack_ansible_project
  generate_inventory_and_vars
  distribute_ssh_keys
  preflight_ansible_ping

  if (( AUTO_DEPLOY )); then
    log "Flag --auto-deploy aktif -> mengeksekusi ansible-playbook site.yml..."
    run_deploy
  else
    echo "" >&2
    ok "1st Install Bootstrap Control Node SELESAI!"
    log "Langkah terakhir untuk deploy seluruh cluster (OpenVPN + Swarm + Secrets + Pola 1 Odoo):"
    log "  cd ${WORK_DIR}"
    log "  ansible-playbook -i inventory/hosts.yml site.yml"
    log "  # (Atau tambah Vault dulu: ansible-vault create inventory/group_vars/vault.yml && ansible-playbook -i inventory/hosts.yml site.yml --ask-vault-pass)"
  fi
}

usage() {
  # Cetak seluruh blok komentar header (lewati shebang & garis pemisah) sampai baris non-komentar pertama
  awk 'NR==1 {next} !/^#/ {exit} /^# ====/ {next} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]:-$0}"
}

main() {
  local mode=""
  while (( $# )); do
    case $1 in
      --managed)             [[ -z $mode || $mode == managed ]] || die "Pilih salah satu: --managed atau --control."; mode="managed" ;;
      --control)             [[ -z $mode || $mode == control ]] || die "Pilih salah satu: --managed atau --control."; mode="control" ;;
      --hostname)            NODE_HOSTNAME="${2:?--hostname butuh nilai}"; shift ;;
      --pubkey-file)         PUBKEY_FILE="${2:?--pubkey-file butuh path}"; shift ;;
      --pubkey-string)       PUBKEY_STRING="${2:?--pubkey-string butuh nilai}"; shift ;;
      --zip)                 ANSIBLE_ZIP="${2:?--zip butuh path file zip}"; shift ;;
      --work-dir)            WORK_DIR="${2:?--work-dir butuh path}"; shift ;;
      --auto-deploy)         AUTO_DEPLOY=1 ;;
      --skip-ssh-bootstrap)  SKIP_SSH_BOOTSTRAP=1 ;;
      --dry-run)             DRY_RUN=1 ;;
      -h|--help)             usage; exit 0 ;;
      *)                     die "Opsi tidak dikenal: $1 (gunakan --help)" ;;
    esac
    shift
  done

  case "$mode" in
    managed) run_managed_bootstrap ;;
    control) run_control_bootstrap ;;
    *)       usage >&2; exit 1 ;;
  esac
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
