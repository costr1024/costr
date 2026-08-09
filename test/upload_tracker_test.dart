// Unit tests for UploadTracker — the compose page's in-flight upload state
// machine. Covers the two bugs it replaced: the stuck `_uploading` flag
// (send button permanently dead) and the silently-ignored send tap during an
// upload ("发送偶尔没反应，要再点一下才好" — _send now awaits `idle`).

import 'package:costr/features/compose/compose_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UploadTracker', () {
    test('starts idle with no failure and no idle completer', () {
      final t = UploadTracker();
      expect(t.uploading, isFalse);
      expect(t.failed, isFalse);
      expect(t.idle, isNull);
    });

    test('started() marks uploading and exposes an unfinished completer', () {
      final t = UploadTracker();
      t.started();
      expect(t.uploading, isTrue);
      expect(t.idle, isNotNull);
      expect(t.idle!.isCompleted, isFalse);
    });

    test('finished() drops back to idle and completes the completer', () async {
      final t = UploadTracker();
      t.started();
      final idle = t.idle!;
      t.finished();
      expect(t.uploading, isFalse);
      expect(t.idle, isNull); // a new round gets a fresh completer
      await idle.future; // must complete — _send awaits exactly this
    });

    test('overlapping uploads: idle only after the LAST one finishes', () async {
      final t = UploadTracker();
      t.started();
      t.started();
      final idle = t.idle!;
      t.finished();
      expect(t.uploading, isTrue, reason: 'one upload still in flight');
      expect(idle.isCompleted, isFalse);
      t.finished();
      expect(t.uploading, isFalse);
      await idle.future;
    });

    test('failure flag clears at the start of a fresh round', () {
      final t = UploadTracker();
      t.started();
      t.finished(failed: true);
      expect(t.failed, isTrue); // consumed by the send decision
      t.started(); // fresh round
      expect(t.failed, isFalse);
      t.finished();
      expect(t.failed, isFalse);
    });

    test('failure inside an overlapping round is preserved to the end', () {
      final t = UploadTracker();
      t.started();
      t.started(); // overlap: the round did NOT restart on this start
      t.finished(failed: true);
      expect(t.failed, isTrue);
      t.finished(); // the other one succeeds — flag still reports the failure
      expect(t.failed, isTrue);
      expect(t.uploading, isFalse);
    });

    test('stray finished() clamps at zero instead of going negative', () {
      final t = UploadTracker();
      t.finished(); // nothing in flight — must not corrupt the counter
      expect(t.uploading, isFalse);
      t.started();
      expect(t.uploading, isTrue);
      t.finished();
      expect(t.uploading, isFalse);
    });
  });
}
