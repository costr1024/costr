/// Inline network audio player (just_audio) for audio media in posts: bare
/// audio URLs in content, NIP-92 imeta audio attachments, and extensionless
/// audio links classified by the link probe. The waveform strip is the
/// Amethyst-style visual identity (real imeta `waveform` samples when the
/// source carries them, a URL-seeded synthetic waveform otherwise; playback
/// progress tints the bars) — but every control is an explicit, tappable
/// Material widget (play/pause, ±10s, a real seek slider, speed, share):
/// waveform-only gestures read as "没法点/没反应" in user testing.
///
/// The player is created LAZILY on the first play tap — a feed can hold many
/// audio cards and pre-creating controllers would hit the network for every
/// one of them. A card costs nothing until the user explicitly plays it.
///
/// Coordination ([_AudioCoordinator]): at most one card plays at a time,
/// and leaving the foreground pauses every player (a plain AudioPlayer keeps
/// sounding with the app in the background — users expect feed audio to stop
/// when they leave).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../app/theme.dart';
import '../services/link_preview.dart' show displayDomain;
import '../utils/format.dart';
import 'proxied_network_image.dart' show proxiedUrl;
import 'video_controls.dart'
    show clampSeek, showSpeedPickerSheet, shareMediaUrl;

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

/// Cross-card audio coordination: at most ONE inline audio plays at a time
/// (starting one pauses the others), and EVERYTHING pauses when the app
/// leaves the foreground — a plain [AudioPlayer] keeps sounding in the
/// background otherwise ("切到后台还在响，想停停不掉"). Deliberately NOT a
/// background-playback service: Costr's audio belongs to the visible card.
class _AudioCoordinator with WidgetsBindingObserver {
  _AudioCoordinator();

  static final _AudioCoordinator instance = _AudioCoordinator();

  final Set<_NetworkAudioState> _active = {};
  bool _observing = false;

  void register(_NetworkAudioState s) {
    _active.add(s);
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
  }

  void unregister(_NetworkAudioState s) {
    _active.remove(s);
  }

  /// [s] is about to start playing — pause every other card first.
  void exclusivePlay(_NetworkAudioState s) {
    for (final other in List.of(_active)) {
      if (!identical(other, s)) other.pauseIfPlaying();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      for (final s in List.of(_active)) {
        s.pauseIfPlaying();
      }
    }
  }
}

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

  /// Local scrub position while dragging the slider; the seek commits on
  /// release only (no seek-storm on remote URLs — same discipline as the
  /// video overlay, whose [clampSeek] also bounds the ±10s steps).
  Duration? _scrubPos;
  bool _wasPlaying = false;

  late List<double> _wave;

  @override
  void initState() {
    super.initState();
    _wave = _resolveWave();
    _AudioCoordinator.instance.register(this);
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
    _AudioCoordinator.instance.unregister(this);
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
    _scrubPos = null;
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (_phase == _AudioPhase.error || _phase == _AudioPhase.loading) return;
    if (p == null) {
      await _initAndPlay();
      return;
    }
    // The PLAYER is the source of truth here — not _playing, which is one
    // stream event behind; routing a stale pause-tap into play() reads as
    // 「按了没反应」.
    if (p.playing) {
      await p.pause();
    } else {
      try {
        if (p.processingState == ProcessingState.completed) {
          await p.seek(Duration.zero);
        }
        _AudioCoordinator.instance.exclusivePlay(this);
        await p.play();
      } catch (_) {
        // A dead source surfaces here rather than in setUrl — degrade.
        if (mounted) setState(() => _phase = _AudioPhase.error);
      }
    }
  }

  /// Coordinator hook (other card started playing / app backgrounded): pause
  /// without ceremony.
  void pauseIfPlaying() {
    final p = _player;
    if (p != null && p.playing) p.pause();
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
      _AudioCoordinator.instance.exclusivePlay(this);
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

  void _step(int seconds) {
    final p = _player;
    if (p == null || _phase != _AudioPhase.ready) return;
    p.seek(clampSeek(_scrubPos ?? _position, seconds, _duration));
  }

  void _scrubStart(double millis) {
    final p = _player;
    if (p == null || _phase != _AudioPhase.ready) return;
    _wasPlaying = p.playing;
    if (_wasPlaying) p.pause();
    setState(() => _scrubPos = Duration(milliseconds: millis.round()));
  }

  void _scrubTo(double millis) {
    if (_phase != _AudioPhase.ready) return;
    setState(() => _scrubPos = Duration(milliseconds: millis.round()));
  }

  void _scrubEnd(double millis) {
    final p = _player;
    if (p == null || _phase != _AudioPhase.ready) return;
    p.seek(Duration(milliseconds: millis.round()));
    if (_wasPlaying) {
      _AudioCoordinator.instance.exclusivePlay(this);
      p.play();
    }
    setState(() => _scrubPos = null);
  }

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
            Icon(Icons.music_off_outlined, size: 18, color: colors.text3),
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

    final ready = _phase == _AudioPhase.ready;
    // Spinner only while NOTHING plays yet (initial load / pre-play
    // buffering). While playing the pause icon ALWAYS shows — even mid
    // buffering — otherwise the button reads as dead ("无法暂停").
    final busy = !_playing &&
        (_phase == _AudioPhase.loading || (ready && _buffering));
    final displayPos = _scrubPos ?? _position;
    final totalMs = _duration.inMilliseconds.toDouble();
    final progress = _duration > Duration.zero
        ? (displayPos.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

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
          const SizedBox(height: 10),
          // Transport row: play/pause, ±10s, waveform (progress visual).
          Row(
            children: [
              _PlayButton(
                busy: busy,
                playing: _playing,
                onTap: _togglePlay,
              ),
              const SizedBox(width: 8),
              _StepButton(
                icon: Icons.replay_10_rounded,
                onTap: ready ? () => _step(-10) : null,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: CustomPaint(
                    painter: _WaveformPainter(
                      bars: _wave,
                      progress: progress,
                      activeColor: colors.brand,
                      inactiveColor: colors.text3.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _StepButton(
                icon: Icons.forward_10_rounded,
                onTap: ready ? () => _step(10) : null,
              ),
            ],
          ),
          // Seek row: a real, tappable slider (the waveform shows progress;
          // the slider IS the scrubber — waveform-only gestures tested as
          // invisible/unresponsive).
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Text(
                  formatDuration(displayPos),
                  style: TextStyle(fontSize: 11, color: colors.text3),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      activeTrackColor: colors.brand,
                      inactiveTrackColor: colors.text3.withValues(alpha: 0.3),
                      thumbColor: colors.brand,
                      overlayShape: SliderComponentShape.noOverlay,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5,
                      ),
                    ),
                    child: Slider(
                      value: displayPos.inMilliseconds
                          .toDouble()
                          .clamp(0, totalMs > 0 ? totalMs : 1),
                      min: 0,
                      max: totalMs > 0 ? totalMs : 1,
                      onChangeStart: _scrubStart,
                      onChanged: _scrubTo,
                      onChangeEnd: _scrubEnd,
                    ),
                  ),
                ),
                Text(
                  formatDuration(_duration),
                  style: TextStyle(fontSize: 11, color: colors.text3),
                ),
              ],
            ),
          ),
          // Action row: speed + share, right-aligned.
          Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: ready ? _pickSpeed : null,
                style: TextButton.styleFrom(
                  foregroundColor: colors.text2,
                  disabledForegroundColor: colors.text3.withValues(
                    alpha: 0.5,
                  ),
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
/// loads/buffers (only before playback starts — see the `busy` note in
/// build).
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
        decoration: BoxDecoration(color: colors.brand, shape: BoxShape.circle),
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

/// Small circular ±10s step chip.
class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CostrColors.of(context);
    final disabled = onTap == null;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 20,
            color: disabled
                ? colors.text3.withValues(alpha: 0.5)
                : colors.text2,
          ),
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
/// [progress] painted [activeColor], the rest [inactiveColor]. Display-only
/// — the seek surface is the slider below it.
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
