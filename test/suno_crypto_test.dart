import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fb_video_downloader/suno_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Vector test tự tạo bằng Node (crypto chuẩn) — cùng scheme Suno dùng:
// glt = 'test-glt-token', clipId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
// key đã gói -> 0f1e2d3c4b5a69788796a5b4c3d2e1f0,
// iv đã gói  -> f0e1d2c3b4a5968778695a4b3c2d1e0f,
// ciphertext CTR -> 'Hello Suno CTR test! 1234567890 ABCDEFGHIJKLMNOPQRSTUVWXYZ'.
const _clipId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const _glt = 'test-glt-token';
const _wrappedKey =
    'AQIDBAUGBwgJCgsMnl34hmkO9LDf9TcO8PzTHQnSQ6UkSxzobqciW+B4EQs=';
const _wrappedIv =
    'CgsMDQ4PEBESExQVyX0Uy7z+SWC4A6Z0qpjRimnO6GSCJ77T/7TJWSZkP8I=';
const _ctrCiphertextB64 =
    'lOlqeMKSM64NDGzVXdeqfDYadSWuZMFjVs8Sh1rdszK52ekFmWeix0DXX0YY7CMUD5zIFO1yduTz5g==';
const _ctrPlaintext =
    'Hello Suno CTR test! 1234567890 ABCDEFGHIJKLMNOPQRSTUVWXYZ';

void main() {
  test('userKeyFromGlt: SHA-256 của glt', () {
    final key = userKeyFromGlt(_glt);
    expect(key.length, 32);
    // SHA-256('test-glt-token') — kiểm chứng bằng Node crypto.
    expect(
      key,
      Uint8List.fromList([
        0xab, 0x47, 0x44, 0x61, 0xf7, 0xa2, 0x63, 0xa4, 0x04, 0xc3, 0x91,
        0x24, 0xf3, 0xb0, 0xdb, 0xfd, 0x0b, 0x29, 0xe3, 0x8a, 0xaa, 0x77,
        0x61, 0x02, 0x4f, 0x55, 0x4c, 0x47, 0xf6, 0x7e, 0xe7, 0xfd,
      ]),
    );
  });

  test('unwrapKey: gỡ gói AES-256-GCM ra key 16 byte', () {
    final userKey = userKeyFromGlt(_glt);
    final key = unwrapKey(_wrappedKey, _clipId, userKey);
    expect(
      key,
      Uint8List.fromList([
        0x0f, 0x1e, 0x2d, 0x3c, 0x4b, 0x5a, 0x69, 0x78, 0x87, 0x96, 0xa5,
        0xb4, 0xc3, 0xd2, 0xe1, 0xf0,
      ]),
    );
    final iv = unwrapKey(_wrappedIv, _clipId, userKey);
    expect(
      iv,
      Uint8List.fromList([
        0xf0, 0xe1, 0xd2, 0xc3, 0xb4, 0xa5, 0x96, 0x87, 0x78, 0x69, 0x5a,
        0x4b, 0x3c, 0x2d, 0x1e, 0x0f,
      ]),
    );
  });

  test('unwrapKey: AAD sai (clip id khác) thì throw', () {
    final userKey = userKeyFromGlt(_glt);
    expect(
      () => unwrapKey(_wrappedKey, 'clip-id-khac', userKey),
      throwsA(isA<SunoCryptoException>()),
    );
  });

  test('decryptAudioFile: giải mã AES-128-CTR đúng plaintext', () async {
    final tmp = await Directory.systemTemp.createTemp('suno_crypto_test_');
    try {
      final encPath = '${tmp.path}/enc.bin';
      final decPath = '${tmp.path}/dec.bin';
      await File(encPath).writeAsBytes(base64Decode(_ctrCiphertextB64));
      await decryptAudioFile(
        inputPath: encPath,
        outputPath: decPath,
        clipId: _clipId,
        rights: const SunoRights(
          key: _wrappedKey,
          iv: _wrappedIv,
          glt: _glt,
        ),
      );
      final plain = await File(decPath).readAsString();
      expect(plain, _ctrPlaintext);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('isPlayableMediaHeader: nhận diện media thường, từ chối file mã hoá', () {
    // MP4: ftyp ở offset 4.
    expect(
      isPlayableMediaHeader([0, 0, 0, 0x1c, 0x66, 0x74, 0x79, 0x70]),
      isTrue,
    );
    // MP3 ID3.
    expect(isPlayableMediaHeader([0x49, 0x44, 0x33, 0x04]), isTrue);
    // WAV RIFF.
    expect(isPlayableMediaHeader([0x52, 0x49, 0x46, 0x46]), isTrue);
    // File Suno đã mã hoá: bytes ngẫu nhiên, không magic nào.
    expect(
      isPlayableMediaHeader([0x29, 0xdc, 0x0a, 0xed, 0x47, 0x11, 0xe1, 0x76]),
      isFalse,
    );
  });
}
