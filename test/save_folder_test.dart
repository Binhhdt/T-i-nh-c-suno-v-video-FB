import 'dart:io';

import 'package:fb_video_downloader/save_folder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dùng thư mục đã chọn khi còn tồn tại', () {
    final tmp = Directory.systemTemp.createTempSync('save_folder_test_');
    try {
      final resolved = resolveSaveDir(
        customPath: tmp.path,
        downloadsDir: Directory('/downloads'),
      );
      expect(resolved.dir.path, tmp.path);
      expect(resolved.usedFallback, isFalse);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('fallback về Downloads khi thư mục đã chọn bị xoá', () {
    final resolved = resolveSaveDir(
      customPath: '/khong/ton/tai/thu/muc/nay',
      downloadsDir: Directory('/downloads'),
    );
    expect(resolved.dir.path, '/downloads');
    expect(resolved.usedFallback, isTrue);
  });

  test('chưa chọn thư mục thì dùng Downloads, không tính là fallback', () {
    final resolved = resolveSaveDir(
      customPath: null,
      downloadsDir: Directory('/downloads'),
    );
    expect(resolved.dir.path, '/downloads');
    expect(resolved.usedFallback, isFalse);
  });

  test('label hiển thị đúng', () {
    expect(SaveFolder.label(null), SaveFolder.defaultLabel);
    expect(SaveFolder.label('/storage/Download/Phim'), '/storage/Download/Phim');
  });

  group('resolveSaveDirChain (dùng chung 2 tab)', () {
    test('thư mục đã chọn ghi được -> dùng nó', () {
      final tmp = Directory.systemTemp.createTempSync('chain_custom_');
      try {
        final r = resolveSaveDirChain(
          customPath: tmp.path,
          publicDownloadsDir: Directory('/downloads'),
          appPrivateDir: Directory('/private'),
        );
        expect(r.dir.path, tmp.path);
        expect(r.usedFallback, isFalse);
        expect(r.usedPrivateFallback, isFalse);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('thư mục đã chọn không ghi được -> Downloads công khai', () {
      final tmp = Directory.systemTemp.createTempSync('chain_dl_');
      try {
        final r = resolveSaveDirChain(
          customPath: '/khong/ton/tai/thu/muc/nay',
          publicDownloadsDir: tmp,
          appPrivateDir: Directory('/private'),
        );
        expect(r.dir.path, tmp.path);
        expect(r.usedFallback, isTrue);
        expect(r.usedPrivateFallback, isFalse);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('không ghi được đâu cả -> thư mục riêng của app + cờ báo rõ', () {
      final r = resolveSaveDirChain(
        customPath: '/khong/ton/tai/thu/muc/nay',
        publicDownloadsDir: Directory('/cung/khong/ton/tai'),
        appPrivateDir: Directory('/private'),
        writable: (_) => false,
      );
      expect(r.dir.path, '/private');
      expect(r.usedPrivateFallback, isTrue);
    });

    test('chưa chọn thư mục, Downloads ghi được -> dùng Downloads', () {
      final tmp = Directory.systemTemp.createTempSync('chain_dl2_');
      try {
        final r = resolveSaveDirChain(
          customPath: null,
          publicDownloadsDir: tmp,
          appPrivateDir: Directory('/private'),
        );
        expect(r.dir.path, tmp.path);
        expect(r.usedFallback, isFalse);
        expect(r.usedPrivateFallback, isFalse);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  test('canWriteToSync: ghi được thư mục thật', () {
    final tmp = Directory.systemTemp.createTempSync('can_write_');
    try {
      expect(canWriteToSync(tmp.path), isTrue);
      expect(canWriteToSync('/khong/ton/tai/thu/muc/nay/xyz'), isFalse);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
