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

# Runtime
