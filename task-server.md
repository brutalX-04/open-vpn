# task-server.md — Ubah `open-vpn` menjadi API Server OpenVPN / Multi-Tunnel

> Repo: `brutalX-04/open-vpn` · commit yang diaudit: `4ba7239` (2026-08-01)
> Nomor baris di bawah mengacu ke commit itu. Jika bergeser, cari berdasarkan isi kodenya.

## Cara pakai di Copilot (VS Code, Agent mode)

1. Buka repo `open-vpn`, buat branch: `git checkout -b refactor/api-only`.
2. Tempel perintah ini ke Copilot Chat (Agent mode):
   `Baca task-server.md. Kerjakan SATU fase per giliran, urut dari Fase 1. Setelah tiap fase: jalankan verifikasi fase itu, ringkas hasilnya, lalu berhenti dan tunggu saya bilang "lanjut".`
3. Jangan lompat fase. Fase 2 dan 3 adalah fondasi; Fase 4 (API) bergantung padanya.
4. Item bertanda **[VERIFIKASI]** belum bisa dipastikan dari membaca kode. Copilot wajib mengujinya di VPS/VM Debian 12 atau Ubuntu 22.04 sebelum mengandalkannya. Jika hasil uji berbeda, catat di `docs/DECISIONS.md` dan pakai alternatif yang lolos tes.
5. Jika ada ambiguitas, pakai "Keputusan desain" (bagian 2). Jangan bertanya ulang.

---

## 0. Target

| Hapus | Pertahankan | Tambah |
|---|---|---|
| `bot/` (bot.py, xendit_gateway.py, config.json), `bot-vpn.service`, dependensi telegram/qrcode/pillow, prompt token & Xendit di installer, bagian Bot di README, fitur `trial` | Menu internal: `menu`, `menu-ssh`, `menu-xray`, `menu-ovpn`, status, restart, autokill, reboot. **Tampilan menu tidak berubah.** | REST API HTTP yang mudah di-hit dari luar, registry akun, hapus/expire akun tanpa mengganggu user lain, limit sesi per akun yang benar-benar bekerja |

Prinsip: **rapi, bersih, cepat, normal.** Satu sumber logika (library Python) dipakai oleh API, menu, dan cleanup. Tidak ada operasi akun yang me-restart service bersama.

Asumsi: "limit per akun" = batas koneksi/sesi bersamaan per akun (itulah yang ada di repo). Jika yang dimaksud kuota data, itu belum ada di repo dan di luar task ini.

---

## 1. Hasil audit

### 1.1 Kondisi repo saat ini

- **Tidak ada HTTP API.** `scripts/api/cli.py` hanya CLI JSON yang diimpor bot. Action `delete`, `renew`, `list` ada di `argparse` (cli.py:288) tetapi jatuh ke `"Action not supported"` (cli.py:306).
- **Logika ganda dan tidak konsisten.** Pembuatan akun ada di bash (menu) dan di Python (`cli.py`) dengan format expiry, host `.ovpn` (`IP` vs `DOMAIN`), dan cek duplikat yang berbeda.
- **Tidak ada registry.** Sumber kebenaran tersebar: `/etc/shadow` (SSH), field `comment` di `/etc/xray/config.json` (Xray), komentar `# Expired` di file `.ovpn` (OpenVPN).

### 1.2 Temuan

**Kritis**

- **S1 · Command injection.** `cli.py:106` menjalankan `useradd ... '{username}' && echo '{password}...' | passwd` lewat `shell=True` dengan input mentah. Jika API membuka ini ke luar, itu eksekusi perintah sebagai root. Serupa di `scripts/xray/delete.sh:47-48`: `${USERNAME}` disisipkan langsung ke kode Python heredoc.
- **S2 · Akun Xray buatan `cli.py` tidak pernah expire.** `cli.py:141` menulis `comment = "<user> YYYY-MM-DD HH:MM:SS"`, sedangkan `cleanup.sh:54` mem-parse token terakhir sebagai `%Y-%m-%d` (yang didapat: jam) lalu `ValueError` → dilewati selamanya. Akibat samping: regex `xray/renew.sh:31` (`[0-9-]*`) tidak cocok format itu, sehingga renew menyisipkan key `comment` kedua (JSON duplicate key).
- **S3 · Restart massal memutus semua user.** `systemctl restart xray` dipanggil di `cli.py:151`, semua `create-*.sh`, `xray/delete.sh:74`, `xray/renew.sh:65`, `cleanup.sh:104`. `systemctl restart vpn-openvpn-tcp vpn-openvpn-udp` dipanggil di `openvpn/delete.sh:60` dan `cleanup.sh:95`. Setiap satu akun dibuat/dihapus/expired, seluruh user Xray atau seluruh user OpenVPN terputus. Ini pelanggaran terbesar terhadap syarat "tidak mengganggu user lain".

**Tinggi**

- **S4 · Race condition.** Read-modify-write `/etc/xray/config.json` tanpa lock dan non-atomik (`json.dump` langsung ke file). Dua create bersamaan (atau create bertabrakan dengan cleanup tiap menit) bisa saling menimpa atau merusak JSON → Xray gagal start. Hal sama untuk `easyrsa` (`index.txt`, `serial`) yang tidak aman dijalankan paralel.
- **S5 · Hapus akun OpenVPN tidak memutus sesi aktif.** Revoke/CRL hanya dicek saat handshake. Satu-satunya yang kini memutus sesi adalah restart (S3).
- **S6 · Lock sesi OpenVPN bisa stale.** `scripts/system/openvpn-single-session.sh` menyimpan lock di `/run/vpn-openvpn-sessions/<cn>`. Setelah daemon di-restart (S3) atau crash, `client-disconnect` tidak dijamin terpanggil → file tertinggal → user sah ditolak ("denied") sampai reboot. Semantik "tolak koneksi baru" juga merugikan user yang pindah jaringan (UDP baru dianggap mati setelah `keepalive 10 120`, ±120 dtk).
- **S7 · Hook OpenVPN kemungkinan gagal karena izin. [VERIFIKASI]** `server-*.conf` memakai `user nobody`; script `client-connect` berjalan setelah privilege drop. `mkdir -p /run/vpn-openvpn-sessions` dan tulis `/var/log/vpn/session-limit.log` bisa ditolak, dan karena `set -eu`, hook keluar non-nol → **koneksi ditolak**. Uji: connect satu klien, lihat `journalctl -u vpn-openvpn-udp`.
- **S8 · Limit SSH tidak efektif untuk tunnel. [VERIFIKASI]** `scripts/system/vpn-tendang` hanya membaca `who -u` (sesi utmp/tty). Akun dibuat `-s /bin/false` dan dipakai untuk tunnel tanpa pty, jadi biasanya tidak muncul di `who`. Dropbear sama. Uji: buka tunnel `ssh -N`, lalu `who -u`.
- **S9 · AutoKill menu rusak.** `scripts/system/autokill.sh:70` memanggil `/usr/bin/vpn-tendang`, sedangkan installer membuat symlink di `/usr/local/bin/vpn-tendang` (`install.sh:434`). Cron gagal diam-diam. Selain itu bertumpuk dengan `vpn-session-limit.timer` (dua mekanisme untuk hal yang sama).
- **S10 · Masa aktif tidak presisi dan bergantung zona waktu.** `cli.py:98` hanya menyimpan tanggal untuk SSH. `cleanup.sh` membandingkan epoch hari UTC dari `/etc/shadow` (`*86400`, baris 25) dengan epoch tengah malam lokal (`date -d "${TODAY}"`, baris 9). Akibatnya: trial 3 jam bisa terhapus <1 menit (server UTC) atau bertahan sampai hari berikutnya (server UTC+7); "1 hari" sebenarnya hidup sampai tengah malam; OpenVPN memakai aturan lain lagi → umur akun berbeda tiap protokol.
- **S11 · `get_status()` salah.** `cli.py:51` mengecek `openvpn@server-tcp/udp`, padahal unit sebenarnya `vpn-openvpn-tcp/udp` (`install.sh:306-330`) → OpenVPN selalu "stopped". `user_counts` hanya `ssh` dan `xray` gabungan (vmess+vless+trojan tidak dipisah), tidak ada OpenVPN; hitungan SSH = semua uid ≥ 1000 (termasuk user non-VPN); Xray dihitung dengan `content.count('"email"')`.

**Sedang**

- **S12 · CRL bisa kedaluwarsa. [VERIFIKASI nilai `EASYRSA_CRL_DAYS`]** CRL easy-rsa 3 biasanya berlaku 180 hari dan hanya dibuat ulang saat ada penghapusan. Di server sepi, CRL expired → OpenVPN menolak semua koneksi. Sertifikat server default ±825 hari juga akan habis.
- **S13 · Hitungan koneksi OpenVPN di menu/status selalu 0. [VERIFIKASI]** `status.sh:82-83` dan `menu/main.sh:17-18` memakai `grep "^CLIENT_LIST"`, tetapi `server-*.conf` tidak mengatur `status-version 2`.
- **S14 · Info koneksi tidak jujur.** API dan menu menampilkan WS-TLS 443, WS non-TLS 80, gRPC, Dropbear 143/109, Stunnel 447/777, SSH-WS, padahal installer tidak membuat konfigurasi nginx/proxy, inbound gRPC, Dropbear, Stunnel (README mengakuinya). `ws-stunnel` / `ws-dropbear` dipanggil `status.sh:66-67` dan `restart.sh:56,74` tetapi tidak pernah dibuat. Akun yang dikembalikan API tampak valid tetapi tidak bisa tersambung.
- **S15 · Restart BadVPN bentrok.** `restart.sh:59-64,76-81` memakai `pkill` + `screen`, sementara unit systemd `badvpn-*` ber-`Restart=always` → port bentrok dan proses yatim. Seharusnya `systemctl restart`.
- **S16 · Profil `.ovpn` tidak konsisten. [VERIFIKASI]** Menu memakai `remote ${IP}`, API memakai `remote ${DOMAIN}`. `compress lz4-v2` hanya di sisi klien (server tanpa `compress`); uji koneksi nyata, hapus baris itu jika bermasalah.
- **S17 · Duplikat username tidak dicek di API.** Xray tidak mengecek email ganda; SSH/OVPN dicek terpisah; cek di bash memakai `grep` tanpa escape.
- **S18 · Installer tidak idempoten. [VERIFIKASI]** `./easyrsa --batch init-pki` + `build-ca` (`install.sh:224-225`) bila dijalankan ulang dapat menghapus PKI lama dan memutus semua sertifikat klien. `iptables -A` menambah aturan ganda tiap jalan.

### 1.3 Status penghapusan akun (kondisi sekarang)

| Protokol | Hapus manual (menu) | Auto-expire | Dampak ke user lain | Sesi aktif akun itu |
|---|---|---|---|---|
| SSH | `pkill -u` + `userdel --force` (hanya user itu) | Jalan tiap menit, tetapi waktu salah (S10) | Tidak ada | Terputus ✔ |
| Xray | Edit JSON + **restart xray** | **Tidak pernah** untuk akun dari `cli.py` (S2) | **Semua user Xray terputus** (S3) | Terputus (via restart) |
| OpenVPN | Revoke + CRL + **restart TCP & UDP** | Via komentar `.ovpn`, tetapi restart (S3) | **Semua user OpenVPN terputus** + lock stale (S6) | Terputus (via restart) |
| API | Tidak ada (`delete`/`renew`/`list` belum diimplementasi) | – | – | – |

### 1.4 Status limit per akun (kondisi sekarang)

| Protokol | Mekanisme | Status |
|---|---|---|
| OpenVPN | 1 sesi per CN lintas TCP+UDP, via hook `client-connect` + file lock | Berisiko: S6, S7 |
| SSH | 1 sesi via `vpn-session-limit.timer` → `vpn-tendang` (`who -u`) | Kemungkinan tidak efektif untuk tunnel (S8); jalur AutoKill salah (S9) |
| Xray | Tidak ada (README mengakui) | Belum ada |

---

## 2. Keputusan desain (default, jangan ditanyakan ulang)

- **D1 Framework:** FastAPI + uvicorn, Python ≥ 3.10, virtualenv di `/etc/vpn/venv`. Kode terpasang di `/etc/vpn/api` dan `/etc/vpn/vpnctl`.
- **D2 Jaringan:** uvicorn bind `127.0.0.1:8088`. Akses eksternal lewat nginx dengan **HTTPS wajib** (server block `api.<DOMAIN>` atau path `/api/`; sertifikat via certbot). Tanpa domain, installer menampilkan peringatan keras bahwa API key akan lewat jaringan tanpa TLS dan menolak membuka akses eksternal secara default.
- **D3 Auth:** header `X-API-Key`. Key acak ≥ 32 byte (base64url) dibuat installer ke `/etc/vpn/api.env` (mode 0600, root). Bandingkan dengan `hmac.compare_digest`. Rotasi: `vpn-cli api-key rotate`.
- **D4 Registry:** SQLite `/var/lib/vpn/accounts.db` (WAL). Tabel `accounts(id, service, username, created_at, expires_at, max_sessions, status, meta_json)` dengan `UNIQUE(service, username)`. Satu `flock` global `/run/vpn/ops.lock` untuk semua operasi mutasi (API, menu, cleanup).
- **D5 Waktu:** simpan UTC epoch. "N hari" = tepat N×24 jam dari saat dibuat. Presisi expire 1 menit (timer). Respons API memakai ISO-8601 UTC. Jangan bergantung pada TZ server.
- **D6 ID layanan:** `ssh`, `vmess`, `vless`, `trojan`, `ovpn-tcp`, `ovpn-udp`. `ovpn-tcp` dan `ovpn-udp` dengan username yang sama berbagi satu sertifikat (CN = username); sertifikat dicabut hanya ketika baris terakhir milik CN itu dihapus. Limit sesi OpenVPN dihitung per CN lintas kedua daemon.
- **D7 Username:** `^[a-z][a-z0-9_]{2,19}$`. Unik per layanan. Untuk `ssh`, tolak juga nama yang sudah ada di `getent passwd` dan daftar terlarang (`root`, `nobody`, `admin`, dst.). Jika `username` tidak dikirim, API membuat acak (`u` + 8 karakter base32 huruf kecil).
- **D8 Aturan tanpa gangguan (non-fungsional, wajib):** tidak ada operasi create/delete/renew/expire yang boleh melakukan `restart`, `reload`, atau `stop` pada `xray`, `vpn-openvpn-*`, `ssh`, `dropbear`, `stunnel4`, `nginx`. Hanya menu "Restart" yang boleh. Mekanisme per protokol ada di Fase 3.
- **D9 Limit sesi:** satu service `vpn-session-guard` (root) yang polling tiap 5–10 dtk, menggantikan `vpn-tendang`, hook `openvpn-single-session.sh`, dan cron AutoKill. Nilai default `max_sessions=1`; override per akun disimpan di registry; kebijakan: OpenVPN = **sesi terbaru menang** (sesi lama diputus, ramah perpindahan jaringan); SSH = **sesi tertua dipertahankan** (perilaku sekarang).
- **D10 Driver abstrak:** setiap protokol di balik interface `Driver` (`create/delete/renew/disconnect/count_online`) dan ada `DryRunDriver` (env `VPN_DRY_RUN=1`) agar unit test berjalan tanpa root.

---

## 3. Struktur target

```
open-vpn/
├─ install.sh                 # tanpa bot; + API, registry, guard, nginx
├─ README.md                  # ditulis ulang (Fase 7)
├─ api/
│  ├─ main.py                 # FastAPI app + routes
│  ├─ auth.py  schemas.py  settings.py
│  └─ requirements.txt
├─ vpnctl/                    # library inti, dipakai API + menu + cleanup
│  ├─ registry.py  locking.py  validate.py  timeutil.py
│  ├─ drivers/{ssh,xray,ovpn,dryrun}.py
│  ├─ status.py  guard.py  cleanup.py  migrate.py
│  └─ cli.py                  # entrypoint `vpn-cli` (menggantikan scripts/api/cli.py)
├─ scripts/                   # menu + lib + system (UI tidak berubah)
├─ tests/                     # pytest + test_no_disruption.sh
├─ docs/DECISIONS.md
└─ bin/badvpn-udpgw
```

---

## FASE 1 — Hapus bot dan gateway

- [ ] Hapus folder `bot/` (`bot.py`, `xendit_gateway.py`, `config.json`).
- [ ] `install.sh`: hapus blok copy bot (`if [[ -d "${SCRIPT_DIR}/bot" ]] ...`, ±baris 74-77); `pip3 install python-telegram-bot ... qrcode pillow` (±96); seluruh blok "Telegram Bot Setup" sampai pembuatan `bot-vpn.service` dan `systemctl enable --now bot-vpn` (±98-152); `chmod +x /etc/vpn/bot/bot.py` (±441); dua baris `echo` yang menyebut Telegram/bot di pesan akhir (±451-452); `mkdir -p /etc/vpn/...` yang khusus bot bila ada.
- [ ] `README.md`: hapus bagian "Bot Telegram", kalimat tentang trial Telegram dan `trial_users.json`, tabel/teks yang menyebut `bot-vpn`, dan frasa "integrasi bot".
- [ ] `scripts/api/cli.py`: hapus `create_trial_bundle` dan action `trial`. (File ini nanti dipindah/digantikan di Fase 2.)
- [ ] Buat `scripts/system/remove-bot.sh` (idempoten) untuk instalasi lama: `systemctl disable --now bot-vpn`, hapus `/etc/systemd/system/bot-vpn.service`, `systemctl daemon-reload`, hapus `/etc/vpn/bot` termasuk `config.json` (berisi token dan secret Xendit; timpa dengan `shred -u` bila tersedia), hapus `trial_users.json*`. Panggil dari installer jika direktori/unit lama terdeteksi, dan beri tahu admin untuk **merotasi token bot dan Xendit key** yang pernah tersimpan.
- **Selesai bila:** `grep -rniE "telegram|xendit|bot-vpn|qrcode|python-telegram|trial" --exclude-dir=.git .` tidak menghasilkan apa pun selain `docs/`/CHANGELOG, dan `bash -n install.sh` lolos.

## FASE 2 — Library inti dan registry

- [ ] Buat paket `vpnctl/` sesuai struktur. Pindahkan seluruh logika create/delete/renew/list/status dari `cli.py` dan script bash ke sini; **tidak ada logika bisnis yang tersisa ganda**.
- [ ] `validate.py`: regex username (D7), batas `days` (1–30; `hours` opsional 1–720, saling eksklusif dengan `days`), batas panjang password.
- [ ] `locking.py`: context manager `ops_lock()` (flock `/run/vpn/ops.lock`, timeout 15 dtk → error `busy`), plus helper `atomic_write(path, data)` (tulis ke file sementara di direktori yang sama, `fsync`, `os.replace`, pertahankan owner/mode).
- [ ] `registry.py`: skema D4, fungsi `add`, `get`, `list(service, limit, offset)`, `remove`, `renew`, `expired(now)`, `count_by_service()`, dan tabel `idempotency(key, request_hash, response_json, created_at)` (TTL 24 jam).
- [ ] **Tidak ada `subprocess(..., shell=True)` di mana pun.** Semua pemanggilan memakai argv list. Password SSH diset lewat `chpasswd` dengan stdin, bukan `echo | passwd`.
- [ ] `migrate.py` (`vpn-cli migrate`): impor akun lama ke registry — SSH (uid ≥ 1000, shell `/bin/false`, punya expiry), klien Xray (parse `comment` format lama tanggal saja **dan** format baru tanggal+jam), profil `.ovpn` (komentar `# Expired`). Idempoten; laporkan yang dilewati.
- [ ] Unit test (pytest, `VPN_DRY_RUN=1`): validator, matematika expire, registry, dan **uji konkurensi** (20 proses menambah akun bersamaan → tidak ada baris hilang/duplikat).
- **Selesai bila:** `pytest tests/` hijau tanpa root, dan `grep -rn "shell=True" vpnctl api` kosong.

## FASE 3 — Siklus hidup akun tanpa mengganggu user lain

Semua operasi mutasi berjalan di dalam `ops_lock()`. Urutan umum create: **validasi → tulis sistem → catat registry**; delete/expire: **putuskan sesi akun itu → hapus dari sistem → hapus registry**. Jika langkah tengah gagal, lakukan rollback langkah sebelumnya dan kembalikan error yang jelas.

**SSH**
- [ ] Create: `useradd -M -s /bin/false -e <tanggal expires_at + 1 hari>` (hanya jaring pengaman), `chpasswd` lewat stdin. Expire sebenarnya ditegakkan cleanup berdasarkan registry.
- [ ] Delete/expire: `pkill -KILL -u <user>` hanya milik user itu, lalu `userdel --force`. Renew: `usermod -e` + update registry.

**Xray**
- [ ] Tambahkan ke `install.sh` konfigurasi API lokal Xray: blok `api` (service `HandlerService`, `StatsService`), `stats`, `policy` (aktifkan statistik user), inbound `dokodemo-door` tag `api` di `127.0.0.1:10085`, dan routing rule ke `api`. Tidak terekspos ke luar.
- [ ] Create/delete: terapkan perubahan **runtime** lewat Xray API (`xray api adu` / `xray api rmu`, atau gRPC `HandlerService.AlterInbound`) — **[VERIFIKASI]** sintaks dan versi minimum di versi terpasang (`xray help api`); catat versi minimum di `docs/DECISIONS.md`.
- [ ] Urutan: (1) update `config.json` lewat `atomic_write` (persistensi), (2) terapkan ke runtime, (3) bila runtime gagal, **rollback** file dan kembalikan 503. **Dilarang restart Xray sebagai fallback** kecuali env `ALLOW_XRAY_RESTART_FALLBACK=1` (default 0).
- [ ] Format `comment` di config diseragamkan: `"<username> <expires_at_epoch>"`; sumber kebenaran tetap registry. Perbaiki `xray/renew.sh` dan `cleanup` agar tidak lagi mem-parse teks (S2).
- [ ] Hapus link gRPC dari output (tidak ada inbound gRPC) dan tampilkan hanya link yang didukung konfigurasi nyata (lihat S14).

**OpenVPN**
- [ ] Create: `easyrsa build-client-full` di dalam `ops_lock()` (easyrsa tidak aman paralel). Masa berlaku sertifikat = `days` + 1 hari cadangan. Hasilkan `.ovpn` dengan **satu template** (host = `DOMAIN`, fallback `IP`); selesaikan S16 setelah uji koneksi nyata.
- [ ] Delete/expire: `easyrsa revoke` → **satu kali** `gen-crl` per batch (cleanup mengumpulkan semua yang expired, lalu regenerasi CRL sekali) → salin ke `/etc/openvpn/crl.pem` (pastikan terbaca oleh user `nobody`).
- [ ] **Tanpa restart.** OpenVPN membaca ulang CRL pada handshake baru **[VERIFIKASI pada versi terpasang: revoke lalu coba connect baru tanpa restart]**. Untuk memutus sesi akun yang sedang aktif, tambahkan `management /run/openvpn/tcp.sock unix` dan `/run/openvpn/udp.sock unix` ke kedua `server-*.conf` dan kirim `kill <CN>` ke keduanya.
- [ ] Tambahkan `status-version 2` di kedua `server-*.conf` (S13), atau baca jumlah klien dari management `status 3`.
- [ ] Timer mingguan `vpn-crl-refresh.timer` yang membuat ulang CRL (S12), dan peringatan di `vpn-cli doctor` bila CRL < 30 hari lagi atau sertifikat server < 90 hari lagi.
- [ ] Renew OpenVPN: kembalikan `501 not_supported` dengan pesan jelas (sertifikat tidak diperpanjang). Dokumentasikan.

**Cleanup (expire)**
- [ ] Ganti `scripts/system/cleanup.sh` menjadi pemanggil tipis `vpn-cli cleanup`. Algoritma: ambil `registry.expired(now)` (satu query, bukan memindai `/etc/shadow` + JSON + semua `.ovpn`), proses per akun lewat driver (tanpa restart), CRL sekali di akhir bila ada OpenVPN yang dicabut. Satu baris log ringkas hanya bila ada yang dihapus.
- [ ] Timer tetap tiap menit, tetapi proses harus selesai < 1 dtk saat tidak ada yang expired dan memakai `ops_lock()` dengan timeout pendek (bila lock sedang dipakai, lewati putaran ini).
- **Selesai bila:** uji `tests/test_no_disruption.sh` (Fase 8) lulus untuk skenario SSH, Xray, OpenVPN.

## FASE 4 — API HTTP

Semua respons JSON. Sukses: `{"data": ...}`. Gagal: `{"error": {"code": "...", "message": "..."}}`. Header `X-Request-Id` di setiap respons.

| Method | Path | Auth | Fungsi |
|---|---|---|---|
| GET | `/v1/health` | tidak | `{"ok": true}` untuk uptime monitor |
| GET | `/v1/status` | ya | Status server, status service, jumlah akun per layanan |
| GET | `/v1/services` | ya | Daftar layanan yang tersedia (dipakai web untuk membangun navbar) |
| POST | `/v1/accounts` | ya | Buat akun |
| GET | `/v1/accounts` | ya | Daftar akun (`service`, `limit`, `offset`), tanpa rahasia |
| GET | `/v1/accounts/{service}/{username}` | ya | Detail akun |
| POST | `/v1/accounts/{service}/{username}/renew` | ya | Perpanjang (`{"days": n}`); 501 untuk OpenVPN |
| DELETE | `/v1/accounts/{service}/{username}` | ya | Hapus akun + putuskan sesinya |

Kode galat: `401 unauthorized`, `404 not_found`, `409 conflict`, `422 invalid_request`, `429 rate_limited`, `501 not_supported`, `503 service_unavailable` / `busy`, `500 internal`.

`GET /v1/services`
```json
{"data": {"generated_at": "2026-10-06T07:37:00Z", "services": [
  {"id": "ssh",      "label": "SSH",         "available": true,  "reason": null, "max_days": 30},
  {"id": "vmess",    "label": "VMess",       "available": true,  "reason": null, "max_days": 30},
  {"id": "vless",    "label": "VLESS",       "available": true,  "reason": null, "max_days": 30},
  {"id": "trojan",   "label": "Trojan",      "available": false, "reason": "xray inbound trojan tidak ditemukan", "max_days": 30},
  {"id": "ovpn-tcp", "label": "OpenVPN TCP", "available": true,  "reason": null, "max_days": 30},
  {"id": "ovpn-udp", "label": "OpenVPN UDP", "available": true,  "reason": null, "max_days": 30}
]}}
```
`available` = unit/service aktif **dan** inbound/port nyata ada **dan** driver sehat. `reason` wajib diisi bila `false`. Daftar ini harus menjadi satu-satunya sumber bagi web.

`GET /v1/status`
```json
{"data": {
  "server": {"domain": "vpn.example.com", "uptime_seconds": 123456, "load1": 0.12,
             "ram": {"used_mb": 310, "total_mb": 1990}},
  "services": {"ssh": "running", "xray": "running", "vpn-openvpn-tcp": "running", "vpn-openvpn-udp": "running"},
  "accounts": {"ssh": 12, "vmess": 7, "vless": 4, "trojan": 2, "ovpn-tcp": 5, "ovpn-udp": 9},
  "online": {"ssh": 3, "ovpn": 4, "xray": null}
}}
```
Jumlah akun dari registry (bukan `uid ≥ 1000` atau `count('"email"')`). `online.xray = null` bila statistik online tidak tersedia. Status unit dipanggil dalam **satu** `systemctl is-active a b c ...`, hasil di-cache 5 detik di memori. Nama unit harus yang sebenarnya (`vpn-openvpn-tcp/udp`) — memperbaiki S11.

`POST /v1/accounts`
```json
// request
{"service": "vmess", "days": 3, "username": "optional", "password": "optional-untuk-ssh", "max_sessions": 1}
// 201
{"data": {"service": "vmess", "username": "u7k3m9qa", "created_at": "...Z", "expires_at": "...Z",
          "max_sessions": 1, "connection": { /* sesuai layanan, di bawah */ }}}
```
`connection` per layanan (hanya yang benar-benar didukung server, S14):
- `ssh`: `{host, password, ports: {...}}` — `ports` hanya port yang **sedang listen** (`ss -ltn`).
- `vmess|vless|trojan`: `{host, uuid | password, links: {ws_tls?, ws_none_tls?}}` — hanya link yang punya front-proxy nyata.
- `ovpn-tcp|ovpn-udp`: `{host, port, proto, filename, content}` (isi `.ovpn` penuh).

Header `Idempotency-Key` (opsional, sangat disarankan): permintaan ulang dengan key sama dan body sama mengembalikan respons semula tanpa membuat akun kedua (simpan di tabel `idempotency`); body berbeda dengan key sama → `409`.

Persyaratan non-fungsional:
- [ ] `settings.py` membaca `/etc/vpn/api.env`; semua batas (max_days, rate) dapat dikonfigurasi.
- [ ] Rahasia (password, UUID, isi `.ovpn`, API key) **tidak pernah** masuk log. Log 1 baris per request: `request_id method path status ms`.
- [ ] Target performa pada VPS 1 GB: `GET /v1/status` < 50 ms (cache), create `ssh`/Xray < 1,5 detik, create OpenVPN < 3 detik, 20 create paralel tidak merusak state (diserialisasi oleh `ops_lock()`, antrean maksimal timeout 15 dtk → `503 busy`).
- [ ] OpenAPI otomatis aktif di `/docs` hanya jika `API_DOCS=1` (default mati di produksi). Simpan salinan `docs/openapi.json` di repo.
- [ ] Systemd `vpn-api.service`: `User=root` (perlu mengelola user/Xray/easyrsa), `ExecStart=/etc/vpn/venv/bin/uvicorn api.main:app --host 127.0.0.1 --port 8088 --workers 1`, `Restart=on-failure`, `ProtectHome=true`, `PrivateTmp=true`, `ProtectSystem=full`. Satu worker disengaja (operasi mutasi diserialisasi); jangan memakai `ProtectSystem=strict` sebelum teruji.
- [ ] nginx: `limit_req` ±10 r/s per IP dengan burst kecil, `client_max_body_size 16k`, header keamanan, tanpa CORS secara default (web memakai server-to-server; variabel `CORS_ORIGINS` opsional). Dokumentasikan opsi `allow <ip-web>; deny all;` untuk membatasi akses hanya dari server web.
- **Selesai bila:** pytest kontrak API (FastAPI `TestClient` + `DryRunDriver`) hijau, termasuk kasus 401, 409, 422, idempotensi, dan `available:false`.

## FASE 5 — Limit sesi per akun (`vpn-session-guard`)

- [ ] Implementasi `vpnctl/guard.py` + `vpn-session-guard.service` (loop 5–10 dtk, ringan, restart otomatis). Membaca `max_sessions` dari registry (default 1).
- [ ] **OpenVPN:** query kedua management socket (`status 3`), kelompokkan per CN. Bila satu CN punya > `max_sessions` koneksi (termasuk lintas TCP+UDP), `kill` sesi **terlama** hingga tersisa batas (sesi terbaru menang). Tidak ada hook `client-connect`/`client-disconnect`, tidak ada lock file, tidak ada state di `/run` → S6 dan S7 hilang. Hapus `openvpn-single-session.sh` serta baris `client-connect`/`client-disconnect` dari kedua `server-*.conf`.
- [ ] **SSH/Dropbear:** hitung sesi per user dari proses (`ps -eo pid,etimes,user,args`, pola `sshd: <user>` dan child dropbear) bukan `who -u` (S8). **[VERIFIKASI]** pola proses di Debian 12 dan Ubuntu 22.04 dengan tunnel tanpa pty. Bila melebihi batas, `kill -TERM` sesi **terbaru**. Jangan memakai `pkill -u` (akan memutus sesi sah).
- [ ] **Xray:** tidak ada pembatas bawaan. Opsional (default mati, env `GUARD_XRAY=1`): bila Xray memiliki statistik online-IP (`GetStatsOnlineIpList`, perlu `statsUserOnline` pada policy), tandai pelanggaran dan catat ke log. Jangan melakukan pemutusan massal. Jika tidak didukung, laporkan `online.xray: null` dan dokumentasikan keterbatasannya.
- [ ] Hapus `vpn-session-limit.service/.timer` dari installer dan `scripts/system/vpn-tendang`. Menu **AutoKill tetap ada dengan tampilan yang sama**, tetapi kini menulis `/etc/vpn/limits.conf` (`MAX_SESSIONS`, `INTERVAL`) lalu `systemctl kill -s HUP vpn-session-guard` (reload konfigurasi), bukan cron (memperbaiki S9).
- [ ] Log hanya saat ada tindakan: `SESSION-LIMIT | service=<..> user=<..> action=kill reason=over_limit`.
- **Selesai bila:** uji manual — satu akun OpenVPN membuka koneksi kedua (TCP lalu UDP) → hanya satu yang bertahan dalam ≤ 10 dtk, tanpa file lock tersisa setelah `systemctl restart vpn-openvpn-udp`; satu akun SSH membuka tunnel kedua → yang terbaru terputus; akun lain tidak terpengaruh.

## FASE 6 — Menu internal (UI tetap, backend disatukan)

- [ ] `scripts/ssh/{create,delete,renew,list,check}.sh`, `scripts/xray/*.sh`, `scripts/openvpn/*.sh`: tampilan, urutan pertanyaan, dan warna **tidak berubah**. Hanya bagian yang menulis ke sistem diganti memanggil `vpn-cli` (mis. `vpn-cli create --service ssh --user ... --days ...`), sehingga menu dan API memakai logika, validasi, registry, dan lock yang sama. Hasil JSON `vpn-cli` diformat ulang oleh script bash seperti tampilan sekarang.
- [ ] Hapus semua `systemctl restart xray` / `vpn-openvpn-*` dari script akun (S3). Hapus interpolasi `${USERNAME}` ke Python heredoc (S1).
- [ ] `scripts/system/status.sh` dan `menu/main.sh`: jumlah akun dari registry; koneksi aktif OpenVPN dari `status-version 2`/management (S13); nama label "KONEKSI AKTIF" hanya untuk koneksi sungguhan (jumlah klien Xray berlabel "AKUN").
- [ ] `scripts/system/restart.sh`: BadVPN memakai `systemctl restart badvpn-7100 badvpn-7200 badvpn-7300` (S15); hapus pemanggilan `ws-stunnel`/`ws-dropbear` yang tidak ada (atau buat kondisional: lewati bila unit tidak terpasang).
- [ ] Tambahkan `vpn-cli doctor`: cek unit, port listen, CRL/sertifikat, versi Xray, konsistensi registry vs sistem (akun yatim), dan izin file.
- **Selesai bila:** semua alur menu lama masih berjalan (buat, hapus, perpanjang, daftar, status, restart, autokill) dan `bash -n` lolos untuk semua script.

## FASE 7 — Installer, systemd, dan dokumentasi

- [ ] `install.sh`: idempoten (S18). Jangan `init-pki`/`build-ca` bila `/etc/openvpn/easy-rsa/pki/ca.crt` sudah ada; cek aturan `iptables` sebelum `-C`/`-A`. Tidak ada prompt Telegram/Xendit. Pasang `python3-venv`, buat venv, `pip install -r api/requirements.txt`. Salin `api/` dan `vpnctl/`. Buat `/etc/vpn/api.env` (key acak, 0600) dan tampilkan key **sekali** di akhir instalasi.
- [ ] Systemd: `vpn-api.service`, `vpn-session-guard.service`, `vpn-expiry-cleanup.timer` (tiap menit), `vpn-crl-refresh.timer` (mingguan). Hapus `vpn-session-limit.*` dan `bot-vpn.service`.
- [ ] Opsi installer untuk nginx + certbot pada `api.<DOMAIN>`; bila tanpa domain, API tetap bind lokal dan installer menampilkan peringatan (D2). Firewall: buka hanya 80/443 dan port layanan VPN; **jangan** buka 8088 atau 10085.
- [ ] Susun front-proxy Xray nyata (nginx `location /vmess`, `/vless`, `/trojan-ws` → `127.0.0.1:10001-10003`, TLS 443) **atau**, bila belum dikerjakan, pastikan `GET /v1/services` mengembalikan `available:false` beserta `reason` untuk layanan Xray sehingga web tidak menawarkan akun yang tidak bisa tersambung (S14).
- [ ] Tulis ulang `README.md`: tujuan project (API server), instalasi, variabel konfigurasi, daftar endpoint dengan contoh `curl`, model expire (N×24 jam), model limit sesi, cara migrasi (`vpn-cli migrate`, `remove-bot.sh`), troubleshooting (`vpn-cli doctor`), catatan keamanan. Hapus tabel port/layanan yang tidak benar-benar dikonfigurasi.
- [ ] `docs/DECISIONS.md`: semua hasil **[VERIFIKASI]** dan penyimpangan dari dokumen ini.

## FASE 8 — Verifikasi akhir (wajib sebelum merge)

Buat `tests/test_no_disruption.sh` yang gagal bila ada yang berubah. Jalankan di VM nyata:

1. Catat sebelum dan sesudah: `systemctl show xray vpn-openvpn-tcp vpn-openvpn-udp ssh -p MainPID -p ActiveEnterTimestamp`.
2. Sambungkan akun **A** per protokol: SSH tunnel, klien Xray (curl via proxy), klien OpenVPN TCP dan UDP.
3. Lakukan 20× create, 10× renew, 20× delete, dan satu putaran expire untuk akun **B** (semua protokol), sebagian paralel.
4. Pastikan: `MainPID` dan `ActiveEnterTimestamp` semua service **tidak berubah**; sesi akun A masih terhubung (management `status 3`, `ps`, koneksi curl masih hidup); registry dan sistem konsisten (`vpn-cli doctor` bersih).
5. Hapus akun A: hanya sesi A yang putus, akun lain tetap.
6. Uji expire: buat akun `hours=1`, majukan waktu uji (atau ubah `expires_at` di registry) → akun hilang ≤ 70 detik; akun lain tidak terputus.
7. Uji limit: skenario Fase 5.
8. Uji keamanan: username `a;touch /tmp/pwn`, `$(id)`, spasi, unicode → semua `422`, tidak ada file `/tmp/pwn`; tanpa/dengan `X-API-Key` salah → `401`.
9. Uji ketahanan CRL: simulasikan CRL mendekati expired dan pastikan `vpn-cli doctor` memperingatkan.

**Definition of Done keseluruhan:** semua fase lulus; `grep -rn "shell=True\|systemctl restart xray\|restart vpn-openvpn" scripts vpnctl api` hanya menyisakan menu "Restart" di `restart.sh`; `docs/DECISIONS.md` terisi; `README.md` baru; tidak ada sisa bot/gateway.
