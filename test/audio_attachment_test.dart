import 'package:costr/models/event.dart';
import 'package:costr/services/link_preview.dart';
import 'package:costr/widgets/network_audio.dart';
import 'package:flutter_test/flutter_test.dart';

Event _ev(List<List<dynamic>> tags, {String content = ''}) => Event(
      id: 'i',
      pubkey: 'p',
      createdAt: 0,
      kind: 1,
      tags: tags,
      content: content,
      sig: '',
    );

void main() {
  group('MediaAttachment.isAudio', () {
    test('audio mime wins over the URL extension', () {
      expect(
        const MediaAttachment(url: 'https://x/a', mimeType: 'audio/mpeg')
            .isAudio,
        isTrue,
      );
      expect(
        const MediaAttachment(url: 'https://x/a.mp4', mimeType: 'audio/ogg')
            .isAudio,
        isTrue,
      );
      // An audio attachment is never also image/video.
      const a = MediaAttachment(url: 'https://x/a', mimeType: 'audio/mpeg');
      expect(a.isVideo, isFalse);
      expect(a.isImage, isFalse);
    });

    test('video/image mime beats an audio-looking extension', () {
      expect(
        const MediaAttachment(url: 'https://x/a.mp3', mimeType: 'video/mp4')
            .isAudio,
        isFalse,
      );
      expect(
        const MediaAttachment(url: 'https://x/a.mp3', mimeType: 'image/png')
            .isAudio,
        isFalse,
      );
    });

    test('extension fallback when the mime is absent', () {
      for (final ext in const [
        '.mp3',
        '.m4a',
        '.aac',
        '.wav',
        '.ogg',
        '.oga',
        '.opus',
        '.flac',
      ]) {
        expect(
          MediaAttachment(url: 'https://x/a$ext').isAudio,
          isTrue,
          reason: ext,
        );
      }
      expect(MediaAttachment(url: 'https://x/a.mp4').isAudio, isFalse);
      expect(MediaAttachment(url: 'https://x/a.jpg').isAudio, isFalse);
    });

    test('query/fragment stripped before the extension check', () {
      expect(
        MediaAttachment(url: 'https://x/a.mp3?sign=1&t=2').isAudio,
        isTrue,
      );
      expect(MediaAttachment(url: 'https://x/a.m4a#t=3').isAudio, isTrue);
    });
  });

  group('imeta / audio tag parsing', () {
    test('imeta audio attachment with a waveform field', () {
      final ev = _ev([
        ['imeta', 'url https://x/v.mp3', 'm audio/mpeg', 'waveform 3 9 4 1'],
      ]);
      final att = ev.mediaAttachments.single;
      expect(att.isAudio, isTrue);
      expect(att.waveform, [3.0, 9.0, 4.0, 1.0]);
    });

    test('imeta waveform skips unparsable tokens', () {
      final ev = _ev([
        ['imeta', 'url https://x/v.mp3', 'm audio/mpeg', 'waveform 3 x 4'],
      ]);
      expect(ev.mediaAttachments.single.waveform, [3.0, 4.0]);
    });

    test('imeta waveform with no samples → null (synthetic fallback)', () {
      final ev = _ev([
        ['imeta', 'url https://x/v.mp3', 'm audio/mpeg', 'waveform '],
      ]);
      expect(ev.mediaAttachments.single.waveform, isNull);
    });

    test('imeta without waveform keeps waveform null', () {
      final ev = _ev([
        ['imeta', 'url https://x/v.mp3', 'm audio/mpeg'],
      ]);
      expect(ev.mediaAttachments.single.waveform, isNull);
    });

    test('["audio", url, mime] tag becomes an audio attachment', () {
      final ev = _ev([
        ['audio', 'https://x/a', 'audio/mp4'],
      ]);
      final att = ev.mediaAttachments.single;
      expect(att.isAudio, isTrue);
      expect(att.mimeType, 'audio/mp4');
    });
  });

  group('parseWaveform', () {
    test('parses space separated numbers', () {
      expect(parseWaveform('1 2.5 3'), [1.0, 2.5, 3.0]);
    });
    test('all-junk and empty input → null', () {
      expect(parseWaveform('a b'), isNull);
      expect(parseWaveform(''), isNull);
    });
  });

  group('syntheticWaveform', () {
    test('deterministic per seed (stable across rebuilds)', () {
      expect(
        syntheticWaveform('https://x/a.mp3'),
        syntheticWaveform('https://x/a.mp3'),
      );
    });

    test('different seeds produce different shapes', () {
      expect(
        syntheticWaveform('https://x/a.mp3'),
        isNot(syntheticWaveform('https://x/b.mp3')),
      );
    });

    test('bar count and amplitude range', () {
      final w = syntheticWaveform('seed');
      expect(w.length, kAudioWaveformBars);
      for (final v in w) {
        expect(v, inInclusiveRange(0.05, 1.0));
      }
    });
  });

  group('link preview audio classification', () {
    test('audio/* content types classify as audio', () {
      expect(classifyContentType('audio/mpeg'), UrlContentKind.audio);
      expect(classifyContentType('audio/ogg; codecs=opus'), UrlContentKind.audio);
      // Neighbours keep their classes.
      expect(classifyContentType('video/mp4'), UrlContentKind.video);
      expect(classifyContentType('image/jpeg'), UrlContentKind.image);
      expect(classifyContentType(null), UrlContentKind.other);
    });

    test('bare audio URLs are never preview-probe candidates', () {
      expect(
        extractPreviewCandidates(
          'a https://x/f.m4a b https://x/g.flac c https://x/h.opus',
        ),
        isEmpty,
      );
    });
  });
}
