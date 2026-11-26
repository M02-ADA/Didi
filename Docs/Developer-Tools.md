# Aturan Developer Mode di branch `developer`

Berlaku untuk branch `developer`. Ikuti [TEAM_ALIGNMENT](TEAM_ALIGNMENT.md) untuk kepemilikan file, kontrak, dan persetujuan perubahan.

| Mode | Perilaku yang harus dipertahankan |
| --- | --- |
| **Off** | Tanpa argumen QA khusus, tampilkan alur pemain terbaru dari `staging`, termasuk kalibrasi, Home, HUD, Pause, dan Results. Permainan dimulai dengan dua pemain. Selector, panel skip, target sentuh transparan, dan diagnostik tidak tampil atau menerima sentuhan. |
| **On** | Di Home sediakan **2 Players / 1 Player** dan tombol **Avatar Preview** di kiri atas. Di ronde live Solo dan Co-op, **Pause → Developer Tools** membuka panel dengan hanya dua aksi pengujian **Next Gate** dan **Diamond Time**. Memilih Developer Tools juga menjalankan Resume agar ronde lanjut dengan panel terbuka. Menutup panel tidak menjeda ronde. |

**FTUE berlaku sama untuk kedua mode.** Start Mission mengikuti alur biasa dari intro dan kalibrasi ke ronde, termasuk saat pertama kali bermain. FTUE hanya dimulai lewat menu **Replay Tutorial** di Home dan tetap memerlukan kalibrasi. Melewati FTUE saat bermain biasa tidak mengubah catatan penyelesaian tutorial. Pertahankan pengecualian branch ini saat merge dari staging.

Di build Debug, tahan logo DIDI selama tiga detik untuk menyalakan atau mematikan mode. VoiceOver menyediakan aksi yang sama. Mode tidak disimpan. `-showDebugTools` hanya mengaktifkan izin yang sama untuk sesi Xcode. Saat mode dimatikan di Home, pilihan kembali ke Co-op. Build Release tidak menyediakan Developer Mode.

- Avatar Preview menampilkan kamera dan satu avatar Lemon berdampingan. Gunakan sesi Solo dan feed pose game yang sudah ada. Preview tidak memulai ronde atau mencatat skor. Kamera dilepas saat kembali ke Home.
- Boleh memperbaiki tata letak, aksesibilitas, dan regresi kontrol yang tercantum di atas. Gunakan aksi dan aturan sesi yang sudah ada untuk skip.
- Jangan tambahkan Advanced, Hide, tombol transparan, skip kalibrasi, replay demo, reset tutorial, SFX Lab, diagnostik kamera, Flights, Timing, steering, atau overlay debug lainnya melalui Developer Mode.
- Fixture QA dari staging tetap memakai argumen khusus masing-masing. Menyalakan Developer Mode tidak mengaktifkan fixture, dan fixture tidak menjadi cara untuk menambahkan alat ke UI normal.
- Saat merge staging, pertahankan alur pemain dari staging dan periksa kedua mode. Jalankan UI test Developer Mode dan tes alur Home/kalibrasi. Verifikasi aksi skip Solo dan Co-op di iPad fisik bila menyentuh jalur live. Perluasan daftar kontrol harus disepakati pemilik terdampak dan dicatat di sini sebelum diimplementasikan.
