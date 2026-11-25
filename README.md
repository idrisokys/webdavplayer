# WebDAV Player

libmpv (media_kit) tabanli sade WebDAV video oynatici.
**Tek APK** (`webdav-player.apk`) hem Android TV (ARMv7, armeabi-v7a) hem mobil (ARMv8, arm64-v8a)
cihazlarda calisir; APK iki mimariyi de icerir, cihaz kendi mimarisini secer. Android 10+ (API 29).

TV modu acilista otomatik algilanir (cihaz Android TV / leanback ise): yalnizca yatay, LEANBACK launcher + banner,
D-pad odak vurgusu, buyuk yazi, kucuk (32 MB) oynatma tamponu; "TV'yi kapat" ve
parlaklik/ses hareketleri TV'de yoktur. Telefon/tablette mobil arayuz acilir.

- Sunucu sabit: `http://192.168.1.44:8080/` (lib/main.dart icinde `_serverUrl`)
- Acilis ekrani: Izleme Listem. Sag alttaki "Listeme ekle" ile sunucudan klasor/video ekle
- Sag ustteki ic ice gecmis daire simgesi = **secim modu** (bir ogeye uzun basmak da aciar):
  klasor/video sec, "Tumunu sec", **Tasi** veya **Kaldir** (sunucudaki dosyalar silinmez)
- **TV'yi kapat** (power simgesi): `192.168.1.44:5555` adresine ADB ile `reboot -p` gonderir
- "Listeye ekle" ekraninin en ustunde **Cihazimdan ekle**: telefondaki klasor ve videolari da ekleyebilirsin
  (ilk seferde "tum dosyalara erisim" izni istenir).
  Cihaza takili **USB HDD / SD kart** da otomatik bulunur: hemen altinda **Harici diskten ekle** satiri cikar
  (`/storage/<UUID>`; ekrani asagi cekince yeniden taranir)
- Izleme Listem'in en sagindaki **cip simgesi** = yurutme bicimi: **Donanim (mediacodec, varsayilan)** / Donanim + (mediacodec-copy) / Yazilim
  (secim kalici; sonraki acilan videoda gecerli olur)
- Klasor gezginlerinde varsayilan siralama **en yeni ustte** (sag ustteki siralama simgesinden degisir);
  Izleme Listem ise harf sirasindadir
- Oynatici: ekrana **basili tut = 3x**; sol yarida yukari/asagi kaydir = **parlaklik**,
  sag yarida = **ses**; alt cubukta durdur/oynat, gecen ve kalan sure, kaydirma cubugu
- Uygulama ikonu: assets/icon.png (CI flutter_launcher_icons ile uretir)
- Yatay / dikey ekran desteklenir (oynatici yataydir)
- Kaldigin yerden devam; izlendi / yarim gostergesi
- TV uzaktan kumanda: OK oynat/duraklat, sol +-10 sn, sag tus kisa basis +10 sn / **basili tut = 3x hizli oynat**, yukari/asagi hiz
- TV listelerde: bir satirdayken **SAG tusu = sec / secimi kaldir** (secim modunu da kendisi acar); Izleme Listem'de klasor satirinda **SOL tusu = yeniden adlandir**; Geri tusu secim modundan cikar

## TV kapatma icin gerekenler
1. TV'de Gelistirici secenekleri > **ADB hata ayiklama / Ag hata ayiklama** acik olmali (TCP 5555).
2. Ilk denemede TV ekraninda cikan "USB hata ayiklamaya izin ver" sorusunda
   **"Her zaman izin ver"** isaretleyip onayla. Anahtar uygulamada saklanir, sonra sorulmaz.
3. IP/port degistirmek icin `lib/main.dart` icindeki `_tvHost` ve `_tvAdbPort`.

## Derleme
1. Zip'i ac, icindekileri repo kokune koy, main dalina push et.
2. Actions > "Build" (gerekirse "Run workflow").
3. Artifact'lar: `webdav-player-mobile-arm64-v8a` (minSdk 29) ve `webdav-player-tv-armeabi-v7a` (minSdk 31).

Yerelde: `flutter build apk --release --split-per-abi --target-platform android-arm64` (mobil),
`... --target-platform android-arm --dart-define=TV=true` (TV; manifest/minSdk ayarlari CI'dadir).

Notlar:
- Android klasoru CI'da `flutter create` ile uretilir.
- APK debug anahtariyla imzalanir; "bilinmeyen kaynak" izniyle kurulur.
