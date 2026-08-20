# OpenWrt STB Multi-ADB Tethering

Repositori ini berisi sekumpulan script OpenWrt untuk menjalankan dua (atau lebih) perangkat Android sebagai USB Modem (Tethering) secara bersamaan pada STB (Set Top Box) Amlogic.

Fitur utama adalah auto-rename interface berdasarkan Serial Number (SN) perangkat dan otomatis menyalakan mode RNDIS via koneksi ADB (tanpa mematikan ADB Debugging di HP).

## Fitur
1. **Auto RNDIS via ADB:** Tidak perlu mengklik "USB Tethering" secara manual di HP setiap kali dicolok atau direstart. Watchdog akan memaksa OS Android menyalakannya via ADB (`svc usb setFunctions rndis`).
2. **Persistent Interface Naming:** Mengganti nama interface acak dari kernel (misal `eth1`, `usbX`) menjadi nama tetap (`usb0`, `usb1`) yang terikat dengan *Serial Number* spesifik tiap HP. Mencegah OpenWrt/OpenClash kebingungan saat router direstart.
3. **Hotplug Support:** Begitu HP dicolokkan (via kabel USB), script langsung dieksekusi detik itu juga (tanpa perlu menunggu jadwal Cron 1 menit).
4. **Interactive CLI Menu:** Disediakan command `menuadb` untuk mengecek Serial, menetapkan/mendaftarkan interface, cek log, dan toggle mode Cron.

## Kompatibilitas
- OS Router: OpenWrt 23.05 (Amlogic/ophub atau sejenisnya).
- OS Android (Tether): Rata-rata Android 7 hingga 14. (Mendukung fallback perintah syntax lama dan baru).
- Modem Packages: Membutuhkan package ADB bawaan OpenWrt terinstall.

## Instalasi All-in-One Setup (Fresh STB)
Jalankan script ini di STB yang sudah memiliki koneksi internet, script ini akan: membersihkan aplikasi VPN lama (Mihomo, Passwall, Tailscale LuCI), menggantinya dengan Tailscale CLI, menginstall Andromodem, dan menyiapkan env tethering.

```bash
wget -O setup_stb.sh https://raw.githubusercontent.com/jhopan/openwrt/main/script/setup_stb.sh && chmod +x setup_stb.sh && ./setup_stb.sh
```

## Penggunaan (Manual Installation & Setup)
Setelah semua script ini (folder `adb-usb-tether/`) dipindahkan ke STB (biasanya ke folder `/usr/bin/` dan `/etc/hotplug.d/usb/`), lakukan langkah berikut:

1. Colokkan HP ke port USB STB.
2. Di HP, izinkan **USB Debugging** (centang "Always allow from this computer").
3. Di terminal STB, ketik:
   ```bash
   menuadb
   ```
4. Pilih menu **1** untuk melihat *Serial Number* HP yang terhubung.
5. Pilih menu **2**, lalu masukkan *Serial Number* tersebut dan tentukan nama interfacenya (misal: `usb0`).
6. Cabut dan colok kembali HP Anda, atau pilih menu **5** (Trigger Manual). Jaringan HP Anda sekarang bernama `usb0`.

## Catatan Penting Routing (Bila memakai >1 HP)
Jika memakai 2 HP (misal `usb0` dan `usb1`), usahakan segmen IP Tethering kedua HP **BERBEDA** (misal HP-1 = 192.168.42.x, HP-2 = 192.168.43.x). 
Bila IP Tethering tidak bisa diganti dan terpaksa bentrok, Anda wajib:
- Masuk ke LuCI -> Network -> Interfaces.
- Ubah/Tambahkan nilai `metric` yang berbeda pada setiap interface (misal: usb0 metric=10, usb1 metric=20).
- Ikat trafik (load balance) menggunakan metode fwmark/OpenClash dengan *bind* spesifik ke interface, BUKAN gateway IP.