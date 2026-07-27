/// NIP-44 v2 encryption (for private bookmarks in NIP-51 kind-10003, and
/// future DMs). Pure-Dart implementation using pointycastle (secp256k1 ECDH,
/// ChaCha20 RFC 7539, HKDF) + crypto (HMAC-SHA256).
///
/// Algorithm (https://github.com/nostr-protocol/nips/blob/master/44.md):
///   shared_x  = x of (priv * lift_x(recipient_pub))  [secp256k1 ECDH]
///   conv_key = HKDF-Extract(salt="nip44-v2", ikm=shared_x)
///   nonce    = 32 random bytes
///   expanded = HKDF-Expand(conv_key, info=nonce, L=76)
///     -> chacha_key(32) | chacha_nonce(12) | mac_key(32)
///   ciphertext = ChaCha20(chacha_key, chacha_nonce, pad(plaintext))
///   mac = HMAC-SHA256(mac_key, nonce || ciphertext)
///   payload = base64( 0x02 || nonce || ciphertext || mac )
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:hex/hex.dart';
import 'package:pointycastle/export.dart' as pc;

const int _version = 0x02;
final Uint8List _hkdfSalt = Uint8List.fromList(utf8.encode('nip44-v2'));

/// Encrypt [plaintext] for [recipientPubkeyHex] using [privkeyHex]. Returns
/// the base64 payload string.
String nip44Encrypt(String privkeyHex, String recipientPubkeyHex, String plaintext) {
  final convKey = _conversationKey(privkeyHex, recipientPubkeyHex);
  final nonce = _randomBytes(32);
  final expanded = _hkdfExpand(convKey, nonce, 76);
  final chachaKey = Uint8List.fromList(expanded.sublist(0, 32));
  final chachaNonce = Uint8List.fromList(expanded.sublist(32, 44));
  final macKey = Uint8List.fromList(expanded.sublist(44, 76));
  final padded = _pad(plaintext);
  final ciphertext = _chacha20(chachaKey, chachaNonce, padded);
  final mac = _hmac(macKey, Uint8List.fromList([...nonce, ...ciphertext]));
  final payload = <int>[_version, ...nonce, ...ciphertext, ...mac];
  return base64.encode(payload);
}

/// Decrypt a base64 NIP-44 payload sent by [senderPubkeyHex] using [privkeyHex].
String nip44Decrypt(String privkeyHex, String senderPubkeyHex, String payloadBase64) {
  final bytes = base64.decode(payloadBase64);
  if (bytes.isEmpty || bytes[0] != _version) {
    throw FormatException('unsupported nip44 version');
  }
  final nonce = Uint8List.fromList(bytes.sublist(1, 33));
  final mac = Uint8List.fromList(bytes.sublist(bytes.length - 32));
  final ciphertext = Uint8List.fromList(bytes.sublist(33, bytes.length - 32));
  final convKey = _conversationKey(privkeyHex, senderPubkeyHex);
  final expanded = _hkdfExpand(convKey, nonce, 76);
  final chachaKey = Uint8List.fromList(expanded.sublist(0, 32));
  final chachaNonce = Uint8List.fromList(expanded.sublist(32, 44));
  final macKey = Uint8List.fromList(expanded.sublist(44, 76));
  final expectedMac = _hmac(macKey, Uint8List.fromList([...nonce, ...ciphertext]));
  if (!_constEq(expectedMac, mac)) {
    throw FormatException('nip44 mac mismatch');
  }
  final padded = _chacha20(chachaKey, chachaNonce, ciphertext);
  return _unpad(padded);
}

Uint8List _conversationKey(String privkeyHex, String pubkeyHex) {
  final sharedX = _ecdhSharedX(privkeyHex, pubkeyHex);
  return _hkdfExtract(_hkdfSalt, sharedX);
}

Uint8List _ecdhSharedX(String privkeyHex, String pubkeyHex) {
  final domain = pc.ECDomainParameters('secp256k1');
  final priv = BigInt.parse(privkeyHex, radix: 16);
  // Recipient pubkey is x-only; lift via compressed (02 || x). The shared x is
  // the same regardless of y parity, so the even-y lift is fine.
  final pubBytes = Uint8List.fromList(
      <int>[0x02, ...HEX.decode(pubkeyHex)]);
  final pubPoint = domain.curve.decodePoint(pubBytes)!;
  final shared = (pubPoint * priv)!;
  final xBytes = _bigIntToBytes(shared.x!.toBigInteger()!, 32);
  return xBytes;
}

Uint8List _hkdfExtract(Uint8List salt, Uint8List ikm) {
  final hmac = crypto.Hmac(crypto.sha256, salt);
  return Uint8List.fromList(hmac.convert(ikm).bytes);
}

Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
  final out = <int>[];
  var counter = 1;
  var prev = <int>[];
  while (out.length < length) {
    final hmac = crypto.Hmac(crypto.sha256, prk);
    final input = <int>[...prev, ...info, counter];
    prev = hmac.convert(input).bytes;
    out.addAll(prev);
    counter++;
  }
  return Uint8List.fromList(out.sublist(0, length));
}

Uint8List _hmac(Uint8List key, Uint8List data) {
  final hmac = crypto.Hmac(crypto.sha256, key);
  return Uint8List.fromList(hmac.convert(data).bytes);
}

Uint8List _chacha20(Uint8List key, Uint8List nonce12, Uint8List data) {
  final cipher = pc.ChaCha7539Engine();
  cipher.init(true, pc.ParametersWithIV<pc.KeyParameter>(
      pc.KeyParameter(key), nonce12));
  return cipher.process(data);
}

Uint8List _pad(String plaintext) {
  final msg = utf8.encode(plaintext);
  final prefix = msg.length < 65536
      ? _u16(msg.length)
      : <int>[0, 0, ..._u32(msg.length)];
  final unpadded = <int>[...prefix, ...msg];
  final paddedLen = _calcPaddedLen(unpadded.length);
  final zeros = List<int>.filled(paddedLen - unpadded.length, 0);
  return Uint8List.fromList(<int>[...unpadded, ...zeros]);
}

String _unpad(Uint8List padded) {
  if (padded.isEmpty) throw FormatException('empty padded');
  final prefixLen = padded[0] == 0 && padded[1] == 0 ? 6 : 2;
  final len = prefixLen == 2
      ? (padded[0] << 8) | padded[1]
      : (padded[2] << 24) | (padded[3] << 16) | (padded[4] << 8) | padded[5];
  if (prefixLen + len > padded.length) {
    throw FormatException('bad padding length');
  }
  return utf8.decode(padded.sublist(prefixLen, prefixLen + len));
}

List<int> _u16(int n) => [(n >> 8) & 0xff, n & 0xff];
List<int> _u32(int n) => [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];

int _calcPaddedLen(int unpadded) {
  if (unpadded <= 32) return 32;
  var next = 1;
  while (next < unpadded) {
    next <<= 1;
  }
  if (next > 65536) next = 65536;
  return next;
}

Uint8List _bigIntToBytes(BigInt value, int length) {
  final bytes = <int>[];
  var v = value;
  while (v > BigInt.zero) {
    bytes.insert(0, (v & BigInt.from(0xff)).toInt());
    v = v >> 8;
  }
  while (bytes.length < length) {
    bytes.insert(0, 0);
  }
  return Uint8List.fromList(bytes.sublist(0, length));
}

bool _constEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}
