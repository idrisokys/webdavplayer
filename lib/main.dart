import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:xml/xml.dart';

import 'adb.dart';

// ============================================================================
//  Sabitler / yardimcilar
// ============================================================================
const _videoExt = {
  '.mkv', '.mp4', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v',
  '.ts', '.mpg', '.mpeg', '.m2ts', '.3gp',
};
const _watchedRatio = 0.95;
const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0];
const _holdSpeed = 2.5; // oynaticiya basili tutunca
const _deviceRoot = '/storage/emulated/0';
const _allOrientations = [
  DeviceOrientation.portraitUp,
  DeviceOrientation.portraitDown,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

// TV (kapatilacak cihaz) - ADB ag hata ayiklama
const _tvHost = '192.168.1.44';
const _tvAdbPort = 5555;

String fmtDur(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

String fmtSec(double s) => fmtDur(Duration(milliseconds: (s * 1000).round()));

String _decode(String s) {
  try {
    return Uri.decodeFull(s);
  } catch (_) {
    return s;
  }
}

const _trAlpha = 'abcçdefgğhıijklmnoöpqrsştuüvwxyz';

int _chKey(int c) {
  final i = _trAlpha.codeUnits.indexOf(c);
  return i >= 0 ? 0x1000 + i : c;
}

int _cmpText(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final c = _chKey(a.codeUnitAt(i)).compareTo(_chKey(b.codeUnitAt(i)));
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}

/// Dogal (sayilari sayi olarak) ve Turkce harf sirali, buyuk/kucuk harf duyarsiz.
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  String norm(String x) => x.replaceAll('İ', 'i').toLowerCase();
  final pa = re.allMatches(norm(a)).map((m) => m.group(0)!).toList();
  final pb = re.allMatches(norm(b)).map((m) => m.group(0)!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final x = pa[i], y = pb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : _cmpText(x, y);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

// ============================================================================
//  Sunucu (sabit)
// ============================================================================
const _serverUrl = 'http://192.168.1.44:8080/';

class Config {
  const Config();
  String get url => _serverUrl;
  Map<String, String> get authHeaders => const {};
  bool get allowInsecure => false;
}

const kConfig = Config();


// ============================================================================
//  Izleme ilerlemesi
// ============================================================================
class Entry {
  final double pos;
  final double dur;
  final bool watched;
  const Entry(this.pos, this.dur, this.watched);
}

class ProgressStore {
  ProgressStore._();
  static final ProgressStore instance = ProgressStore._();

  late SharedPreferences _p;
  Map<String, dynamic> _data = {};

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p.getString('progress');
    if (raw != null) {
      try {
        _data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        _data = {};
      }
    }
  }

  Entry get(String key) {
    final m = _data[key];
    if (m is Map) {
      return Entry(
        (m['pos'] as num?)?.toDouble() ?? 0,
        (m['dur'] as num?)?.toDouble() ?? 0,
        m['watched'] == true,
      );
    }
    return const Entry(0, 0, false);
  }

  Future<void> update(String key, double pos, double dur,
      {bool? watched}) async {
    final w = watched ?? (dur > 0 && pos / dur >= _watchedRatio);
    _data[key] = {'pos': w ? 0.0 : pos, 'dur': dur, 'watched': w};
    await _p.setString('progress', jsonEncode(_data));
  }
}

// ============================================================================
//  WebDAV
// ============================================================================
class DavItem {
  final String name;
  final Uri uri;
  final String key; // cozulmus yol - ilerleme anahtari
  final bool isDir;
  final DateTime? modified; // siralama icin (kalici degil)
  DavItem(this.name, this.uri, this.key, this.isDir, {this.modified});

  bool get isLocal => uri.scheme == 'file';

  Map<String, dynamic> toJson() => {
        'name': name,
        'uri': uri.toString(),
        'key': key,
        'isDir': isDir,
      };

  factory DavItem.fromJson(Map<String, dynamic> m) => DavItem(
        m['name'] as String,
        Uri.parse(m['uri'] as String),
        m['key'] as String,
        m['isDir'] as bool,
      );
}

class DavError implements Exception {
  final String message;
  DavError(this.message);
  @override
  String toString() => message;
}

const _propBody = '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>'
    '</d:prop></d:propfind>';

Future<List<DavItem>> propfind(Config cfg, Uri dir) async {
  final client = http.Client();
  try {
    final req = http.Request('PROPFIND', dir)
      ..headers.addAll({
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
        ...cfg.authHeaders,
      })
      ..body = _propBody;
    final streamed =
        await client.send(req).timeout(const Duration(seconds: 30));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw DavError(
          'Yetkilendirme hatasi (${res.statusCode}). Sunucu kimlik dogrulama istiyor.');
    }
    if (res.statusCode != 207 && res.statusCode != 200) {
      throw DavError('Sunucu hatasi: HTTP ${res.statusCode}');
    }
    final doc = XmlDocument.parse(utf8.decode(res.bodyBytes, allowMalformed: true));
    final selfPath = _decode(dir.path).replaceAll(RegExp(r'/+$'), '');
    final items = <DavItem>[];

    for (final r in doc.findAllElements('response', namespace: '*')) {
      final hrefs = r.findElements('href', namespace: '*');
      if (hrefs.isEmpty) continue;
      final href = hrefs.first.innerText.trim();
      var uri = dir.resolve(href);
      final path = _decode(uri.path);
      if (path.replaceAll(RegExp(r'/+$'), '') == selfPath) continue;

      final isDir = r.findAllElements('collection', namespace: '*').isNotEmpty;
      final segs = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty) continue;
      final name = segs.last;
      if (name.startsWith('.')) continue;

      if (!isDir) {
        final dot = name.lastIndexOf('.');
        final ext = dot >= 0 ? name.substring(dot).toLowerCase() : '';
        if (!_videoExt.contains(ext)) continue;
      } else if (!uri.path.endsWith('/')) {
        uri = uri.replace(path: '${uri.path}/');
      }
      DateTime? modified;
      final lm = r.findAllElements('getlastmodified', namespace: '*');
      if (lm.isNotEmpty) {
        final t = lm.first.innerText.trim();
        try {
          modified = HttpDate.parse(t);
        } catch (_) {
          modified = DateTime.tryParse(t);
        }
      }
      items.add(DavItem(name, uri, path, isDir, modified: modified));
    }
    return items;
  } on TimeoutException {
    throw DavError('Sunucu zaman asimina ugradi.');
  } on SocketException catch (e) {
    throw DavError('Baglanti kurulamadi: ${e.message}');
  } on HandshakeException {
    throw DavError(
        'SSL sertifika hatasi.');
  } on XmlException {
    throw DavError('Sunucudan gecersiz yanit alindi (WebDAV adresi dogru mu?).');
  } finally {
    client.close();
  }
}

/// Telefon icindeki klasor / video listesi (dart:io).
Future<List<DavItem>> listLocal(Uri dir) async {
  final items = <DavItem>[];
  try {
    for (final e in Directory.fromUri(dir).listSync(followLinks: false)) {
      final name = e.path.substring(e.path.lastIndexOf('/') + 1);
      if (name.isEmpty || name.startsWith('.')) continue;
      final isDir = FileSystemEntity.isDirectorySync(e.path);
      if (!isDir) {
        final dot = name.lastIndexOf('.');
        final ext = dot >= 0 ? name.substring(dot).toLowerCase() : '';
        if (!_videoExt.contains(ext)) continue;
      }
      DateTime? modified;
      try {
        modified = e.statSync().modified;
      } catch (_) {}
      items.add(DavItem(
        name,
        isDir ? Directory(e.path).uri : File(e.path).uri,
        'local:${e.path}',
        isDir,
        modified: modified,
      ));
    }
  } on FileSystemException {
    throw DavError(
        'Klasör okunamadı. Depolama erişim izni verildi mi?');
  }
  return items;
}

enum SortMode { newest, oldest, nameAsc, nameDesc }

String sortLabel(SortMode m) => switch (m) {
      SortMode.newest => 'En yeni üstte',
      SortMode.oldest => 'En eski üstte',
      SortMode.nameAsc => 'Ad (A → Z)',
      SortMode.nameDesc => 'Ad (Z → A)',
    };

/// Klasorler her zaman dosyalardan once gelir.
List<DavItem> sortItems(List<DavItem> list, SortMode mode) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final out = [...list];
  out.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    switch (mode) {
      case SortMode.newest:
        final c = (b.modified ?? epoch).compareTo(a.modified ?? epoch);
        return c != 0 ? c : naturalCompare(a.name, b.name);
      case SortMode.oldest:
        final c = (a.modified ?? epoch).compareTo(b.modified ?? epoch);
        return c != 0 ? c : naturalCompare(a.name, b.name);
      case SortMode.nameAsc:
        return naturalCompare(a.name, b.name);
      case SortMode.nameDesc:
        return naturalCompare(b.name, a.name);
    }
  });
  return out;
}

// ============================================================================
//  Izleme listesi (kalici)
// ============================================================================
class WlFolder {
  final String id;
  String name;
  WlFolder(this.id, this.name);
}

class WlItem {
  final DavItem item;
  String? folder;
  WlItem(this.item, this.folder);
}

class AddResult {
  final int added;
  final int moved;
  const AddResult(this.added, this.moved);
}

class WatchlistStore extends ChangeNotifier {
  WatchlistStore._();
  static final WatchlistStore instance = WatchlistStore._();

  late SharedPreferences _p;
  final List<WlFolder> folders = [];
  final List<WlItem> items = [];

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p.getString('watchlist');
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      for (final f in (m['folders'] as List? ?? [])) {
        folders.add(WlFolder(f['id'] as String, f['name'] as String));
      }
      for (final i in (m['items'] as List? ?? [])) {
        items.add(WlItem(
          DavItem.fromJson(Map<String, dynamic>.from(i as Map)),
          i['folder'] as String?,
        ));
      }
    } catch (_) {
      folders.clear();
      items.clear();
    }
  }

  Future<void> _save() async {
    await _p.setString(
      'watchlist',
      jsonEncode({
        'folders': [
          for (final f in folders) {'id': f.id, 'name': f.name},
        ],
        'items': [
          for (final i in items) {...i.item.toJson(), 'folder': i.folder},
        ],
      }),
    );
    notifyListeners();
  }

  bool contains(String key) => items.any((e) => e.item.key == key);

  /// Izleme listesi: harf sirasi (Turkce, dogal siralama).
  List<WlItem> itemsIn(String? folder) => items
      .where((e) => e.folder == folder)
      .toList()
    ..sort((a, b) => naturalCompare(a.item.name, b.item.name));

  List<WlFolder> get sortedFolders =>
      [...folders]..sort((a, b) => naturalCompare(a.name, b.name));

  int countIn(String id) => items.where((e) => e.folder == id).length;

  WlFolder? folderById(String? id) {
    if (id == null) return null;
    for (final f in folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  Future<WlFolder> createFolder(String name) async {
    final f = WlFolder(DateTime.now().microsecondsSinceEpoch.toString(), name);
    folders.add(f);
    await _save();
    return f;
  }

  Future<void> renameFolder(String id, String name) async {
    final f = folderById(id);
    if (f == null) return;
    f.name = name;
    await _save();
  }

  /// Klasor silinince icindeki ogeler ana listeye tasinir.
  Future<void> deleteFolder(String id) async {
    for (final i in items) {
      if (i.folder == id) i.folder = null;
    }
    folders.removeWhere((f) => f.id == id);
    await _save();
  }

  Future<AddResult> addAll(Iterable<DavItem> list, {String? folder}) async {
    var added = 0, moved = 0;
    for (final it in list) {
      final idx = items.indexWhere((e) => e.item.key == it.key);
      if (idx < 0) {
        items.add(WlItem(it, folder));
        added++;
      } else if (folder != null && items[idx].folder != folder) {
        items[idx].folder = folder;
        moved++;
      }
    }
    if (added + moved > 0) await _save();
    return AddResult(added, moved);
  }

  Future<void> moveItem(String key, String? folder) async {
    final idx = items.indexWhere((e) => e.item.key == key);
    if (idx < 0) return;
    items[idx].folder = folder;
    await _save();
  }

  Future<void> removeItem(String key) async {
    items.removeWhere((e) => e.item.key == key);
    await _save();
  }

  Future<void> moveItems(Set<String> keys, String? folder) async {
    for (final i in items) {
      if (keys.contains(i.item.key)) i.folder = folder;
    }
    await _save();
  }

  Future<void> removeItems(Set<String> keys) async {
    items.removeWhere((e) => keys.contains(e.item.key));
    await _save();
  }

  /// [withItems] true ise klasorlerin icindekiler de listeden kalkar,
  /// false ise ana listeye tasinir.
  Future<void> deleteFolders(Set<String> ids, {required bool withItems}) async {
    if (withItems) {
      items.removeWhere((e) => ids.contains(e.folder));
    } else {
      for (final i in items) {
        if (ids.contains(i.folder)) i.folder = null;
      }
    }
    folders.removeWhere((f) => ids.contains(f.id));
    await _save();
  }
}

// ============================================================================
//  Ortak diyaloglar
// ============================================================================
class _NameDialog extends StatefulWidget {
  final String title;
  final String initial;
  const _NameDialog({required this.title, required this.initial});
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Klasör adı',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _c.text.trim()),
          child: const Text('Tamam'),
        ),
      ],
    );
  }
}

Future<String?> askName(BuildContext context, String title,
    {String initial = ''}) async {
  final r = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, initial: initial),
  );
  if (r == null || r.isEmpty) return null;
  return r;
}

Future<bool> askConfirm(BuildContext context, String title, String body) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Evet'),
        ),
      ],
    ),
  );
  return r ?? false;
}

class FolderChoice {
  final String? id; // null = ana liste
  const FolderChoice(this.id);
}

Widget _optRow(IconData icon, String text, {bool current = false}) {
  return Row(
    children: [
      Icon(icon, color: Colors.amber),
      const SizedBox(width: 14),
      Expanded(child: Text(text, overflow: TextOverflow.ellipsis)),
      if (current) const Icon(Icons.check, size: 18),
    ],
  );
}

/// Klasor sec / yeni klasor olustur. Iptalde null doner.
Future<FolderChoice?> showFolderPicker(
  BuildContext context, {
  String? current,
  bool allowRoot = true,
  String title = 'Klasör seç',
}) {
  return showDialog<FolderChoice>(
    context: context,
    builder: (ctx) {
      final st = WatchlistStore.instance;
      // id = olusturma zamani -> en yeni klasor en ustte
      final fs = [...st.folders]..sort((a, b) =>
          (int.tryParse(b.id) ?? 0).compareTo(int.tryParse(a.id) ?? 0));
      return SimpleDialog(
        title: Text(title),
        children: [
          if (allowRoot)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, const FolderChoice(null)),
              child: _optRow(Icons.home_outlined, 'Ana liste',
                  current: current == null),
            ),
          for (final f in fs)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, FolderChoice(f.id)),
              child: _optRow(Icons.folder_special, f.name,
                  current: current == f.id),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final name = await askName(ctx, 'Yeni klasör');
              if (name == null) return;
              final f = await st.createFolder(name);
              if (ctx.mounted) Navigator.pop(ctx, FolderChoice(f.id));
            },
            child: _optRow(Icons.create_new_folder_outlined, 'Yeni klasör oluştur'),
          ),
        ],
      );
    },
  );
}

// ============================================================================
//  Ortak ogeler (ikonlar)
// ============================================================================
Widget statusIcon(DavItem it, {bool inWatchlist = false}) {
  if (it.isDir) {
    return Icon(inWatchlist ? Icons.folder_open : Icons.folder,
        color: Colors.lightBlueAccent, size: 28);
  }
  final e = ProgressStore.instance.get(it.key);
  if (e.watched) {
    return const Icon(Icons.check_circle, color: Colors.green, size: 28);
  }
  if (e.pos > 5 && e.dur > 0) {
    return SizedBox(
      width: 26,
      height: 26,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: (e.pos / e.dur).clamp(0.03, 1.0),
              strokeWidth: 3.5,
              color: Colors.orange,
              backgroundColor: Colors.white24,
            ),
          ),
          const Icon(Icons.play_arrow, size: 14, color: Colors.orange),
        ],
      ),
    );
  }
  return const Icon(Icons.movie_outlined, color: Colors.white38, size: 26);
}

String? progressText(DavItem it) {
  if (it.isDir) return null;
  final e = ProgressStore.instance.get(it.key);
  if (!e.watched && e.pos > 5 && e.dur > 0) {
    return '${fmtSec(e.pos)} / ${fmtSec(e.dur)}  •  %${(e.pos / e.dur * 100).floor()}';
  }
  if (e.watched) return 'İzlendi';
  return null;
}


// ============================================================================
//  Uygulama
// ============================================================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await SystemChrome.setPreferredOrientations(_allOrientations);
  await ProgressStore.instance.init();
  await WatchlistStore.instance.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebDAV Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepOrange,
          brightness: Brightness.dark,
        ),
      ),
      builder: (context, child) {
        // Genis ekranlarda (Android TV / tablet) yaziyi biraz buyut
        final mq = MediaQuery.of(context);
        // Yatay ekranda kesinti (notch) kenarlarini bos birak
        Widget body = SafeArea(top: false, bottom: false, child: child!);
        if (Platform.isAndroid &&
            mq.size.width >= 900 &&
            mq.size.shortestSide >= 500) {
          body = MediaQuery(
            data: mq.copyWith(textScaler: TextScaler.linear(1.15)),
            child: body,
          );
        }
        return body;
      },
      home: const WatchlistScreen(),
    );
  }
}

// ============================================================================
//  Izleme listem (acilis ekrani)
// ============================================================================
class WatchlistScreen extends StatefulWidget {
  final String? folderId; // null = ana liste
  const WatchlistScreen({super.key, this.folderId});
  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  final st = WatchlistStore.instance;

  // secim modu
  bool selecting = false;
  final Set<String> selFolders = {};
  final Set<String> selItems = {};

  int get _selCount => selFolders.length + selItems.length;

  void _exitSelect() => setState(() {
        selecting = false;
        selFolders.clear();
        selItems.clear();
      });

  void _toggleFolder(String id) => setState(() {
        if (!selFolders.remove(id)) selFolders.add(id);
      });

  void _toggleItem(String key) => setState(() {
        if (!selItems.remove(key)) selItems.add(key);
      });

  bool _allSelected(List<WlFolder> folders, List<WlItem> its) =>
      (folders.isNotEmpty || its.isNotEmpty) &&
      folders.every((f) => selFolders.contains(f.id)) &&
      its.every((w) => selItems.contains(w.item.key));

  void _toggleAll(List<WlFolder> folders, List<WlItem> its) {
    setState(() {
      if (_allSelected(folders, its)) {
        selFolders.clear();
        selItems.clear();
      } else {
        selFolders.addAll(folders.map((f) => f.id));
        selItems.addAll(its.map((w) => w.item.key));
      }
    });
  }

  // ---- islemler
  Future<void> _newFolder() async {
    final name = await askName(context, 'Yeni klasör');
    if (name != null) await st.createFolder(name);
  }

  Future<void> _openAdd() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BrowserScreen(
        start: Uri.parse(kConfig.url),
        selectMode: true,
        targetFolder: widget.folderId,
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _play(DavItem it) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(cfg: kConfig, item: it),
    ));
    if (mounted) setState(() {}); // ikonlari guncelle
  }

  Future<void> _openDir(DavItem it) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BrowserScreen(start: it.uri, selectMode: false),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _moveSelected() async {
    if (selItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Klasörler taşınamaz, taşımak için video seç.'),
      ));
      return;
    }
    final c = await showFolderPicker(
      context,
      current: widget.folderId,
      title: '${selItems.length} öğeyi taşı',
    );
    if (c == null) return;
    final n = selItems.length;
    await st.moveItems(Set.of(selItems), c.id);
    if (!mounted) return;
    _exitSelect();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$n öğe taşındı')));
  }

  Future<void> _removeSelected() async {
    final hasF = selFolders.isNotEmpty;
    final parts = <String>[
      if (hasF) '${selFolders.length} klasör',
      if (selItems.isNotEmpty) '${selItems.length} öğe',
    ];
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Listeden kaldırılsın mı?'),
        content: Text(
          '${parts.join(' ve ')} listeden kaldırılacak. '
          'Sunucudaki dosyalar silinmez.'
          '${hasF ? '\n\n"İçerikleri koru": klasörlerdeki videolar ana listeye taşınır.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal'),
          ),
          if (hasF)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep'),
              child: const Text('İçerikleri koru'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'all'),
            child: Text(hasF ? 'Hepsini kaldır' : 'Kaldır'),
          ),
        ],
      ),
    );
    if (r == null) return;
    final items = Set.of(selItems);
    final folders = Set.of(selFolders);
    if (items.isNotEmpty) await st.removeItems(items);
    if (folders.isNotEmpty) {
      await st.deleteFolders(folders, withItems: r == 'all');
    }
    if (!mounted) return;
    _exitSelect();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Listeden kaldırıldı')));
  }

  Future<void> _renameFolder(WlFolder f) async {
    final name = await askName(context, 'Klasörü yeniden adlandır',
        initial: f.name);
    if (name != null) await st.renameFolder(f.id, name);
  }

  Future<void> _powerOffTv() async {
    final ok = await askConfirm(
      context,
      'TV kapatılsın mı?',
      '$_tvHost cihazına ADB ile "reboot -p" gönderilecek.',
    );
    if (!ok || !mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3)),
            SizedBox(width: 20),
            Expanded(
              child: Text('TV\'ye bağlanılıyor…\nİlk seferde TV ekranında '
                  '"Her zaman izin ver"i işaretleyip onayla.'),
            ),
          ],
        ),
      ),
    );
    final res = await adbShell(_tvHost, _tvAdbPort, 'reboot -p');
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(res.message)));
  }

  // ---- arayuz
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) {
        final inRoot = widget.folderId == null;
        final folder = st.folderById(widget.folderId);
        final folders = inRoot ? st.sortedFolders : <WlFolder>[];
        final its = st.itemsIn(widget.folderId);
        final empty = folders.isEmpty && its.isEmpty;

        return PopScope(
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _exitSelect();
          },
          child: Scaffold(
            appBar: selecting
                ? AppBar(
                    leading: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Seçim modundan çık',
                      onPressed: _exitSelect,
                    ),
                    title: Text('$_selCount seçili'),
                    actions: [
                      IconButton(
                        icon: Icon(_allSelected(folders, its)
                            ? Icons.deselect
                            : Icons.select_all),
                        tooltip: _allSelected(folders, its)
                            ? 'Seçimi kaldır'
                            : 'Tümünü seç',
                        onPressed: () => _toggleAll(folders, its),
                      ),
                    ],
                  )
                : AppBar(
                    title: Text(
                        inRoot ? 'İzleme Listem' : (folder?.name ?? 'Klasör')),
                    actions: [
                      if (inRoot)
                        IconButton(
                          icon: const Icon(Icons.power_settings_new),
                          tooltip: 'TV\'yi kapat',
                          onPressed: _powerOffTv,
                        ),
                      if (inRoot)
                        IconButton(
                          icon: const Icon(Icons.create_new_folder_outlined),
                          tooltip: 'Yeni klasör',
                          onPressed: _newFolder,
                        ),
                      IconButton(
                        icon: const Icon(Icons.join_inner),
                        tooltip: 'Seçim modu',
                        onPressed: empty
                            ? null
                            : () => setState(() => selecting = true),
                      ),
                    ],
                  ),
            floatingActionButton: selecting
                ? null
                : FloatingActionButton.extended(
                    onPressed: _openAdd,
                    icon: const Icon(Icons.add),
                    label: const Text('Listeme ekle'),
                  ),
            bottomNavigationBar: selecting ? _selectBar() : null,
            body: empty ? _emptyView() : _list(folders, its),
          ),
        );
      },
    );
  }

  Widget _selectBar() {
    final none = _selCount == 0;
    return Material(
      elevation: 8,
      color: Colors.grey.shade900,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: selItems.isEmpty ? null : _moveSelected,
                icon: const Icon(Icons.drive_file_move_outline),
                label: const Text('Taşı'),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade700),
                onPressed: none ? null : _removeSelected,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Kaldır'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyView() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_play, size: 64, color: Colors.white38),
            SizedBox(height: 12),
            Text(
              'Listen boş.\nSağ alttaki "Listeme ekle" ile sunucundan video veya klasör ekle.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(List<WlFolder> folders, List<WlItem> its) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        for (final f in folders)
          ListTile(
            selected: selFolders.contains(f.id),
            selectedTileColor: Colors.white12,
            leading: const SizedBox(
              width: 32,
              child: Center(
                  child: Icon(Icons.folder_special, color: Colors.amber, size: 28)),
            ),
            title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${st.countIn(f.id)} öğe'),
            trailing: selecting
                ? Checkbox(
                    value: selFolders.contains(f.id),
                    onChanged: (_) => _toggleFolder(f.id),
                  )
                : PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'rename') _renameFolder(f);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'rename', child: Text('Yeniden adlandır')),
                    ],
                  ),
            onTap: () {
              if (selecting) {
                _toggleFolder(f.id);
              } else {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => WatchlistScreen(folderId: f.id),
                ));
              }
            },
            onLongPress: selecting
                ? null
                : () => setState(() {
                      selecting = true;
                      selFolders.add(f.id);
                    }),
          ),
        for (final w in its)
          ListTile(
            selected: selItems.contains(w.item.key),
            selectedTileColor: Colors.white12,
            leading: SizedBox(
              width: 32,
              child: Center(child: statusIcon(w.item, inWatchlist: true)),
            ),
            title: Text(w.item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: progressText(w.item) == null
                ? null
                : Text(
                    progressText(w.item)!,
                    style: TextStyle(
                      color: progressText(w.item) == 'İzlendi'
                          ? null
                          : Colors.orange,
                    ),
                  ),
            trailing: selecting
                ? Checkbox(
                    value: selItems.contains(w.item.key),
                    onChanged: (_) => _toggleItem(w.item.key),
                  )
                : null,
            onTap: () {
              if (selecting) {
                _toggleItem(w.item.key);
              } else if (w.item.isDir) {
                _openDir(w.item);
              } else {
                _play(w.item);
              }
            },
            onLongPress: selecting
                ? null
                : () => setState(() {
                      selecting = true;
                      selItems.add(w.item.key);
                    }),
          ),
      ],
    );
  }
}

// ============================================================================
//  Sunucu gezgini (ekleme ekrani / klasor izleme)
// ============================================================================
class BrowserScreen extends StatefulWidget {
  final Uri start;
  final bool selectMode; // true: listeye ekleme ekrani
  final String? targetFolder; // ekleme hedefi (null = ana liste)
  const BrowserScreen({
    super.key,
    required this.start,
    required this.selectMode,
    this.targetFolder,
  });
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final List<Uri> stack;
  final Map<String, DavItem> selected = {};
  List<DavItem> items = [];
  SortMode sort = SortMode.newest; // varsayilan: en yeni ustte
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    var u = widget.start.toString();
    if (!u.endsWith('/')) u = '$u/';
    stack = [Uri.parse(u)];
    _load();
  }

  bool get _atServerRoot => widget.selectMode && stack.length == 1;
  bool get _isLocal => stack.last.scheme == 'file';

  String get _title {
    if (_atServerRoot) return 'Listeye ekle';
    final segs = stack.last.pathSegments.where((s) => s.isNotEmpty).toList();
    if (_isLocal && stack.last.path.replaceAll(RegExp(r'/+$'), '') == _deviceRoot) {
      return 'Cihaz belleği';
    }
    return segs.isEmpty ? 'Sunucu' : _decode(segs.last);
  }

  bool get _allSelected =>
      items.isNotEmpty && items.every((i) => selected.containsKey(i.key));

  Future<void> _ensureStorage() async {
    if (!Platform.isAndroid) return;
    if (await Permission.manageExternalStorage.isGranted) return;
    final r = await Permission.manageExternalStorage.request();
    if (r.isGranted) return;
    if (await Permission.storage.isGranted) return;
    await Permission.storage.request(); // Android 10 ve oncesi
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final List<DavItem> r;
      if (_isLocal) {
        await _ensureStorage();
        r = await listLocal(stack.last);
      } else {
        r = await propfind(kConfig, stack.last);
      }
      if (!mounted) return;
      setState(() {
        items = sortItems(r, sort);
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        items = [];
        error = e.toString();
        loading = false;
      });
    }
  }

  void _up() {
    if (stack.length > 1) {
      stack.removeLast();
      _load();
    }
  }

  void _toggle(DavItem it) {
    setState(() {
      if (selected.containsKey(it.key)) {
        selected.remove(it.key);
      } else {
        selected[it.key] = it;
      }
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        for (final i in items) {
          selected.remove(i.key);
        }
      } else {
        for (final i in items) {
          selected[i.key] = i;
        }
      }
    });
  }

  Future<void> _addSelected({required bool pickFolder}) async {
    String? folder = widget.targetFolder;
    if (pickFolder) {
      final c = await showFolderPicker(
        context,
        current: folder,
        title: 'Hangi klasöre eklensin?',
      );
      if (c == null) return;
      folder = c.id;
    }
    final r = await WatchlistStore.instance
        .addAll(selected.values.toList(), folder: folder);
    if (!mounted) return;
    final parts = <String>[
      if (r.added > 0) '${r.added} öğe eklendi',
      if (r.moved > 0) '${r.moved} öğe klasöre taşındı',
    ];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          parts.isEmpty ? 'Seçilenler zaten listede' : parts.join(', ')),
    ));
    setState(selected.clear);
  }

  Future<void> _enter(DavItem it) async {
    stack.add(it.uri);
    await _load();
  }

  Future<void> _openDevice() async {
    stack.add(Directory(_deviceRoot).uri);
    await _load();
  }

  Future<void> _play(DavItem it) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(cfg: kConfig, item: it),
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (stack.length > 1) {
                _up();
              } else {
                Navigator.of(context).maybePop();
              }
            },
          ),
          title: Text(_title, overflow: TextOverflow.ellipsis),
          actions: [
            if (widget.selectMode && items.isNotEmpty)
              TextButton.icon(
                onPressed: _toggleAll,
                icon: Icon(_allSelected ? Icons.deselect : Icons.select_all),
                label: Text(_allSelected ? 'Seçimi kaldır' : 'Tümünü seç'),
              ),
            PopupMenuButton<SortMode>(
              icon: const Icon(Icons.sort),
              tooltip: 'Sırala',
              initialValue: sort,
              onSelected: (m) => setState(() {
                sort = m;
                items = sortItems(items, m);
              }),
              itemBuilder: (_) => [
                for (final m in SortMode.values)
                  CheckedPopupMenuItem(
                    value: m,
                    checked: m == sort,
                    child: Text(sortLabel(m)),
                  ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Yenile',
              onPressed: _load,
            ),
          ],
        ),
        body: _body(),
        bottomNavigationBar:
            widget.selectMode && selected.isNotEmpty ? _selectBar() : null,
      ),
    );
  }

  Widget _selectBar() {
    return Material(
      elevation: 8,
      color: Colors.grey.shade900,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Seçimi temizle',
                    onPressed: () => setState(selected.clear),
                  ),
                  Text('${selected.length} seçili'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _addSelected(pickFolder: true),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Klasöre ekle'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _addSelected(pickFolder: false),
                    icon: const Icon(Icons.playlist_add),
                    label: Text(widget.targetFolder == null
                        ? 'Listeme ekle'
                        : 'Bu klasöre ekle'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deviceRow() {
    return ListTile(
      leading: const SizedBox(
        width: 32,
        child: Center(
          child: Icon(Icons.phone_android,
              color: Colors.lightGreenAccent, size: 28),
        ),
      ),
      title: const Text('Cihazımdan ekle'),
      subtitle: const Text('Telefondaki klasör ve videolar'),
      trailing: const Icon(Icons.chevron_right),
      onTap: _openDevice,
    );
  }

  Widget _errorView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
          const SizedBox(height: 12),
          Text(error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Tekrar dene'),
              ),
              if (_isLocal)
                OutlinedButton.icon(
                  onPressed: openAppSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('İzin ayarları'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tile(DavItem it) {
    final wl = WatchlistStore.instance;
    final inList = widget.selectMode && wl.contains(it.key);
    final prog = progressText(it);
    final sub = [
      if (inList) 'Listede',
      if (prog != null) prog,
    ].join('  •  ');
    final sel = selected.containsKey(it.key);
    return ListTile(
      selected: sel,
      selectedTileColor: Colors.white12,
      leading: SizedBox(width: 32, child: Center(child: statusIcon(it))),
      title: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: sub.isEmpty
          ? null
          : Text(sub,
              style: TextStyle(
                  color: prog != null && prog != 'İzlendi'
                      ? Colors.orange
                      : null)),
      trailing: widget.selectMode
          ? Checkbox(value: sel, onChanged: (_) => _toggle(it))
          : null,
      onTap: () {
        if (it.isDir) {
          _enter(it);
        } else if (widget.selectMode) {
          _toggle(it);
        } else {
          _play(it);
        }
      },
    );
  }

  Widget _body() {
    // Sunucu kokunde "Cihazimdan ekle" satiri her durumda en ustte gorunur
    final pre = <Widget>[
      if (_atServerRoot) _deviceRow(),
      if (_atServerRoot) const Divider(height: 1),
    ];
    final List<Widget>? tail = loading
        ? const [
            Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            ),
          ]
        : error != null
            ? [_errorView()]
            : items.isEmpty
                ? const [
                    Padding(
                      padding: EdgeInsets.all(48),
                      child: Center(child: Text('Video bulunamadı')),
                    ),
                  ]
                : null;
    final count = pre.length + (tail?.length ?? items.length);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: count,
        itemBuilder: (_, i) {
          if (i < pre.length) return pre[i];
          final j = i - pre.length;
          return tail != null ? tail[j] : _tile(items[j]);
        },
      ),
    );
  }
}


// ============================================================================
//  Oynatici
// ============================================================================
class PlayerScreen extends StatefulWidget {
  final Config cfg;
  final DavItem item;
  const PlayerScreen({super.key, required this.cfg, required this.item});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player player;
  late final VideoController controller;
  final FocusNode _focus = FocusNode();
  final List<StreamSubscription> _subs = [];
  Timer? _hideTimer;
  Timer? _saveTimer;
  bool _controlsVisible = true;
  bool _completedHandled = false;
  double? _dragMs;
  TapDownDetails? _dtap;

  // basili tutunca hizli oynat
  bool _boost = false;
  double _rateBefore = 1.0;

  // parlaklik (sol) / ses (sag) kaydirma
  double _brightness = 0.5;
  double _volume = 0.5;
  int _vSide = 0; // 0 = parlaklik, 1 = ses
  double _vBase = 0;
  double _vDy = 0;
  int? _hudSide;
  double _hudValue = 0;
  Timer? _hudTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    player = Player(
      configuration: PlayerConfiguration(bufferSize: 64 * 1024 * 1024),
    );
    controller = VideoController(player);
    _initLevels();
    _init();
  }

  Future<void> _initLevels() async {
    try {
      _brightness = await ScreenBrightness.instance.application;
    } catch (_) {}
    try {
      VolumeController.instance.showSystemUI = false;
      _volume = await VolumeController.instance.getVolume();
    } catch (_) {}
  }

  Future<void> _init() async {
    final platform = player.platform;
    if (widget.cfg.allowInsecure && platform is NativePlayer) {
      await platform.setProperty('tls-verify', 'no');
    }
    final st = ProgressStore.instance.get(widget.item.key);
    final Duration? start = (!st.watched && st.pos > 5)
        ? Duration(milliseconds: (st.pos * 1000).round())
        : null;

    _subs.add(player.stream.completed.listen((c) {
      if (c) _onCompleted();
    }));
    _subs.add(player.stream.error.listen((e) {
      if (!mounted || e.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Oynatma hatasi: $e')),
      );
    }));

    await player.open(
      Media(
        widget.item.isLocal
            ? widget.item.uri.toFilePath()
            : widget.item.uri.toString(),
        httpHeaders: widget.cfg.authHeaders,
        start: start,
      ),
    );
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _save());
    _scheduleHide();
  }

  void _save() {
    if (_completedHandled) return;
    final d = player.state.duration.inMilliseconds / 1000.0;
    final p = player.state.position.inMilliseconds / 1000.0;
    if (d > 0 && p > 1) {
      ProgressStore.instance.update(widget.item.key, p, d);
    }
  }

  void _onCompleted() {
    if (_completedHandled) return;
    final d = player.state.duration.inMilliseconds / 1000.0;
    if (d > 0) {
      _completedHandled = true;
      ProgressStore.instance.update(widget.item.key, d, d, watched: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _save();
    }
  }

  @override
  void dispose() {
    _save();
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _hudTimer?.cancel();
    ScreenBrightness.instance.resetApplicationScreenBrightness().catchError((_) {});
    try {
      VolumeController.instance.showSystemUI = true;
    } catch (_) {}
    for (final s in _subs) {
      s.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(_allOrientations);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    player.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---- kontrol gorunurlugu
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && player.state.playing && _dragMs == null) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  // ---- eylemler
  void _seekBy(int sec) {
    final dur = player.state.duration;
    var t = player.state.position + Duration(seconds: sec);
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;
    player.seek(t);
    _showControls();
  }

  void _changeSpeed(int dir) {
    final cur = player.state.rate;
    final double next = dir > 0
        ? _speeds.firstWhere((s) => s > cur + 1e-6, orElse: () => _speeds.last)
        : _speeds.lastWhere((s) => s < cur - 1e-6, orElse: () => _speeds.first);
    player.setRate(next);
    _showControls();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      player.playOrPause();
    } else if (k == LogicalKeyboardKey.mediaPlay) {
      player.play();
    } else if (k == LogicalKeyboardKey.mediaPause) {
      player.pause();
    } else if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(shift ? -60 : -10);
    } else if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(shift ? 60 : 10);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _changeSpeed(1);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _changeSpeed(-1);
    } else if (k == LogicalKeyboardKey.bracketRight) {
      _changeSpeed(1);
    } else if (k == LogicalKeyboardKey.bracketLeft) {
      _changeSpeed(-1);
    } else if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    } else {
      return KeyEventResult.ignored;
    }
    _showControls();
    return KeyEventResult.handled;
  }

  void _onDoubleTap() {
    final d = _dtap;
    if (d == null) return;
    final w = MediaQuery.of(context).size.width;
    _seekBy(d.localPosition.dx < w / 2 ? -10 : 10);
  }

  // ---- basili tut: 2.5x
  void _startBoost() {
    if (_boost) return;
    _boost = true;
    _rateBefore = player.state.rate;
    player.setRate(_holdSpeed);
    setState(() {});
  }

  void _endBoost() {
    if (!_boost) return;
    _boost = false;
    player.setRate(_rateBefore);
    if (mounted) setState(() {});
  }

  // ---- dikey kaydirma: sol = parlaklik, sag = ses
  void _vStart(DragStartDetails d) {
    final w = MediaQuery.of(context).size.width;
    _vSide = d.localPosition.dx < w / 2 ? 0 : 1;
    _vBase = _vSide == 0 ? _brightness : _volume;
    _vDy = 0;
  }

  void _vUpdate(DragUpdateDetails d) {
    _vDy += d.delta.dy;
    final h = MediaQuery.of(context).size.height;
    final v = (_vBase - _vDy / (h * 0.7))
        .clamp(_vSide == 0 ? 0.02 : 0.0, 1.0)
        .toDouble();
    if (_vSide == 0) {
      _brightness = v;
      ScreenBrightness.instance
          .setApplicationScreenBrightness(v)
          .catchError((_) {});
    } else {
      _volume = v;
      VolumeController.instance.setVolume(v).catchError((_) {});
    }
    setState(() {
      _hudSide = _vSide;
      _hudValue = v;
    });
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hudSide = null);
    });
  }

  Widget _levelHud() {
    final side = _hudSide;
    if (side == null) return const SizedBox.shrink();
    final icon = side == 0
        ? Icons.brightness_6
        : (_hudValue <= 0.001 ? Icons.volume_off : Icons.volume_up);
    return Align(
      alignment: side == 0 ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(height: 8),
              SizedBox(
                height: 90,
                width: 6,
                child: RotatedBox(
                  quarterTurns: 3,
                  child: LinearProgressIndicator(
                    value: _hudValue,
                    color: Colors.orange,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text('${(_hudValue * 100).round()}',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _boostHud() {
    if (!_boost) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.fast_forward, color: Colors.white, size: 20),
                SizedBox(width: 6),
                Text('2.5x',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- arayuz
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _showControls(),
          cursor: _controlsVisible
              ? MouseCursor.defer
              : SystemMouseCursors.none,
          child: Stack(
            children: [
              Positioned.fill(
                child: Video(
                  controller: controller,
                  controls: NoVideoControls,
                  fit: BoxFit.contain,
                ),
              ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleControls,
                  onDoubleTapDown: (d) => _dtap = d,
                  onDoubleTap: _onDoubleTap,
                  onLongPressStart: (_) => _startBoost(),
                  onLongPressEnd: (_) => _endBoost(),
                  onLongPressCancel: _endBoost,
                  onVerticalDragStart: _vStart,
                  onVerticalDragUpdate: _vUpdate,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned.fill(child: IgnorePointer(child: _levelHud())),
              Positioned.fill(child: IgnorePointer(child: _boostHud())),
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: StreamBuilder<bool>(
                      stream: player.stream.buffering,
                      initialData: player.state.buffering,
                      builder: (_, s) => (s.data ?? false)
                          ? const CircularProgressIndicator()
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildControls(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Column(
      children: [
        // ust cubuk
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(
                    widget.item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        // alt cubuk
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 4),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [_seekRow()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _seekRow() {
    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      initialData: player.state.duration,
      builder: (_, ds) {
        final dur = ds.data ?? Duration.zero;
        final maxMs = dur.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (_, ps) {
            final pos = ps.data ?? Duration.zero;
            final hasDur = maxMs > 0;
            final value = (_dragMs ?? pos.inMilliseconds.toDouble())
                .clamp(0.0, hasDur ? maxMs : 1.0)
                .toDouble();
            final remaining = hasDur
                ? Duration(milliseconds: (maxMs - value).round())
                : Duration.zero;
            return Row(
              children: [
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  initialData: player.state.playing,
                  builder: (_, s) => IconButton(
                    iconSize: 26,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 36, height: 36),
                    color: Colors.white,
                    icon: Icon((s.data ?? false) ? Icons.pause : Icons.play_arrow),
                    onPressed: () {
                      player.playOrPause();
                      _showControls();
                    },
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 60,
                  child: Text(fmtDur(Duration(milliseconds: value.round())),
                      style: const TextStyle(color: Colors.white)),
                ),
                Expanded(
                  child: Slider(
                    value: value,
                    min: 0,
                    max: hasDur ? maxMs : 1.0,
                    onChangeStart: (_) => _hideTimer?.cancel(),
                    onChanged:
                        hasDur ? (v) => setState(() => _dragMs = v) : null,
                    onChangeEnd: (v) {
                      player.seek(Duration(milliseconds: v.round()));
                      setState(() => _dragMs = null);
                      _scheduleHide();
                    },
                  ),
                ),
                SizedBox(
                  width: 66,
                  child: Text(hasDur ? '-${fmtDur(remaining)}' : '--:--',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
