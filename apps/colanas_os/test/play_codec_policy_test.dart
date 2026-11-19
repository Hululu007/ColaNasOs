import 'package:colanas_os/core/codec_support.dart';
import 'package:colanas_os/core/play_preferences.dart';
import 'package:colanas_os/core/play_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('user-selectable playback strategies exclude internal H.264', () {
    expect(
      playCodecs.where((codec) => codec.selectable).map((codec) => codec.key),
      ['original', 'h265', 'av1'],
    );
    expect(playableCodecs().map((codec) => codec.key), [
      'original',
      'h265',
      'av1',
    ]);
    expect(playCodecOf('h264')!.transcode, isTrue);
    expect(playCodecOf('h264')!.selectable, isFalse);
  });

  test('transcode codec selection does not include original playback', () {
    expect(playableTranscodeCodecs().map((codec) => codec.key), [
      'h265',
      'av1',
    ]);
    expect(defaultTranscodeCodec(), 'h265');
  });

  test('legacy normalization false migrates to inherit, not forced off', () {
    expect(
      PlayPreferences.audioNormalizeModeFrom(null),
      AudioNormalizeMode.inherit,
    );
    expect(
      PlayPreferences.audioNormalizeModeFrom(false),
      AudioNormalizeMode.inherit,
    );
    expect(
      PlayPreferences.audioNormalizeModeFrom(true),
      AudioNormalizeMode.enabled,
    );
    expect(
      PlayPreferences.audioNormalizeModeFrom('disabled'),
      AudioNormalizeMode.disabled,
    );
  });
}
