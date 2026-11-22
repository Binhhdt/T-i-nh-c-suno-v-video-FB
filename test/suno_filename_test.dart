import 'package:fb_video_downloader/suno_filename.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeSongTitle', () {
    test('giữ nguyên tiêu đề tiếng Việt bình thường', () {
      expect(sanitizeSongTitle('Tình khúc ngày cũ'), 'Tình khúc ngày cũ');
    });

    test('bỏ ký tự cấm / \\ : * ? " < > |', () {
      expect(
        sanitizeSongTitle('Bài: hát / hay * nhất? "2026"'),
        'Bài hát hay nhất 2026',
      );
    });

    test('trim dấu chấm + khoảng trắng ở 2 đầu, gộp khoảng trắng lặp', () {
      expect(
        sanitizeSongTitle('...  Mưa   trên   phố  ...'),
        'Mưa trên phố',
      );
    });

    test('giới hạn ~100 ký tự', () {
      final long = 'A' * 150;
      final out = sanitizeSongTitle(long);
      expect(out.length, lessThanOrEqualTo(100));
      expect(out, 'A' * 100);
    });

    test('chỉ còn ký tự cấm -> rỗng (caller fallback timestamp)', () {
      expect(sanitizeSongTitle('///...:::'), isEmpty);
      expect(sanitizeSongTitle(''), isEmpty);
    });
  });

  group('uniqueFileName', () {
    test('không trùng -> giữ nguyên', () {
      expect(
        uniqueFileName('/dl', 'Tình khúc ngày cũ.wav',
            exists: (_) => false),
        'Tình khúc ngày cũ.wav',
      );
    });

    test('trùng -> thêm (1), (2)... trước đuôi', () {
      final existing = {
        '/dl/Tình khúc ngày cũ.wav',
        '/dl/Tình khúc ngày cũ (1).wav',
      };
      expect(
        uniqueFileName('/dl', 'Tình khúc ngày cũ.wav',
            exists: (p) => existing.contains(p)),
        'Tình khúc ngày cũ (2).wav',
      );
    });

    test('file không đuôi vẫn đánh số đúng', () {
      expect(
        uniqueFileName('/dl', 'video', exists: (p) => p == '/dl/video'),
        'video (1)',
      );
    });
  });
}
