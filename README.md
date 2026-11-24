# WebDAV Player

libmpv (media_kit) tabanli sade WebDAV video oynatici.
**Yalnizca Android 10+ (API 29) ve arm64-v8a (ARMv8) cihazlar** (Android TV dahil).

- Sunucu sabit: `http://192.168.1.44:8080/` (lib/main.dart icinde `_serverUrl`)
- Acilis ekrani: Izleme Listem. Sag alttaki "Listeme ekle" ile sunucudan klasor/video ekle
- Sag ustteki ic ice gecmis daire simgesi = **secim modu** (bir ogeye uzun basmak da aciar):
  klasor/video sec, "Tumunu sec", **Tasi** veya **Kaldir** (sunucudaki dosyalar silinmez)
- **TV'yi kapat** (power simgesi): `192.168.1.44:5555` adresine ADB ile `reboot -p` gonderir
- Oynat/duraklat, +-10 sn sarma, hiz; kaldigin yerden devam; izlendi / yarim gostergesi
- TV uzaktan kumanda: OK oynat/duraklat, sol/sag +-10 sn, yukari/asagi hiz

## TV kapatma icin gerekenler
1. TV'de Gelistirici secenekleri > **ADB hata ayiklama / Ag hata ayiklama** acik olmali (TCP 5555).
2. Ilk denemede TV ekraninda cikan "USB hata ayiklamaya izin ver" sorusunda
   **"Her zaman izin ver"** isaretleyip onayla. Anahtar uygulamada saklanir, sonra sorulmaz.
3. IP/port degistirmek icin `lib/main.dart` icindeki `_tvHost` ve `_tvAdbPort`.

## Derleme
1. Zip'i ac, icindekileri repo kokune koy, main dalina push et.
2. Actions > "Build" (gerekirse "Run workflow").
3. Artifact: `webdav-player-android` (app-arm64-v8a-release.apk, minSdk 29).

Notlar:
- Android klasoru CI'da `flutter create` ile uretilir.
- APK debug anahtariyla imzalanir; "bilinmeyen kaynak" izniyle kurulur.
