/// Inline network audio player (just_audio) for audio media in posts: bare
/// audio URLs in content, NIP-92 imeta audio attachments, and extensionless
/// audio links classified by the link probe. Amethyst-style presentation:
/// the waveform strip is the visual body. When the imeta carries a
/// `waveform` field (NIP-A0 voice notes: space-separated amplitudes) the
/// REAL waveform renders; otherwise a stable synthetic waveform is generated
/// from the URL seed (Amethyst seeds from the event id — the URL is costr's
/// per-attachment stable seed). Playback progress tints the bars; tap/drag
/// on the strip seeks (release commits, same scrub discipline as the video
/// overlay). Controls: play/pause, speed (shares the video bottom sheet),
/// share link.
///
/// The player is created LAZILY on the first play tap — a feed can hold many
/// audio cards and pre-creating controllers would hit the network for every
/// one of them (metadata probes + buffer priming). A card costs nothing
/// until the user explicitly plays it.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../app/theme.dart';
import '../services/link_preview.dart' show displayDomain;
import '../utils/format.dart';
import 'proxied_network_image.dart' show proxiedUrl;
import 'video_controls.dart' show showSpeedPickerSheet, shareMediaUrl;

/// Number of bars in the synthetic waveform (Amethyst uses 96).
const int kAudioWaveformBars = 96;

/// Amethyst-style synthetic waveform: seeded by [seed] (stable across
/// rebuilds AND across sessions — Dart's seeded [Random] is deterministic),
/// baseline + carrier sine + noise with an optional fade envelope, so each
/// audio card gets its own recognizable "audio silhouette" instead of a flat
/// strip. Values are clamped to [0.05, 1]. Public for unit testing.
List<double> syntheticWaveform(String seed, {int bars = kAudioWaveformBars}) {
  final rng = math.Random(_stableHash(seed));
  const twoPi = 2 * math.pi;
  // Shape parameters drawn once per seed — these are what make seed A look
  // different from seed B at a glance (ported from Amethyst's
  // SyntheticWaveform.kt).
  final phaseOffset = rng.nextDouble() * twoPi;
  final carrierCycles = 2.5 + rng.nextDouble() * 5.5; // 2.5–8 cycles/strip
  final carrierWeight = 0.18 + rng.nextDouble() * 0.18; // 0.18–0.36
  final baseline = 0.28 + rng.nextDouble() * 0.22; // 0.28–0.50
  final envelopeStrength = rng.nextDouble() * 0.45; // 0–0.45; some fade
  final noiseStrength = 0.18 + rng.nextDouble() * 0.22; // 0.18–0.40
  return List<double>.generate(bars, (i) {
    final phase = i / bars;
    final envelope = 1 - envelopeStrength * (1 - math.sin(phase * math.pi));
    final carrier =
        math.sin(phase * twoPi * carrierCycles + phaseOffset) * carrierWeight;
    final noise = (rng.nextDouble() - 0.5) * 2 * noiseStrength;
    return ((baseline + carrier + noise) * envelope).clamp(0.05, 1.0);
  });
}

/// FNV-1a 32-bit — [String.hashCode] is not guaranteed stable across Dart
/// versions/platforms, and the waveform must be.
int _stableHash(String s) {
  var h = 0x811c9dc5;
  for (final u in s.codeUnits) {
    h ^= u;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

enum _AudioPhase { idle, loading, ready, error }

class NetworkAudio extends StatefulWidget {
  const NetworkAudio({
    super.key,
    required this.url,
    this.waveform,
    this.forceProxy = false,
  });

  final String url;

  /// Real waveform samples from the imeta `waveform` field; null →
  /// [syntheticWaveform] seeded by [url].
  final List<double>? waveform;

  /// When true, load through the proxy mirror ([proxiedUrl]) — flipped on by
  /// the post's "代理媒体" toggle. Manual only.
  final bool forceProxy;

  @override
  State<NetworkAudio> createState() => _NetworkAudioState();
}

class _NetworkAudioState extends State<NetworkAudio> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;

  _AudioPhase _phase = _AudioPhase.idle;
  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;

  /// Local scrub position (fraction of duration) while dragging the waveform;
  /// the seek commits on release only (no seek-storm on remote URLs — same
  /// discipline as the video overlay).
  double? _scrubFraction;

  late List<double> _wave;

  @override
  void initState() {
    super.initState();
    _wave = _resolveWave();
  }

  List<double> _resolveWave() {
    final w = widget.waveform;
    if (w != null && w.isNotEmpty) return w;
    return syntheticWaveform(widget.url);
  }

  @override
  void didUpdateWidget(covariant NetworkAudio oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url ||
        widget.forceProxy != oldWidget.forceProxy ||
        widget.waveform != oldWidget.waveform) {
      _teardown();
      _wave = _resolveWave();
      _phase = _AudioPhase.idle;
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  void _teardown() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _stateSub = null;
    _positionSub = null;
    _player?.dispose();
    _player = null;
    _playing = false;
    _buffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _speed = 1.0;
    _scrubFraction = null;
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (_phase == _AudioPhase.error || _phase == _AudioPhase.loading) return;
    if (_phase == _AudioPhase.idle || p == null) {
      await _initAndPlay();
      return;
    }
    if (_playing) {
      await p.pause();
    } else {
      try {
        if (p.processingState == ProcessingState.completed) {
          await p.seek(Duration.zero);
        }
        await p.play();
      } catch (_) {
        // A dead source surfaces here rather than in setUrl — degrade.
        if (mounted) setState(() => _phase = _AudioPhase.error);
      }
    }
  }

  Future<void> _initAndPlay() async {
    setState(() => _phase = _AudioPhase.loading);
    final p = AudioPlayer();
    _player = p;
    _stateSub = p.playerStateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _playing = s.playing;
        _buffering = s.processingState == ProcessingState.loading ||
            s.processingState == ProcessingState.buffering;
      });
    });
    _positionSub = p.positionStream.listen((d) {
      if (mounted) setState(() => _position = d);
    });
    final effectiveUrl = widget.forceProxy
        ? proxiedUrl(widget.url)
        : widget.url;
    try {
      // preload: true (default) — duration is known when the future settles.
      await p.setUrl(effectiveUrl);
      await p.setSpeed(_speed);
      await p.play();
    } catch (_) {
      if (!mounted) {
        p.dispose();
        return;
      }
      _teardown();
      setState(() => _phase = _AudioPhase.error);
      return;
    }
    if (!mounted) {
      p.dispose();
      return;
    }
    setState(() {
      _duration = p.duration ?? Duration.zero;
      _phase = _AudioPhase.ready;
    });
  }

  void _seekToFraction(double fraction) {
    final p = _player;
    if (p == null || _phase != _AudioPhase.ready) return;
    final target = Duration(
      milliseconds: (fraction * _duration.inMilliseconds).round(),
    );
    // Fire-and-forget: the position stream repaints the bar as it lands.
    p.seek(target);
  }

  double _fractionAt(Offset local, double width) =>
      width <= 0 ? 0 : (local.dx / width).clamp(0.0, 1.0);

  Future<void> _pickSpeed() async {
    final v = await showSpeedPickerSheet(context, _speed);
    final p = _player;
    if (v != null && mounted) {
      setState(() => _speed = v);
      await p?.setSpeed(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = CostrColors.of(context);
    final theme = Theme.of(context);
    if (_phase == _AudioPhase.error) {
      return _Card(
        child: Row(
          children: [
            Icon(
              Icons.music_off_outlined,
              size: 18,
              color: colors.text3,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '音频无法加载',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.text3,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final busy =
        _phase == _AudioPhase.loading ||
        (_phase == _AudioPhase.ready && _buffering);
    final progress = _scrubFraction ??
        (_duration > Duration.zero
            ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(
                0.0,
                1.0,
              )
            : 0.0);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title line: audio glyph + filename (or the domain for
          // extensionless/tag-declared URLs whose path carries no name).
          Row(
            children: [
              Icon(Icons.graphic_eq_rounded, size: 16, color: colors.text3),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _displayName(widget.url),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.text3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _PlayButton(
                busy: busy,
                playing: _playing && !busy,
                onTap: _togglePlay,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => setState(
                        () => _scrubFraction = _fractionAt(d.localPosition, width),
                      ),
                      onTapUp: (d) {
                        final f = _fractionAt(d.localPosition, width);
                        setState(() => _scrubFraction = null);
                        _seekToFraction(f);
                      },
                      onTapCancel: () => setState(() => _scrubFraction = null),
                      onHorizontalDragStart: (d) => setState(
                        () => _scrubFraction = _fractionAt(d.localPosition, width),
                      ),
                      onHorizontalDragUpdate: (d) => setState(
                        () => _scrubFraction = _fractionAt(d.localPosition, width),
                      ),
                      onHorizontalDragEnd: (_) {
                        final f = _scrubFraction;
                        setState(() => _scrubFraction = null);
                        if (f != null) _seekToFraction(f);
                      },
                      child: SizedBox(
                        height: 44,
                        child: CustomPaint(
                          painter: _WaveformPainter(
                            bars: _wave,
                            progress: progress,
                            activeColor: colors.brand,
                            inactiveColor: colors.text3.withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '${formatDuration(_scrubFraction != null && _duration > Duration.zero ? Duration(milliseconds: (_scrubFraction! * _duration.inMilliseconds).round()) : _position)} / ${formatDuration(_duration)}',
                style: const TextStyle(fontSize: 11).copyWith(
                  color: colors.text3,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _phase == _AudioPhase.ready ? _pickSpeed : null,
                style: TextButton.styleFrom(
                  foregroundColor: colors.text2,
                  disabledForegroundColor: colors.text3.withValues(alpha: 0.5),
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(formatSpeed(_speed)),
              ),
              _SmallIconButton(
                icon: Icons.share_outlined,
                onTap: () => shareMediaUrl(
                  context,
                  widget.url,
                  subject: 'Costr 音频',
                  copiedMessage: '已复制音频链接',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Filename from the URL path; falls back to the domain when the path ends
/// in a root or carries no dotted name (tag-declared / probe-classified
/// audio URLs often have none).
String _displayName(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final slash = path.lastIndexOf('/');
  final name = slash >= 0 ? path.substring(slash + 1) : path;
  if (name.isNotEmpty && name.contains('.')) return name;
  return displayDomain(url);
}

/// Themed rounded card (radius 16 + 1px border, §15 card conventions).
class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = CostrColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.bg2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: child,
    );
  }
}

/// Brand-filled circular play/pause button; shows a spinner while the source
/// loads/buffers.
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.busy,
    required this.playing,
    required this.onTap,
  });
  final bool busy;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CostrColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colors.brand,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: busy
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.onBrand,
                ),
              )
            : Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: colors.onBrand,
                size: 26,
              ),
      ),
    );
  }
}

/// 16px icon chip for the card's action row (share).
class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CostrColors.of(context);
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 16, color: colors.text3),
        ),
      ),
    );
  }
}

/// Waveform strip painter: [bars] amplitude samples (normalized to their own
/// max so real NIP-A0 waveforms of any scale fill the strip), left of
/// [progress] painted [activeColor], the rest [inactiveColor].
class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  final List<double> bars;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    if (n == 0 || size.width <= 0 || size.height <= 0) return;
    var maxV = 0.0;
    for (final b in bars) {
      final a = b.abs();
      if (a > maxV) maxV = a;
    }
    final scale = maxV > 0 ? 1 / maxV : 1.0;
    final step = size.width / n;
    final barWidth = math.max(1.5, step * 0.6);
    final radius = Radius.circular(barWidth / 2);
    final paint = Paint();
    final playedUntil = progress * n;
    for (var i = 0; i < n; i++) {
      final amp = (bars[i].abs() * scale).clamp(0.04, 1.0);
      final h = math.max(2.0, amp * size.height);
      final cx = step * i + step / 2;
      paint.color = i < playedUntil ? activeColor : inactiveColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - barWidth / 2, (size.height - h) / 2, barWidth, h),
          radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.bars != bars ||
      oldDelegate.progress != progress ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.inactiveColor != inactiveColor;
}
