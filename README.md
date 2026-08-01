# Panduan Instalasi OpenVPN & Multi-Tunnel Autoscript

## Persyaratan

- Debian 10/11/12 atau Ubuntu 20.04/22.04.
- VPS baru, akses root, minimal 1 GB RAM.
- Koneksi internet saat instalasi. Domain bersifat opsional; jika kosong, IP VPS digunakan.

## Instalasi

```bash
apt update -y && apt install -y curl wget
wget https://raw.githubusercontent.com/brutalX-04/open-vpn/main/install.sh
chmod +x install.sh
./install.sh
```

Installer akan meminta domain/subdomain dan, secara opsional, token serta admin ID Telegram.

## Service yang otomatis berjalan

Setelah instalasi, installer mengaktifkan dan langsung menjalankan service berikut. Semua service ini juga aktif kembali setelah reboot:

| Service | Nama systemd | Keterangan |
|---|---|---|
| OpenSSH | `ssh` | Akses SSH standar di port 22 |
| Cron | `cron` | Tetap dipakai oleh komponen sistem |
| Nginx | `nginx` | Dipasang dan diaktifkan; konfigurasi proxy belum dibuat oleh installer |
| Dropbear | `dropbear` | Dipasang dan diaktifkan |
| Stunnel | `stunnel4` | Dipasang dan diaktifkan |
| Fail2Ban | `fail2ban` | Dipasang dan diaktifkan |
| OpenVPN TCP | `vpn-openvpn-tcp` | Port 1194/TCP |
| OpenVPN UDP | `vpn-openvpn-udp` | Port 1194/UDP |
| BadVPN UDPGW | `badvpn-7100`, `badvpn-7200`, `badvpn-7300` | Hanya bind localhost pada port 7100/7200/7300 |
| Xray | `xray` | Inbound WS lokal pada port 10001/10002/10003 |
| Expiry cleanup | `vpn-expiry-cleanup.timer` | Menjalankan pemeriksaan akun expired setiap menit |
| SSH session limit | `vpn-session-limit.timer` | Menutup sesi SSH tambahan setiap menit |

Bot Telegram (`bot-vpn.service`) hanya diaktifkan otomatis bila token diisi saat instalasi. Jika token diisi kemudian, jalankan:

```bash
systemctl enable --now bot-vpn
```

Status service dapat diperiksa dengan `status` atau `systemctl status <nama-service>`.

## Expired akun

Masa aktif input dalam satuan hari. Tanggal expired adalah awal hari tersebut pada zona waktu VPS (00:00). Pada menit pertama tanggal expired:

- akun SSH ditutup dan dihapus;
- akun Xray dihapus dari konfigurasi lalu Xray direstart;
- profil OpenVPN TCP/UDP dihapus, sertifikatnya dicabut, CRL diperbarui, lalu kedua service OpenVPN direstart.

Timer memakai `Persistent=true`, sehingga bila VPS mati saat jadwal lewat, cleanup akan dijalankan segera setelah VPS kembali hidup. Cek status dan log:

```bash
systemctl status vpn-expiry-cleanup.timer
systemctl list-timers vpn-expiry-cleanup.timer
/etc/vpn/scripts/system/cleanup.sh --verbose
tail -f /var/log/vpn/cleanup.log
```

## Batas koneksi dan trial

- Satu akun OpenVPN hanya dapat memiliki satu koneksi aktif, termasuk bila mencoba memakai profil TCP dan UDP bersamaan. Koneksi kedua ditolak saat proses connect.
- Satu akun SSH dibatasi satu sesi interaktif aktif. Timer `vpn-session-limit.timer` menutup sesi tambahan paling lambat dalam satu menit. Log ada di `/var/log/vpn/session-limit.log`.
- Satu akun Telegram hanya dapat membuat satu paket trial per tanggal server. Catatan disimpan di `/etc/vpn/bot/trial_users.json`, sehingga aturan tetap berlaku setelah bot atau VPS direstart.

Xray tidak menyediakan pembatas jumlah koneksi aktif per pengguna pada konfigurasi inbound standar ini. Karena itu, script tidak mengklaim membatasi multi-login Xray; pembatasan tersebut memerlukan proxy/session store eksternal atau sistem autentikasi tambahan.

## Port yang benar-benar dikonfigurasi

| Komponen | Port |
|---|---|
| OpenSSH | 22/TCP |
| OpenVPN TCP | 1194/TCP |
| OpenVPN UDP | 1194/UDP |
| BadVPN UDPGW | 127.0.0.1:7100, 7200, 7300/UDP |
| Xray VMess WS | 10001/TCP |
| Xray VLESS WS | 10002/TCP |
| Xray Trojan WS | 10003/TCP |

Nginx, Dropbear, dan Stunnel dipasang tetapi installer ini belum menulis konfigurasi port/proxy khusus untuk SSH WebSocket, TLS, Cloudflare, atau gRPC. Jangan menganggap port 80/443 sudah menjadi tunnel aktif sebelum konfigurasi tersebut ditambahkan.

## Perintah CLI

- `menu`: menu utama.
- `menu-ssh`: kelola akun SSH.
- `menu-xray vmess|vless|trojan`: kelola akun Xray.
- `menu-ovpn`: kelola profil OpenVPN TCP/UDP.
- `running` atau `status`: status sistem.
- `restart-service`: menu restart service.
- `vpn-cli`: CLI JSON untuk integrasi bot/API.

## Bot Telegram

Saat instalasi, masukkan token bot dan Admin User ID bila sudah tersedia. Installer juga menawarkan konfigurasi Xendit untuk pembayaran QRIS otomatis. Ambil **Secret API Key** dari dashboard Xendit; gunakan Test Secret Key untuk pengujian dan Live Secret Key untuk transaksi produksi.

Bot memakai Xendit Payments API v3, endpoint `/v3/payment_requests`, API version `2024-11-11`, dan channel `QRIS`. Saat pelanggan memilih paket, bot membuat QRIS dinamis; akun hanya dibuat setelah status Payment Request dari Xendit adalah `SUCCEEDED`.

Konfigurasi disimpan di `/etc/vpn/bot/config.json`:

```json
{
  "xendit": {
    "secret_key": "xnd_development_atau_live_secret_key"
  }
}
```

Jaga Secret API Key tetap rahasia; jangan kirimkan ke chat atau commit ke repository. Tanpa key, bot menolak pembayaran dan tidak membuat akun otomatis. Setelah mengubah token, admin ID, atau konfigurasi Xendit:

```bash
systemctl enable --now bot-vpn
systemctl restart bot-vpn
journalctl -u bot-vpn -f
```

## Catatan OpenVPN

Server menggunakan CRL pada `/etc/openvpn/crl.pem`. Karena itu, sertifikat yang dicabut oleh menu hapus atau cleanup expired tidak dapat dipakai lagi setelah service direstart oleh proses tersebut.
