/// Small pure formatting helpers shared across widgets (video player time
/// labels, speed button label). Kept dependency-free so they are trivially
/// unit-testable.
library;

/// Formats a playback duration as `m:ss` (or `h:mm:ss` when >= 1 hour),
/// matching common video players. Negative values clamp to 0:00.
String formatDuration(Duration d) {
  var total = d.inSeconds;
  if (total < 0) total = 0;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:$ss';
  }
  return '$m:$ss';
}

/// Formats a playback speed as a compact button label: 1 → `1.0x`,
/// 0.75 → `0.75x`.
String formatSpeed(double speed) => '${speed}x';
