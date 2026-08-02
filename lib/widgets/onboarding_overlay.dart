/// First-run onboarding overlay (DESIGN §6 / ui_demo.html `.ob`).
///
/// Seven bubble steps shown once over the main shell after first login:
/// 1. 发帖 (FAB) — broadcasting, no platform can censor you.
/// 2. 搜索 (nav tab) — search users / posts (NIP-50).
/// 3. 通知 (nav tab) — @mentions / replies / likes; quiet in background.
/// 4. 关注 — follow people from their profile; their posts appear in 关注 feed.
/// 5. 语言过滤 (home topbar 🌐) — filter the feed by 中文 / 英文 / 日文.
/// 6. 关注过滤 (following-mode filter icon) — narrow by custom group / hashtag.
/// 7. 设置 (我的 → 设置) — account backup / server nodes / notifications / about.
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
  const _ObStep({
    required this.title,
    required this.text,
    required this.alignment,
  });
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
      title: '搜索',
      text: '点底栏「搜索」按内容或名字搜用户、帖子。和首页的语言/关注过滤互不影响。',
      alignment: Alignment.bottomCenter,
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
    _ObStep(
      title: '语言过滤',
      text: '首页顶栏 🌐 按语言过滤帖子：全部 / 🇨🇳中文 / 🇬🇧英文 / 🇯🇵日文。只在首页生效。',
      alignment: Alignment.topRight,
    ),
    _ObStep(
      title: '关注过滤',
      text: '切到「关注」后，顶栏筛选图标可按自定义分组或标签过滤，只看你想看的人。',
      alignment: Alignment.topCenter,
    ),
    _ObStep(
      title: '设置',
      text: '「我的」→ 设置：账号可再看/备份私钥、查看服务器节点与时延、通知开关，还有「关于 Costr」。私钥只在本机。',
      alignment: Alignment.bottomRight,
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
              child: const ColoredBox(color: Color(0x8C000000)),
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
                        Text(
                          s.title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        GestureDetector(
                          onTap: widget.onDone,
                          child: const Text(
                            '跳过',
                            style: TextStyle(
                              color: Color(0xFF1D9BF0),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.text,
                      style: const TextStyle(
                        color: Color(0xFF536471),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
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
