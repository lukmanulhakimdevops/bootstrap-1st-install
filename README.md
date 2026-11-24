# bootstrap-1st-install.sh

Skrip Day-0 untuk menyiapkan server/VM yang masih kosong sampai siap menjalankan
`ansible-playbook site.yml` pada **Sovereign PostgreSQL DBaaS v3**
(Ansible + Docker Swarm + OpenVPN + Pola 1 DB-per-Store).

Skrip ini idempoten: aman dijalankan ulang setelah memperbaiki kesalahan.

---

## Daftar isi

1. [Gambaran umum](#gambaran-umum)
2. [Prasyarat](#prasyarat)
3. [Quick start](#quick-start)
4. [Mode 1: `--managed`](#mode-1---managed)
5. [Mode 2: `--control`](#mode-2---control)
6. [Opsi CLI](#opsi-cli)
7. [Variabel environment](#variabel-environment)
8. [Format `DB_HOSTS` dan `STORE_LIST_SPEC`](#format-db_hosts-dan-store_list_spec)
9. [File yang dihasilkan](#file-yang-dihasilkan)
10. [Pengaman bawaan](#pengaman-bawaan)
11. [Troubleshooting](#troubleshooting)
12. [Catatan](#catatan)

---

## Gambaran umum

```
 ┌──────────────────────┐   SSH key + python3    ┌──────────────────────────┐
 │  Control Node        │ ─────────────────────► │ backup (OpenVPN Hub,     │
 │  (--control)         │                        │         Swarm manager-1) │
 │  ansible-core        │ ─────────────────────► │ db1..dbN (PostgreSQL)    │
 │  inventory + vars    │                        │ monitoring / app         │
 └──────────────────────┘                        └──────────────────────────┘
                                                   (--managed, opsional)
```

| Mode | Dijalankan di | Tujuan |
|---|---|---|
| `--managed` | Tiap VM baru (opsional) | Pasang prasyarat Ansible managed node, tanam SSH public key, atur sshd |
| `--control` | Control Node / Bastion / node `backup` | Pasang Ansible, siapkan proyek & inventory, distribusi SSH key, ping, deploy |

## Prasyarat

- OS **Debian/Ubuntu** (butuh `apt-get`) dan akses **root** (`sudo`).
- Koneksi internet ke mirror apt, PyPI, dan Ansible Galaxy.
- Untuk `--control`: arsip proyek `ansible-pg-dbaas-swarm-v3.zip` (atau proyek sudah ada di `WORK_DIR`).
- Akses SSH awal ke tiap target: password root (`SSH_PASS`) **atau** public key Control Node sudah tertanam via mode `--managed`.
- Jika `SSH_USER` bukan root: user tersebut harus punya `sudo` tanpa password di target.
- Sumber daya yang disarankan: RAM ≥ 2 GB untuk node DB/Swarm, ≥ 8 GB untuk monitoring (ELK), disk bebas ≥ 10 GB di `/var/lib` (di bawah itu hanya diberi peringatan).

## Quick start

**A. Di tiap VM baru (opsional)**

```bash
sudo ./bootstrap-1st-install.sh --managed \
  --hostname node-db1 \
  --pubkey-file ./control.pub
```

Lewati langkah ini bila password root SSH sudah aktif; Control Node akan memasang key lewat `SSH_PASS`.

**B. Di Control Node**

```bash
export OVPN_PUBLIC_ENDPOINT="vpn.example.com"
export BACKUP_SSH_IP="203.0.113.10"  BACKUP_VPN_IP="10.88.0.1"
export MON_SSH_IP="198.51.100.20"    MON_VPN_IP="10.88.0.20"
export DB_HOSTS="1:db1:198.51.100.11:10.88.0.11:manager:100:yes,2:db2:198.51.100.12:10.88.0.12:manager:90:yes,3:db3:198.51.100.13:10.88.0.13:worker:0:no"
export STORE_LIST_SPEC="STR01:store1:monitoring:8069:odoo_store1,STR02:store2:monitoring:8070:odoo_store2,STR03:store3:monitoring:8071:odoo_store3"
# Opsional, agar distribusi SSH key tidak interaktif:
# export SSH_PASS="PasswordRootSementara"

sudo -E ./bootstrap-1st-install.sh --control \
  --zip ./ansible-pg-dbaas-swarm-v3.zip --auto-deploy
```

> **Gunakan `sudo -E`** agar variabel environment ikut terbawa.
> Selalu coba dulu dengan `--dry-run` untuk melihat rencana tanpa mengubah sistem.

## Mode 1: `--managed`

Urutan kerja:

1. Preflight: OS, RAM, disk, konektivitas mirror (hanya peringatan).
2. Set hostname (bila `--hostname`): validasi RFC 1123, sinkronkan `127.0.1.1` di `/etc/hosts`, dan set `preserve_hostname` cloud-init agar tidak dikembalikan saat reboot.
3. Pasang paket: `openssh-server openssh-client python3 python3-apt sudo acl curl ca-certificates gnupg`.
4. Aktifkan service SSH.
5. Tanam public key Control Node ke `/root/.ssh/authorized_keys` (divalidasi dengan `ssh-keygen`, tanpa duplikat).
6. Konfigurasi sshd lewat `/etc/ssh/sshd_config.d/00-ansible-bootstrap.conf`:
   - `PubkeyAuthentication yes`
   - `PermitRootLogin prohibit-password` **hanya jika** pubkey berhasil ditanam
   - divalidasi dengan `sshd -t`; bila gagal, perubahan di-rollback otomatis.

Jika tidak ada pubkey yang diberikan, `PermitRootLogin` **tidak diubah** supaya `ssh-copy-id` via password dari Control Node tetap bisa dipakai.

## Mode 2: `--control`

| Langkah | Yang dilakukan |
|---|---|
| Preflight | OS, resource, konektivitas, parsing & validasi topologi, cek placeholder |
| 1/6 | Pasang `python3 python3-pip python3-venv sshpass openssh-client git curl unzip ca-certificates`, lalu pastikan `ansible-core >= 2.15` (venv `/opt/ansible-venv` bila belum ada/terlalu lama) |
| 2/6 | Install collections `community.docker`, `community.general`, `ansible.posix` |
| 3/6 | Buat keypair ed25519 di `SSH_KEY_PATH` bila belum ada (`.pub` dibuat ulang bila hilang) |
| 4/6 | Ekstrak zip ke `WORK_DIR` (lewati bila `site.yml` sudah ada), `chmod go-w`, install `requirements.yml` bila ada |
| 5/6 | Generate `inventory/hosts.yml`, patch `inventory/group_vars/all.yml` |
| 6/6 | `ssh-copy-id` (+ `sshpass` bila `SSH_PASS`) dan raw-bootstrap `python3`, `python3-apt`, `acl`, `sudo` ke semua host |
| Akhir | `ansible -i inventory/hosts.yml all -m ping`; bila `--auto-deploy`, lanjut `ansible-playbook -i inventory/hosts.yml site.yml` |

Jika satu atau lebih host gagal pada langkah 6/6, semua host tetap dicoba dulu, lalu kegagalannya dirangkum dalam satu pesan error.

## Opsi CLI

| Opsi | Mode | Keterangan |
|---|---|---|
| `--managed` / `--control` | — | Pilih salah satu (wajib) |
| `--hostname <nama>` | managed | Set hostname |
| `--pubkey-file <path>` | managed | File public key Control Node |
| `--pubkey-string "<key>"` | managed | Public key sebagai string |
| `--zip <file.zip>` | control | Arsip proyek Ansible |
| `--work-dir <dir>` | control | Tujuan ekstrak proyek |
| `--auto-deploy` | control | Lanjut ke `ansible-playbook site.yml` |
| `--skip-ssh-bootstrap` | control | Lewati distribusi SSH key (ping tetap berjalan) |
| `--dry-run` | keduanya | Tampilkan rencana tanpa mengubah sistem |
| `-h`, `--help` | — | Tampilkan bantuan |

## Variabel environment

**Topologi & jaringan (control)**

| Variabel | Default | Keterangan |
|---|---|---|
| `OVPN_PUBLIC_ENDPOINT` | `vpn.domain-lo.com` | Hostname/IP publik OpenVPN Hub |
| `OVPN_PORT` | `1194` | Port OpenVPN |
| `OVPN_PROTO` | `udp` | `udp` atau `tcp` |
| `BACKUP_SSH_IP` / `BACKUP_VPN_IP` | `203.0.113.10` / `10.88.0.1` | Node backup (Hub OpenVPN + Swarm manager-1) |
| `MON_SSH_IP` / `MON_VPN_IP` | `198.51.100.20` / `10.88.0.20` | Node monitoring/app |
| `DB_HOSTS` | 3 node contoh | Lihat [format](#format-db_hosts-dan-store_list_spec) |
| `STORE_LIST_SPEC` | 3 store contoh | Kosongkan (`""`) untuk menonaktifkan Pola 1 |

**Koneksi SSH & proyek (control)**

| Variabel | Default | Keterangan |
|---|---|---|
| `SSH_USER` | `root` | User SSH Day-0 (non-root otomatis memakai `ansible_become` & `sudo -n`) |
| `SSH_PORT` | `22` | Port SSH |
| `SSH_PASS` | kosong | Password sementara untuk `sshpass` (di-`unset` setelah distribusi) |
| `SSH_KEY_PATH` | `/root/.ssh/id_ed25519` | Path private key Control Node (harus absolut) |
| `WORK_DIR` | `/opt/ansible-pg-dbaas-swarm-v3` | Lokasi proyek Ansible |
| `ANSIBLE_ZIP` | `./ansible-pg-dbaas-swarm-v3.zip` | Arsip proyek |
| `ANSIBLE_CORE_MIN` | `2.15` | Versi minimum ansible-core |
| `ANSIBLE_VENV` | `/opt/ansible-venv` | Lokasi venv bila ansible-core perlu dipasang |

**Managed node**

| Variabel | Default | Keterangan |
|---|---|---|
| `NODE_HOSTNAME` | kosong | Setara `--hostname` |
| `PUBKEY_FILE` / `PUBKEY_STRING` | kosong | Setara `--pubkey-file` / `--pubkey-string` |
| `ALLOW_ROOT_PUBKEY` | `1` | Set `0` agar konfigurasi sshd tidak disentuh |
| `CONNECTIVITY_HOST` | otomatis | Host uji konektivitas (mis. mirror internal) |

**Flag & override**

| Variabel | Default | Keterangan |
|---|---|---|
| `DRY_RUN` / `AUTO_DEPLOY` / `SKIP_SSH_BOOTSTRAP` | `0` | Setara opsi CLI |
| `ALLOW_BAD_QUORUM` | `0` | `1` = izinkan jumlah Swarm manager genap/< 3 (lab/non-HA) |
| `ALLOW_PLACEHOLDER` | `0` | `1` = izinkan nilai contoh (TEST-NET, `vpn.domain-lo.com`) |
| `ANSIBLE_VAULT_PASSWORD_FILE` | kosong | Dipakai saat `--auto-deploy` bila `vault.yml` terenkripsi |

## Format `DB_HOSTS` dan `STORE_LIST_SPEC`

**`DB_HOSTS`**: entri dipisah koma, field dipisah titik dua:

```
id:name:ssh_ip:vpn_ip:swarm_role:priority:sync_eligible
```

| Field | Aturan |
|---|---|
| `id` | Angka, unik (menjadi `repmgr_node_id`) |
| `name` | Huruf kecil/angka/`-`/`_`, diawali huruf, unik; `backup` dan `monitoring` dicadangkan |
| `ssh_ip`, `vpn_ip` | IPv4 valid dan unik (VPN IP juga tidak boleh sama dengan backup/monitoring) |
| `swarm_role` | `manager` atau `worker` (default `worker`) |
| `priority` | Angka (default `100`) |
| `sync_eligible` | `yes` atau `no` (default `yes`) |

- Minimal 2 node DB.
- Node **pertama** dalam daftar dijadikan primary (`is_primary: true`).
- **Kuorum Swarm**: `backup` dihitung sebagai manager pertama. Total manager harus **ganjil dan ≥ 3** (mis. `backup` + `db1` + `db2`).

**`STORE_LIST_SPEC`** (Pola 1 DB-per-Store):

```
code:name:swarm_host:http_port:db_name[:db_user]
```

- `db_name` dan `db_user` harus berupa identifier PostgreSQL aman (`[a-z_][a-z0-9_]*`); `db_user` default sama dengan `db_name`.
- `code` dan `name` harus unik, dan `http_port` tidak boleh bentrok pada `swarm_host` yang sama.
- `swarm_host` yang tidak dikenal di inventory hanya menghasilkan peringatan.

## File yang dihasilkan

```
$WORK_DIR/
├── inventory/
│   ├── hosts.yml                 # digenerate (ditimpa tiap run)
│   └── group_vars/all.yml        # dipatch: ovpn_public_endpoint, ovpn_port, ovpn_proto, store_nodes
└── .bootstrap-backup/            # di luar inventory/ agar tidak terbaca Ansible
    ├── all.yml.orig              # salinan all.yml sebelum run pertama
    └── hosts.yml.<timestamp>     # hosts.yml lama bila isinya berubah
```

Blok `store_nodes` di `all.yml` dibungkus penanda `# BEGIN/END bootstrap-managed store_nodes`.
Jangan edit di dalam penanda tersebut; perubahan akan ditimpa saat skrip dijalankan ulang.

Group inventory yang dibuat: `backup_nodes`, `db_nodes`, `monitoring_nodes`, `app_nodes`.

## Pengaman bawaan

- **Tolak nilai placeholder**: `203.0.113.x`, `198.51.100.x`, `192.0.2.x`, dan `vpn.domain-lo.com` membuat skrip berhenti (kecuali `--dry-run` atau `ALLOW_PLACEHOLDER=1`).
- **Validasi kuorum Swarm** (override: `ALLOW_BAD_QUORUM=1`).
- **Anti-lockout SSH**: pubkey ditanam sebelum sshd diubah; `sshd -t` gagal berarti rollback.
- **Backup otomatis** untuk `all.yml` dan `hosts.yml`.
- **Tanpa password di argumen proses**: `sshpass -e` memakai environment, bukan `-p`.

## Troubleshooting

| Gejala | Penyebab / solusi |
|---|---|
| `Nilai masih berupa placeholder/contoh` | Isi environment dengan nilai sebenarnya, atau `ALLOW_PLACEHOLDER=1` bila disengaja |
| `Kuorum Raft wajib GANJIL dan >= 3` | Perbaiki `swarm_role` di `DB_HOSTS`, atau `ALLOW_BAD_QUORUM=1` untuk lab |
| `ssh-copy-id … gagal` | Cek password/`SSH_PASS`, firewall, dan `PermitRootLogin`/`PasswordAuthentication` di target. Bila VM di-reinstall dengan IP sama: `ssh-keygen -R <ip>` |
| `Ansible ping gagal` | Periksa pesan per-host; pastikan `python3` ada di target dan `SSH_KEY_PATH` benar |
| `site.yml tidak ditemukan di dalam …zip` | Struktur arsip salah; `site.yml` harus berada di root arsip atau di satu folder top-level |
| `ansible.cfg` diabaikan | Direktori world-writable. Skrip sudah menjalankan `chmod go-w`; periksa bila proyek dipindah manual |
| `Validasi 'sshd -t' gagal` | Ada opsi tidak valid di `sshd_config`; perubahan skrip sudah di-rollback, perbaiki lalu jalankan ulang |
| Hostname kembali ke nilai lama setelah reboot | Biasanya cloud-init; skrip menulis `preserve_hostname: true` bila `/etc/cloud/cloud.cfg.d` ada |
| Playbook meminta vault password saat `--auto-deploy` | Set `ANSIBLE_VAULT_PASSWORD_FILE`, atau jalankan dari terminal interaktif (otomatis `--ask-vault-pass`) |

## Catatan

- **Lokasi vault**: file `inventory/group_vars/vault.yml` hanya berlaku untuk grup bernama `vault`, kecuali `site.yml` memuatnya lewat `vars_files`. Jika variabel vault harus berlaku global, letakkan di `inventory/group_vars/all/vault.yml`.
- Skrip hanya mendukung **IPv4**.
- Ansible versi apt di distro lama (mis. Ubuntu 22.04) terlalu lama untuk collection terbaru, karena itu skrip memakai venv bila versi sistem < `ANSIBLE_CORE_MIN`.
- Setelah deploy, hapus password sementara di target dan batasi `PermitRootLogin`/`PasswordAuthentication` sesuai kebijakan keamanan Anda.
