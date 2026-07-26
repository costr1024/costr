/// Profile page — shows the logged-in identity (npub + hex pubkey) + logout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idAsync = ref.watch(identityProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: idAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, _) => Center(child: Text('加载失败：$e')),
        data: (identity) {
          if (identity == null) {
            return const Center(child: Text('未登录'));
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.account_circle,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text('npub',
                        style: Theme.of(context).textTheme.labelSmall),
                    SelectableText(
                      identity.npub,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    Text('pubkey (hex)',
                        style: Theme.of(context).textTheme.labelSmall),
                    SelectableText(
                      identity.pubkeyHex,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.logout),
                      label: const Text('登出'),
                      onPressed: () async {
                        await ref
                            .read(identityProvider.notifier)
                            .logout();
                        if (context.mounted) context.go('/login');
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
