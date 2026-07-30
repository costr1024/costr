/// First-run onboarding overlay (DESIGN §6 / ui_demo.html `.ob`).
///
/// Three bubble steps shown once over the main shell after first login:
/// 1. 发帖 (FAB) — broadcasting, no platform can censor you.
/// 2. 通知 (nav tab) — @mentions / replies / likes; quiet in background.
/// 3. 关注 — follow people from their profile; their posts appear in 关注 feed.
///
/// Dimmed backdrop + tip card (matches the demo; no cutout highlight). Tap
/// backdrop or 跳过 → done. After the last step → done. The "seen" flag is
/// persisted by the caller (AppShell) in the local config table so it never
/// shows again.
library;

import 'package:flutter/material.dart';

class OnboardingOverlay extends StatefulWidget {
  const OnboardingOverlay({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _ObStep {
  const _ObStep({required this.title, required this.text, required this.alignment});
  final String title;
  final String text;
  final Alignment alignment;
}

class _OnboardingOverlayState extends State<OnboardingOverlay> {
  int _step = 0;

  static const List<_ObStep> _steps = <_ObStep>[
    _ObStep(
      title: '发帖',
      text: '点右下角按钮发一条帖子。你发的会广播到全网，没有平台能审核你的号。',
      alignment: Alignment.bottomRight,
    ),
    _ObStep(
      title: '通知',
      text: '点底栏的「通知」看你被 @、被回复、被喜欢。App 在后台不会偷偷盯着，省电。',
      alignment: Alignment.bottomCenter,
    ),
    _ObStep(
      title: '关注',
      text: '点别人的头像或名字进主页，关注后他们的帖子会出现在「首页·关注」里。',
      alignment: Alignment.bottomCenter,
    ),
  ];

  void _next() {
    if (_step < _steps.length - 1) {
      setState(() => _step++);
    } else {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _steps[_step];
    final isLast = _step == _steps.length - 1;
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: <Widget>[
          // Dimmed backdrop; tap = skip.
          Positioned.fill(
            child: GestureDetector(
              onTap: widget.onDone,
              child: const ColoredBox(
                color: Color(0x8C000000),
              ),
            ),
          ),
          Align(
            alignment: s.alignment,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 260),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x4D000000),
                      blurRadius: 30,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Text(s.title,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        GestureDetector(
                          onTap: widget.onDone,
                          child: const Text('跳过',
                              style: TextStyle(
                                  color: Color(0xFF1D9BF0), fontSize: 13)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(s.text,
                        style: const TextStyle(
                            color: Color(0xFF536471),
                            fontSize: 13,
                            height: 1.5)),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: _next,
                        child: Text(isLast ? '完成' : '下一步'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
