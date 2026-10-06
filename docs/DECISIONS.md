# Keputusan dan hasil verifikasi

## Keputusan implementasi

- Registry menjadi sumber expiry dan jumlah akun. Migrasi dapat dijalankan ulang; konflik unik dilaporkan sebagai duplikat.
- Database SQLite dan idempotency response memakai akses filesystem terbatas; `api.env` mode `0600`.
- API tetap loopback-only. Reverse proxy HTTPS dan sertifikat domain dipasang admin karena domain/DNS serta sertifikat tidak dapat diverifikasi saat instalasi di lingkungan ini.
- Xray account endpoints baru aktif bila admin mengaktifkan `XRAY_FRONT_PROXY=1` dan Nginx/Xray routes serta port websocket terdeteksi. Inbound Xray lokal tanpa front proxy tidak menghasilkan connection link.
- Runtime Xray menggunakan CLI API `adu`/`rmu`, konfigurasi Xray dipersistenkan atomik lebih dulu, dan kegagalan API mengembalikan config lama. Tidak ada restart sebagai fallback.
- Guard SSH no-PTY, OpenVPN TCP/UDP, revoke/handshake, profil client, serta operasi akun tanpa gangguan lulus pada VM Ubuntu 24.04.
- Migrasi registry memakai expiry SSH dari `/etc/shadow`, komentar expiry Xray lama tanggal atau tanggal+jam, serta `# Expired` profil OpenVPN.
- Installer menerima Debian 10/11/12 dan Ubuntu 20.04/22.04/24.04; instalasi dan pengulangan installer berhasil di Ubuntu 24.04.5 (Noble), dengan OpenVPN 2.6.19, EasyRSA 3.1.7, dan Xray 26.3.27. `vpn-cli doctor` lulus semua pemeriksaan setelah pemasangan.
- Unit vendor Xray awalnya menunjuk ke `/usr/local/etc/xray/config.json` mode 0600, sedangkan aplikasi mengelola `/etc/xray/config.json`. Drop-in installer kini membuat unit membaca file aplikasi dengan izin root:nogroup 0640; Xray berjalan dan `xray run -test` melaporkan `Configuration OK`.
- CLI Xray 26.3.27: `adu` memakai file inbound JSON; `rmu` memerlukan `--tag=<inbound-tag>` dan email. Create/delete VMess, VLESS, dan Trojan berhasil; uji runtime refusal pada config terisolasi memulihkan file persis byte-per-byte.
- Smoke test VM lulus untuk API health/auth/services/status, SSH dan OpenVPN API create/delete, idempotency, SSH dan semua Xray renew, EasyRSA TCP/UDP shared-CN create/delete, forced expiry cleanup, CRL refresh, dan konsistensi registry. PID serta `ActiveEnterTimestamp` SSH, Xray, OpenVPN TCP/UDP, dan API tetap sama sepanjang operasi.
- Pemeriksaan ulang menemukan indeks `CLIENT_LIST` status-v3 yang keliru pada session guard: waktu koneksi harus di kolom 8 dan `Client ID` di kolom 10. Parser diperbaiki; guard diuji dengan sesi nyata SSH tanpa PTY dan OpenVPN lintas TCP/UDP. Revoke ditolak pada handshake baru tanpa restart daemon.
- Domain uji `vm1.brutalx.my.id` ter-resolve ke IPv4 publik VM. Let's Encrypt HTTP-01 gagal timeout ke port 80. Guest firewall awalnya hanya mengizinkan SSH; TCP 80/443 telah diizinkan sebelum rule reject dan disimpan dengan netfilter-persistent. Setelah ingress cloud TCP 80/443 dibuka, Certbot berhasil menerbitkan sertifikat untuk `vm1.brutalx.my.id` hingga 2027-01-04. HTTP redirect, TLS trust, renewal timer, dan VMess WSS melalui TLS telah diuji; API tetap bind loopback.
- API SSH create awalnya gagal karena `ProtectSystem=full` menghalangi shadow-utils menulis lock/temp files di `/etc`, termasuk setelah allowlist. Installer kini tidak mengaktifkan `ProtectSystem` untuk API (uji useradd transient membuktikan keharusan ini); `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, loopback binding, dan API key tetap aktif. API berjalan sebagai root; evaluasi model privilege sebelum mengekspos API melalui reverse proxy.

## Verifikasi dan pengecualian

- Uji rollback Xray lulus pada config sementara dan endpoint runtime yang sengaja tidak tersedia; file kembali identik dan tidak menyentuh config aktif.
- Guard SSH no-PTY, OpenVPN TCP/UDP, revoke/handshake, profil client, serta operasi akun tanpa gangguan lulus pada VM Ubuntu 24.04.
- Stress akun A/B, expiry, beban paralel 20 create/10 renew/20 delete per layanan, dan akun C lulus. Uji API nyata menolak key hilang/salah dengan 401 serta shell metacharacters, spasi, dan Unicode dengan 422; sentinel tidak dibuat.
- Sertifikat TLS, redirect HTTP, Certbot timer, route VMess WSS, dan generator link telah diuji. API administrasi tetap loopback-only; tes klien langsung Windows dilewati karena proxy lokal Windows tidak tersedia.

- CRL warning diverifikasi dengan waktu simulasi 15 hari tersisa; hash file CRL aktif tidak berubah. Waktu doctor dapat diinjeksi melalui parameter untuk pengujian deterministik.
- Matriks Debian 12 dan Ubuntu 22.04 sengaja dilewati atas arahan pengguna; pengujian runtime dilaksanakan di Ubuntu 24.04.5.

## Konteks implementasi

Spesifikasi Xray menyatakan HandlerService menyediakan tambah/hapus user inbound; ini belum membuktikan argumen CLI cocok di versi yang terpasang. Sumber primer: [Project X API Interface](https://xtls.github.io/en/config/api.html) dan [Project X command arguments](https://xtls.github.io/ru/document/command).


