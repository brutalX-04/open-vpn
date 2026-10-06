# Progres refactor server VPN

Acuan: `task-server.md`. Semua fase dalam cakupan pengguna telah diselesaikan dan diverifikasi; matriks Debian 12/Ubuntu 22.04 dilewati atas arahan pengguna.

## Status fase

- [x] Fase 1 â€” hapus bot/gateway.
- [x] Fase 2 â€” library inti, registry SQLite, migrasi, validator, locking, DryRunDriver.
- [x] Fase 3 â€” operasi akun tanpa gangguan: smoke test nyata Xray/OpenVPN/SSH dan expiry lulus tanpa perubahan PID/timestamp; sesi SSH, VMess, OpenVPN TCP dan UDP akun A tetap aktif sepanjang operasi paralel akun B.
- [x] Fase 4 â€” API FastAPI lokal, auth, idempotency, status/services/account routes.
- [x] Fase 5 â€” session guard SSH/OpenVPN: parser OpenVPN status v3 diperbaiki dan dipasang; pengujian nyata dua sesi SSH no-PTY serta OpenVPN lintas TCP/UDP lulus; sesi lebih lama dipertahankan dan yang berlebih diputus. Revoke sertifikat menolak handshake baru tanpa restart daemon.
- [x] Fase 6 â€” menu dan cleanup memakai vpnctl; restart eksplisit tetap di menu restart.
- [x] Fase 7 â€” installer, unit, HTTPS opsional, dokumentasi: instalasi dan pengulangan installer lulus di Ubuntu 24.04; API loopback, Xray, OpenVPN, guard, cleanup, firewall guest, dan dokumentasi aktif. TLS aktif untuk `vm1.brutalx.my.id`: sertifikat Let's Encrypt terbit, renewal timer aktif, redirect HTTP ke HTTPS dan VMess WebSocket lewat TLS lulus; API tetap loopback-only.
- [x] Fase 8 - verifikasi akhir Ubuntu 24.04: stress/sesi tanpa gangguan, batas sesi/revoke, CRL warning saat 15 hari tersisa tanpa mengubah CRL aktif, Xray rollback setelah runtime menolak, validasi keamanan API, TLS publik dan route VMess TLS lulus. Matriks Debian 12/Ubuntu 22.04 dilewati atas arahan pengguna.

## Pekerjaan yang sudah diterapkan

- `vpnctl/`: validasi, UTC expiry, flock ops lock, atomic write, registry SQLite WAL dan idempotency TTL 24 jam, driver SSH/Xray/OpenVPN/DryRun, operasi create/delete/renew/cleanup, migrasi, guard, doctor, CLI.
- `api/`: FastAPI dengan `X-API-Key`, request ID, health/status/services/accounts, idempotency, error JSON; docs mati secara default. Xray dilaporkan unavailable kecuali proxy WS nyata terdeteksi.
- `install.sh`: venv, copy API/library, API key acak 0600, migrasi lama, systemd API/guard/cleanup/CRL refresh, EasyRSA dan NAT idempoten, management socket OpenVPN, opsi Nginx + Let's Encrypt dengan backend tetap loopback.
- Installer memvalidasi `/etc/os-release` dan kini menerima Ubuntu 24.04; README serta keputusan verifikasi diperbarui. Uji pytest di VM Ubuntu 24.04 lulus dalam DryRun.
- Uji instalasi dan pengulangan installer nyata di Ubuntu 24.04.5 sukses. `vpn-cli doctor` memberi `ok: true`; API loopback health HTTP 200.
- Xray 26.3.27 `adu/rmu` lulus create/delete untuk VMess, VLESS, Trojan setelah driver memakai inbound tag+email untuk `rmu` dan installer menunjuk ke file config aplikasi.
- `sudo bash tests/vm_smoke.sh` lulus: API auth/CRUD/idempotency/status, SSH/Xray/OpenVPN create-delete-renew-expire, EasyRSA shared cert/CRL, serta PID dan ActiveEnterTimestamp tetap sama.
- Parser sesi OpenVPN status v3 memakai kolom `Connected Since (time_t)` dan `Client ID` yang benar; perbaikan terpasang di VM. `vpn-cli doctor` tetap `ok: true`, semua enam layanan aktif.
- Smoke test sesi VM lulus: guard memutus sesi TCP lama saat UDP baru masuk; guard SSH memutus tunnel no-PTY baru dan mempertahankan satu sesi; penghapusan akun mencabut sertifikat dan handshake baru ditolak oleh server tanpa restart OpenVPN.
- Uji tanpa gangguan VM lulus: akun A tetap mengakses SSH, VMess, OpenVPN TCP/UDP selama beban akun B; siklus beban paralel selesai, lalu menghapus A menghentikan sesi A dan membiarkan akun C tetap aktif.
- Uji klien VMess nyata melalui WebSocket lokal dan TLS publik lulus dengan HTTP 200; generator profil TLS terverifikasi. API uji dan keamanan, doctor, serta seluruh 14 tes lokal lulus.
- Firewall guest kini mengizinkan dan mempersistenkan TCP 80/443 serta TCP/UDP 1194 sebelum rule reject; `bash -n` installer dan skrip smoke lulus.
- Domain `vm1.brutalx.my.id` menunjuk ke IP VM. Setelah ingress cloud TCP 80/443 dibuka, Certbot menerbitkan sertifikat sampai 2027-01-04; renewal timer aktif. Nginx redirect HTTP ke HTTPS dan route VMess WSS TLS menghasilkan HTTP 200 melalui klien Xray. Route VLESS/Trojan dikonfigurasi; API administrasi tetap loopback-only.
- Menu SSH/Xray/OpenVPN, status, cleanup dan AutoKill diarahkan ke registry/session guard. `vpn-tendang` dan hook sesi OpenVPN lama dihapus. Operasi akun tidak me-restart service bersama.
- `README.md`, `docs/DECISIONS.md`, contoh Nginx HTTPS, OpenAPI dan `tests/test_no_disruption.sh` tersedia.

## Verifikasi lokal

- `python -m pytest -p no:cacheprovider tests/ -q` -- 14 passed (one TestClient/httpx deprecation warning).
- `python -m compileall -q api vpnctl tests` â€” lulus.
- `rg` pencarian `shell=True` pada `vpnctl`, `api`, dan launcher CLI â€” kosong.
- Git Bash `-n` seluruh shell scripts dan `tests/test_no_disruption.sh` â€” lulus; audit statis no-disruption lulus.
- Pytest lokal memakai thread untuk uji konkurensi SQLite karena sandbox Windows memblokir multiprocessing named pipes. Pada POSIX, test memakai 20 proses.

## Uji VM yang masih diperlukan

Pengujian layanan yang diminta sudah selesai di Ubuntu 24.04. Pengujian Debian 12 dan Ubuntu 22.04 sengaja dilewati atas arahan pengguna. Uji klien langsung dari Windows belum dilakukan karena konfigurasi proxy Windows mengarah ke localhost yang tidak aktif di lingkungan ini.

