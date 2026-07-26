/// Pure-Dart Bech32 (BIP-173) implementation.
///
/// Used for NIP-19 entity encoding (nsec1/npub1/note1). NIP-19 uses plain
/// bech32 (NOT bech32m). This is encoding only — no cryptography. Hand-rolled
/// because the `bech32` pub package targets Dart <3.0.0 and is incompatible
/// with our SDK (3.12).
library;

/// Bech32 character set (BIP-173).
const String _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

/// Generator constants for checksum calculation.
const List<int> _gen = [
  0x3b6a57b2,
  0x26508e6d,
  0x1ea119fa,
  0x3d4233dd,
  0x2a1462b3,
];

class Bech32Exception implements Exception {
  Bech32Exception(this.message);
  final String message;
  @override
  String toString() => 'Bech32Exception: $message';
}

/// Internal: polymod over the bech32 generator polynomial.
int _polymod(List<int> values) {
  int chk = 1;
  for (final v in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (int i = 0; i < 5; i++) {
      if (((top >> i) & 1) != 0) {
        chk ^= _gen[i];
      }
    }
  }
  return chk;
}

/// Internal: expand the human-readable part for checksum input.
List<int> _hrpExpand(String hrp) {
  final out = <int>[];
  for (final c in hrp.codeUnits) {
    out.add(c >> 5);
  }
  out.add(0);
  for (final c in hrp.codeUnits) {
    out.add(c & 31);
  }
  return out;
}

List<int> _createChecksum(String hrp, List<int> data5) {
  final values = <int>[
    ..._hrpExpand(hrp),
    ...data5,
    0,
    0,
    0,
    0,
    0,
    0,
  ];
  final mod = _polymod(values) ^ 1;
  return [
    for (int i = 0; i < 6; i++) (mod >> (5 * (5 - i))) & 31,
  ];
}

bool _verifyChecksum(String hrp, List<int> data5, List<int> checksum) {
  return _polymod(<int>[..._hrpExpand(hrp), ...data5, ...checksum]) == 1;
}

/// Convert between bit group sizes (BIP-173 convertbits).
///
/// [fromBits] → [toBits]. [pad] true to zero-pad the final group (used for
/// 8→5 on encode); false to reject non-zero padding (used for 5→8 on decode,
/// where the original data was a whole number of bytes).
List<int> _convertBits(
  List<int> data,
  int fromBits,
  int toBits,
  bool pad,
) {
  int acc = 0;
  int bits = 0;
  final out = <int>[];
  final maxv = (1 << toBits) - 1;
  for (final v in data) {
    if (v < 0 || (v >> fromBits) != 0) {
      throw Bech32Exception('invalid value $v for $fromBits-bit group');
    }
    acc = (acc << fromBits) | v;
    bits += fromBits;
    while (bits >= toBits) {
      bits -= toBits;
      out.add((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits != 0) {
      out.add((acc << (toBits - bits)) & maxv);
    }
  } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0) {
    throw Bech32Exception('non-zero padding');
  }
  return out;
}

/// Decoded bech32 result: human-readable part + raw 8-bit payload bytes.
class Bech32Decoded {
  const Bech32Decoded(this.hrp, this.data);
  final String hrp;
  final List<int> data;
  @override
  String toString() => 'Bech32Decoded(hrp: $hrp, data length: ${data.length})';
}

/// Encode [data] (raw bytes) with human-readable part [hrp] using bech32.
///
/// Returns the lowercase bech32 string: `<hrp>1<data><checksum>`.
String encodeBech32(String hrp, List<int> data) {
  if (hrp.isEmpty) {
    throw Bech32Exception('hrp must not be empty');
  }
  for (final c in hrp.codeUnits) {
    if (c < 33 || c > 126) {
      throw Bech32Exception('invalid hrp character');
    }
  }
  final data5 = _convertBits(data, 8, 5, true);
  final checksum = _createChecksum(hrp, data5);
  final chars = [
    ...data5,
    ...checksum,
  ].map((i) => _charset.codeUnitAt(i));
  return "${hrp}1${String.fromCharCodes(chars)}";
}

/// Decode a bech32 string into its hrp and raw payload bytes.
///
/// Accepts all-lower or all-upper case; mixed case is rejected. Verifies the
/// checksum and throws [Bech32Exception] on any malformation.
Bech32Decoded decodeBech32(String input) {
  final hasUpper = input.contains(RegExp(r'[A-Z]'));
  final hasLower = input.contains(RegExp(r'[a-z]'));
  if (hasUpper && hasLower) {
    throw Bech32Exception('mixed-case string');
  }
  final s = input.toLowerCase();
  final pos = s.lastIndexOf('1');
  if (pos < 1 || pos + 7 > s.length) {
    throw Bech32Exception('invalid separator position');
  }
  final hrp = s.substring(0, pos);
  for (final c in hrp.codeUnits) {
    if (c < 33 || c > 126) {
      throw Bech32Exception('invalid hrp character: $c');
    }
  }
  final dataPart = s.substring(pos + 1);
  final data5 = <int>[];
  for (final c in dataPart.codeUnits) {
    final idx = _charset.indexOf(String.fromCharCode(c));
    if (idx < 0) {
      throw Bech32Exception('invalid character in data part');
    }
    data5.add(idx);
  }
  if (data5.length < 6) {
    throw Bech32Exception('data too short');
  }
  final checksum = data5.sublist(data5.length - 6);
  final payload = data5.sublist(0, data5.length - 6);
  if (!_verifyChecksum(hrp, payload, checksum)) {
    throw Bech32Exception('invalid checksum');
  }
  return Bech32Decoded(hrp, _convertBits(payload, 5, 8, false));
}
