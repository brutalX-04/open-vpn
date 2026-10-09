# OpenVPN Control Server

Server VPN dengan registry akun SQLite, cleanup berbasis masa aktif, pembatas sesi, menu lokal, dan REST API FastAPI. API hanya bind ke `127.0.0.1:8088`; akses dari luar harus melalui reverse proxy HTTPS yang dikelola admin.

## Lisensi

Proyek ini dapat digunakan, diubah, dan dibagikan secara gratis sesuai [LICENSE](LICENSE). Penjualan, distribusi berbayar, dan eksploitasi komersial yang menjadikan perangkat lunak ini sebagai nilai utama tidak diizinkan. Lisensi ini adalah lisensi source-available dengan batasan komersial, bukan lisensi open source yang disetujui OSI.

## Persyaratan

- Debian 12, Ubuntu 22.04, atau Ubuntu 24.04, akses root, minimal RAM 1 GB.
- Domain disarankan untuk membuat profil klien. Installer meminta domain dan memasang OpenVPN, Xray, Nginx, Python virtualenv, serta unit systemd. Jika domain terdeteksi, installer menawarkan endpoint `api.<domain>` melalui Nginx dan Let's Encrypt; DNS harus menunjuk ke VPS dan port 80/443 dapat dijangkau. Jika setup HTTPS gagal atau ditolak, API tetap loopback-only.
- Jalankan installer dari root repository yang lengkap:

```bash
apt update && apt install -y git curl
git clone https://github.com/brutalX-04/open-vpn.git /opt/open-vpn
cd /opt/open-vpn
chmod +x install.sh
./install.sh
```

Installer mempertahankan PKI dan config Xray yang telah ada, menjalankan migrasi registry idempoten, dan menampilkan API key hanya saat pertama kali dibuat. Key disimpan di `/etc/vpn/api.env` dengan mode `0600`.

## Menghapus instalasi

Jalankan uninstaller dari repository dengan hak root:

```bash
sudo bash uninstall.sh
```

Uninstaller meminta konfirmasi dengan mengetik `uninstall`, lalu menghapus unit layanan VPN, tautan perintah, dan situs Nginx milik installer. Secara default, konfigurasi, akun, registry, PKI, log, paket, serta sertifikat Let's Encrypt dipertahankan. Layanan sistem bersama seperti SSH, cron, Nginx, dan fail2ban juga tetap aktif.

Untuk sekaligus menghapus akun terkelola dan data VPN, termasuk konfigurasi, database registry, PKI OpenVPN, serta konfigurasi Xray, gunakan:

```bash
sudo bash uninstall.sh --purge-data
```

Opsi tambahan:

- `--purge-packages` menghapus paket `openvpn`, `easy-rsa`, `dropbear`, dan `stunnel4`; paket bersama dan dependensi tidak di-autoremove.
- `--remove-firewall` menghapus aturan iptables VPN yang cocok untuk port 1194 dan NAT. Aturan identik yang sudah ada sebelum instalasi mungkin ikut terhapus.
- `--yes` melewati prompt konfirmasi; gunakan hanya jika opsi yang dipilih sudah diperiksa.

## Perintah

Menu interaktif: `menu`, `menu-ssh`, `menu-xray`, `menu-ovpn`, `status`, dan `restart-service`.

```bash
vpn-cli migrate
vpn-cli list --service ssh
vpn-cli create --service ssh --user contoh_01 --days 7
vpn-cli renew --service ssh --user contoh_01 --days 3
vpn-cli delete --service ssh --user contoh_01
vpn-cli cleanup
vpn-cli doctor
vpn-cli api-key rotate
```

Username mengikuti `^[a-z][a-z0-9_]{2,19}$`. Durasi adalah 1–30 hari atau 1–720 jam, tepat dihitung sebagai N × 24 jam dari waktu UTC pembuatan. Password SSH dibaca dari stdin (`--password-stdin`) atau dibuat acak bila tidak diberikan; jangan meletakkan password di argumen proses.

## REST API

API lokal mendengarkan `127.0.0.1:8088`. Semua endpoint selain health membutuhkan header `X-API-Key`. Respons sukses berbentuk `{"data": ...}` dan error `{"error":{"code":"...","message":"..."}}`; semua respons membawa `X-Request-Id`. Rahasia tidak dicatat ke log.

Unit API berjalan sebagai root agar dapat mengelola akun sistem dan konfigurasi VPN. Unit membatasi home dan temporary files, tetapi tidak memakai `ProtectSystem` karena shadow-utils memerlukan file sementara di `/etc`. Pertahankan bind loopback dan API key; sebelum mengeksposnya lewat reverse proxy, tinjau pembatasan privilege serta aktifkan TLS dan aturan akses yang sesuai.

| Method | Endpoint | Fungsi |
|---|---|---|
| GET | `/v1/health` | Health check tanpa autentikasi |
| GET | `/v1/status` | Status unit, akun registry, dan sesi online yang tersedia |
| GET | `/v1/services` | Kemampuan layanan aktual untuk aplikasi web |
| POST | `/v1/accounts` | Buat akun (`service`, `days` atau `hours`, `username?`, `password?`, `max_sessions?`) |
| GET | `/v1/accounts?service=ssh&limit=100&offset=0` | Daftar tanpa rahasia |
| GET | `/v1/accounts/{service}/{username}` | Detail akun tanpa rahasia |
| POST | `/v1/accounts/{service}/{username}/renew` | Perpanjang SSH/Xray dengan `{"days": n}` |
| DELETE | `/v1/accounts/{service}/{username}` | Hapus akun dan putuskan sesi milik akun |

Contoh:

```bash
curl -H "X-API-Key: $API_KEY" http://127.0.0.1:8088/v1/status
curl -X POST http://127.0.0.1:8088/v1/accounts \
  -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: order-123' \
  -d '{"service":"ssh","days":7,"username":"contoh_01"}'
```

Idempotency-Key yang sama dan request sama mengembalikan respons pertama selama 24 jam; request berbeda menghasilkan 409. OpenVPN renew menghasilkan 501 karena sertifikat tidak dapat diperpanjang. Xray hanya ditawarkan ketika inbound, Nginx websocket route dan port terkait terdeteksi hidup. Pada instalasi default front proxy belum tersedia, sehingga VMess, VLESS, dan Trojan tampil `available:false`.

### Profil klien Xray

Untuk menerbitkan tautan klien TLS/WebSocket pada VM yang sudah terpasang, arahkan A record domain ke IPv4 publik VM, izinkan TCP 80 dan 443 pada firewall VM dan firewall cloud, lalu jalankan:

```bash
sudo bash /etc/vpn/scripts/system/configure-xray-proxy.sh vm1.example.com
```

Skrip meminta sertifikat Let's Encrypt dan memasang rute WebSocket di Nginx. Pada host yang sama, rute `/v1/` juga diteruskan ke API lokal `127.0.0.1:8088` melalui HTTPS; API key tetap wajib untuk endpoint administrasi selain health. Jika installer sebelumnya membuat vhost `vpn-api` untuk host ini, skrip menonaktifkan symlink duplikat dan menggabungkan layanan dalam vhost Xray. Setelah aktif, menu pembuatan VMess/VLESS/Trojan menampilkan tautan impor. Tautan VMess berisi JSON profil yang di-Base64-kan; UUID saja bukan tautan lengkap.

Setup front proxy juga mengaktifkan SSH over WebSocket melalui Nginx pada TCP 80 (WS) dan 443 (WSS). Port 443 memerlukan sertifikat TLS untuk domain tersebut. Akun tunnel tetap memakai shell noninteraktif; SSH TCP forwarding harus aktif. BadVPN UDPGW mendengarkan hanya di loopback pada port 7100, 7200, dan 7300, sehingga dipakai oleh klien melalui tunnel SSH. OpenVPN UDP adalah layanan terpisah di UDP 1194 dan memerlukan profil OpenVPN. Izinkan TCP 80/443 dan UDP 1194 di firewall cloud; aturan iptables installer hanya berlaku di dalam VPS.

### Akses dari luar dengan HTTPS

Jangan membuka port 8088 atau 10085. DNS `api.<domain>` harus mengarah ke server dan sertifikat TLS harus valid. Contoh konfigurasi Nginx (sesuaikan path sertifikat):

```nginx
limit_req_zone $binary_remote_addr zone=vpn_api:10m rate=10r/s;
server {
    listen 443 ssl;
    server_name api.example.com;
    ssl_certificate /etc/letsencrypt/live/api.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.example.com/privkey.pem;
    client_max_body_size 16k;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    location / {
        limit_req zone=vpn_api burst=10 nodelay;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:8088;
    }
}
```

Batasi hanya server web jika diperlukan dengan `allow <ip-web>; deny all;` di dalam `location`. Jangan aktifkan CORS kecuali browser mengakses API secara langsung dan origin memang dibutuhkan. Tanpa TLS installer membiarkan API hanya di loopback.

## Cleanup, sesi, dan sertifikat

- `vpn-expiry-cleanup.timer` memeriksa registry tiap menit. Expiry menggunakan UTC epoch; aksi akun tidak me-restart service bersama.
- `vpn-session-guard.service` memeriksa sesi OpenVPN dan SSH tiap 5–10 detik. Koneksi OpenVPN terbaru dipertahankan; untuk SSH sesi tertua dipertahankan. Xray tidak dapat diputus berdasarkan statistik user pada konfigurasi saat ini.
- OpenVPN membagi CN/sertifikat antar TCP dan UDP. Sertifikat dicabut saat entry terakhir CN dihapus; CRL diperbarui sekali per batch dan mingguan oleh `vpn-crl-refresh.timer`.
- Profil OpenVPN tidak di-renew. Buat akun/sertifikat baru setelah menghapus entry lama.
- AutoKill menu menyimpan `MAX_SESSIONS` dan `INTERVAL` di `/etc/vpn/limits.conf`, lalu mengirim HUP ke session guard.

Gunakan `vpn-cli doctor`, `journalctl -u vpn-api -u vpn-session-guard`, dan `/var/log/vpn/cleanup.log` untuk diagnosis. File registry ada di `/var/lib/vpn/accounts.db` (WAL; izin terbatas). Migrasi legacy aman diulang dengan `vpn-cli migrate`.

## Pengujian dan batas verifikasi

```bash
python -m pip install -r requirements-dev.txt
python -m pytest -p no:cacheprovider tests/ -q
```

Tes lokal memverifikasi library dan kontrak API memakai DryRunDriver. Ubuntu 24.04 sudah diuji dengan instalasi nyata, Xray add/remove, EasyRSA dan CRL, API auth/CRUD, expiry, serta snapshot PID/timestamp service. Uji klien aktif untuk session limit, `client-kill`, koneksi profil OpenVPN, CRL pada handshake baru, dan HTTPS/certbot masih diperlukan sebelum produksi.

Pada VM test yang sudah diinstal, jalankan `sudo bash tests/vm_smoke.sh` untuk menguji create/delete akun SSH, semua protokol Xray, sertifikat bersama OpenVPN TCP/UDP, CRL, API auth, dan memastikan PID serta waktu aktif service tidak berubah. Script membuat akun sementara acak dan membersihkannya saat selesai.
