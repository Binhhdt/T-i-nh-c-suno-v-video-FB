import 'package:fb_video_downloader/audio_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('convertedFileName: đổi đuôi + bỏ hậu tố _source', () {
    expect(convertedFileName('suno_123_source.m4a', 'mp3'), 'suno_123.mp3');
    expect(convertedFileName('suno_123_source.mp3', 'wav'), 'suno_123.wav');
    expect(convertedFileName('suno_123.m4a', 'mp3'), 'suno_123.mp3');
  });

  test('needsConversion: chỉ khác đuôi mới cần convert', () {
    expect(needsConversion('m4a', 'mp3'), isTrue);
    expect(needsConversion('m4a', 'wav'), isTrue);
    expect(needsConversion('mp3', 'mp3'), isFalse);
    expect(needsConversion('wav', 'wav'), isFalse);
    expect(needsConversion('MP3', 'mp3'), isFalse);
  });

  test('ConvertResult: mang theo mã lỗi + log ffmpeg để UI hiện lỗi thật', () {
    const r = ConvertResult(
      ok: false,
      returnCode: 1,
      errorOutput: 'moov atom not found',
    );
    expect(r.ok, isFalse);
    expect(r.returnCode, 1);
    expect(r.errorOutput, contains('moov atom not found'));
  });
}
