/// Feed page — placeholder.
///
/// Will display a time-sorted list of text-note (NIP-01 kind 1) events
/// fetched from connected relays.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class FeedPage extends StatelessWidget {
  const FeedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('costr')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Feed\n\nRelay connection and event rendering arrive once '
            'features are wired up.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.edit),
        label: const Text('Compose'),
        onPressed: () => context.go('/compose'),
      ),
      bottomNavigationBar: NavigationBar(
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Feed',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
        selectedIndex: 0,
        onDestinationSelected: (i) => context.go(i == 0 ? '/feed' : '/profile'),
      ),
    );
  }
}
