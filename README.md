# WebDAV Player

libmpv (media_kit) tabanli sade WebDAV video oynatici.
**Tek APK** (`webdav-player.apk`) hem Android TV (ARMv7, armeabi-v7a) hem mobil (ARMv8, arm64-v8a)
cihazlarda calisir; APK iki mimariyi de icerir, cihaz kendi mimarisini secer. Android 10+ (API 29).

TV modu acilista otomatik algilanir (cihaz Android TV / leanback ise): yalnizca yatay, LEANBACK launcher + banner,
D-pad odak vurgusu, buyuk yazi, kucuk (32 MB) oynatma tamponu; "TV'yi kapat" ve
parlaklik/ses hareketleri TV'de yoktur. Telefon/tablette mobil arayuz acilir.

- Sunucu sabit: `http://192.168.1.44:8080/` (lib/main.dart icinde `_serverUrl`)
- Acilis ekrani: Izleme Listem. Basligin yanindaki kucuk **+** ile sunucudan / cihazdan / harici diskten klasor-video ekle
- Secim renkle gosterilir (onay kutusu yok). Dokunmatik: satira **uzun bas** = sec, sonra dokunarak ekle/cikar
- Izleme Listem: sag ustteki **Listeden cikar** dugmesi secilenleri listeden kaldirir (sunucudaki dosyalar silinmez)
- Ekleme ekrani: sag ustteki **Listeme ekle** dugmesi secilenleri izleme listesine ekler; en yeni klasor ustte
- **Kumanda SOL tusu (her ekranda)**: satiri sec / secimi kaldir; **SOL tusa basili tut**: izleme listesinde secili satir(lar)i listeden cikarir, ekleme ekraninda izleme listesine ekler
- Sunucuya (WebDAV) ulasilamazsa hata gosterilmez
- Yurutme bicimi her zaman **Donanim (mediacodec)**
- Izleme Listem harf sirasindadir
- Oynatici: ekrana **basili tut = 3x**; sol yarida yukari/asagi kaydir = **parlaklik**,
  sag yarida = **ses**; alt cubukta durdur/oynat, gecen ve kalan sure, kaydirma cubugu
- Uygulama ikonu: assets/icon.png (CI flutter_launcher_icons ile uretir)
- Kaldigin yerden devam; video adinin yaninda kirmizi izlenme yuzdesi (%)
- Oynaticida TV kumandasi: OK oynat/duraklat, sol +-10 sn, sag tus kisa basis +10 sn / basili tut = 3x hizli oynat, yukari/asagi hiz

## Derleme
1. Zip'i ac, icindekileri repo kokune koy, main dalina push et.
2. Actions > "Build" (gerekirse "Run workflow").
3. Artifact'lar: `webdav-player-mobile-arm64-v8a` (minSdk 29) ve `webdav-player-tv-armeabi-v7a` (minSdk 31).

Yerelde: `flutter build apk --release --split-per-abi --target-platform android-arm64` (mobil),
`... --target-platform android-arm --dart-define=TV=true` (TV; manifest/minSdk ayarlari CI'dadir).

Notlar:
- Android klasoru CI'da `flutter create` ile uretilir.
- APK debug anahtariyla imzalanir; "bilinmeyen kaynak" izniyle kurulur.
