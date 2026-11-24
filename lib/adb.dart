import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
//  Minimal ADB istemcisi (ag uzerinden, TCP 5555)
//  Uzak cihazda "adb shell <komut>" calistirir. Harici adb binary'si gerekmez.
// ============================================================================

const _aCnxn = 0x4e584e43;
const _aAuth = 0x48545541;
const _aOpen = 0x4e45504f;
const _aOkay = 0x59414b4f;
const _aWrte = 0x45545257;
const _aClse = 0x45534c43;
const _aStls = 0x534c5453;

class AdbResult {
  final bool ok;
  final String message;
  const AdbResult(this.ok, this.message);
}

// ---- RSA anahtari (bir kez uretilir, kalici saklanir) ----------------------
class _Key {
  final BigInt n, e, d, p, q;
  _Key(this.n, this.e, this.d, this.p, this.q);

  List<String> toJson() =>
      [n, e, d, p, q].map((b) => b.toString()).toList(growable: false);

  factory _Key.fromJson(List<dynamic> l) => _Key(
        BigInt.parse(l[0] as String),
        BigInt.parse(l[1] as String),
        BigInt.parse(l[2] as String),
        BigInt.parse(l[3] as String),
        BigInt.parse(l[4] as String),
      );
}

List<String> _genKeyIsolate(int _) {
  final rnd = Random.secure();
  final seed = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
  final secure = pc.FortunaRandom()..seed(pc.KeyParameter(seed));
  final gen = pc.RSAKeyGenerator()
    ..init(pc.ParametersWithRandom(
      pc.RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
      secure,
    ));
  final pair = gen.generateKeyPair();
  final pub = pair.publicKey as pc.RSAPublicKey;
  final priv = pair.privateKey as pc.RSAPrivateKey;
  return [
    pub.modulus!.toString(),
    pub.exponent!.toString(),
    priv.privateExponent!.toString(),
    priv.p!.toString(),
    priv.q!.toString(),
  ];
}

Future<_Key> _loadKey() async {
  final p = await SharedPreferences.getInstance();
  final raw = p.getString('adb_key');
  if (raw != null) {
    try {
      return _Key.fromJson(jsonDecode(raw) as List);
    } catch (_) {}
  }
  final l = await compute(_genKeyIsolate, 0);
  final k = _Key.fromJson(l);
  await p.setString('adb_key', jsonEncode(k.toJson()));
  return k;
}

Uint8List _leBytes(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = 0; i < len; i++) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

/// Android'in bekledigi RSAPublicKey yapisi (2048 bit).
Uint8List _androidPubKey(_Key k) {
  final b = BytesBuilder();
  void u32(int v) =>
      b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  final two32 = BigInt.one << 32;
  final inv = (k.n % two32).modInverse(two32);
  final n0inv = ((two32 - inv) % two32).toInt();
  u32(64);
  u32(n0inv);
  b.add(_leBytes(k.n, 256));
  b.add(_leBytes((BigInt.one << 4096) % k.n, 256));
  u32(k.e.toInt());
  return b.toBytes();
}

/// ADB, 20 baytlik token'i hazir SHA-1 ozeti gibi PKCS#1 v1.5 ile imzalar.
Uint8List _signToken(_Key k, Uint8List token) {
  const prefix = [
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, //
    0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
  ];
  final input = Uint8List.fromList([...prefix, ...token]);
  final engine = pc.PKCS1Encoding(pc.RSAEngine())
    ..init(
      true,
      pc.PrivateKeyParameter<pc.RSAPrivateKey>(
          pc.RSAPrivateKey(k.n, k.d, k.p, k.q)),
    );
  return engine.process(input);
}

// ---- Protokol -------------------------------------------------------------
Uint8List _msg(int cmd, int a0, int a1, [Uint8List? data]) {
  data ??= Uint8List(0);
  var sum = 0;
  for (final x in data) {
    sum += x;
  }
  final h = ByteData(24)
    ..setUint32(0, cmd, Endian.little)
    ..setUint32(4, a0, Endian.little)
    ..setUint32(8, a1, Endian.little)
    ..setUint32(12, data.length, Endian.little)
    ..setUint32(16, sum & 0xffffffff, Endian.little)
    ..setUint32(20, (cmd ^ 0xffffffff) & 0xffffffff, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...data]);
}

class _Packet {
  final int cmd, arg0, arg1;
  final Uint8List data;
  _Packet(this.cmd, this.arg0, this.arg1, this.data);
}

class _Closed implements Exception {
  const _Closed();
}

class _Conn {
  final Socket sock;
  final List<int> _b = [];
  bool _closed = false;
  Completer<void>? _w;

  _Conn(this.sock) {
    sock.listen(
      (d) {
        _b.addAll(d);
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      onError: (_) {
        _closed = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  void _wake() {
    final w = _w;
    _w = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<Uint8List> _read(int n, Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (_b.length < n) {
      if (_closed) throw const _Closed();
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('adb');
      _w = Completer<void>();
      await _w!.future.timeout(left, onTimeout: () {});
    }
    final out = Uint8List.fromList(_b.sublist(0, n));
    _b.removeRange(0, n);
    return out;
  }

  Future<_Packet> readPacket(Duration timeout) async {
    final h = await _read(24, timeout);
    final bd = ByteData.sublistView(h);
    final len = bd.getUint32(12, Endian.little);
    final data = len > 0 ? await _read(len, timeout) : Uint8List(0);
    return _Packet(
      bd.getUint32(0, Endian.little),
      bd.getUint32(4, Endian.little),
      bd.getUint32(8, Endian.little),
      data,
    );
  }

  void send(Uint8List m) => sock.add(m);

  Future<void> close() async {
    try {
      await sock.close();
    } catch (_) {}
    sock.destroy();
  }
}

/// [host]:[port] adresindeki cihazda `shell:<command>` calistirir.
Future<AdbResult> adbShell(
  String host,
  int port,
  String command, {
  Duration authWait = const Duration(seconds: 45),
}) async {
  _Conn? c;
  try {
    final key = await _loadKey();
    final sock = await Socket.connect(host, port,
        timeout: const Duration(seconds: 6));
    sock.setOption(SocketOption.tcpNoDelay, true);
    c = _Conn(sock);

    c.send(_msg(_aCnxn, 0x01000000, 256 * 1024,
        Uint8List.fromList(utf8.encode('host::\u0000'))));

    var signed = false;
    var keySent = false;
    var connected = false;
    while (!connected) {
      final p = await c.readPacket(
          keySent ? authWait : const Duration(seconds: 10));
      if (p.cmd == _aCnxn) {
        connected = true;
      } else if (p.cmd == _aAuth && p.arg0 == 1) {
        if (!signed) {
          signed = true;
          c.send(_msg(_aAuth, 2, 0, _signToken(key, p.data)));
        } else if (!keySent) {
          keySent = true;
          final pub = '${base64Encode(_androidPubKey(key))} webdavplayer@android\u0000';
          c.send(_msg(_aAuth, 3, 0, Uint8List.fromList(utf8.encode(pub))));
        } else {
          return const AdbResult(false, 'TV izni reddetti.');
        }
      } else if (p.cmd == _aStls) {
        return const AdbResult(false,
            'Cihaz TLS (kablosuz hata ayıklama) istiyor. Klasik "ADB ağ hata ayıklama" (5555) açık olmalı.');
      }
    }

    c.send(_msg(_aOpen, 1, 0,
        Uint8List.fromList(utf8.encode('shell:$command\u0000'))));

    // Cihaz kapanirken baglanti kopar; bu da basari sayilir.
    try {
      while (true) {
        final p = await c.readPacket(const Duration(seconds: 6));
        if (p.cmd == _aOkay) {
          return const AdbResult(true, 'Kapatma komutu gönderildi.');
        }
        if (p.cmd == _aWrte) {
          c.send(_msg(_aOkay, 1, p.arg0));
        }
        if (p.cmd == _aClse) {
          return const AdbResult(true, 'Kapatma komutu gönderildi.');
        }
      }
    } on _Closed {
      return const AdbResult(true, 'Kapatma komutu gönderildi.');
    }
  } on TimeoutException {
    return const AdbResult(false,
        'Zaman aşımı. TV ekranındaki "USB hata ayıklamaya izin ver" sorusunu onayladın mı?');
  } on _Closed {
    return const AdbResult(false, 'Bağlantı TV tarafından kapatıldı.');
  } on SocketException catch (e) {
    return AdbResult(false,
        'TV\'ye bağlanılamadı ($host:$port). ADB ağ hata ayıklaması açık mı? ${e.message}');
  } catch (e) {
    return AdbResult(false, 'Hata: $e');
  } finally {
    await c?.close();
  }
}
