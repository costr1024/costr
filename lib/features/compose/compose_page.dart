/// Compose page — placeholder.
library;

import 'package:flutter/material.dart';

class ComposePage extends StatelessWidget {
  const ComposePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compose')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Compose\n\nEvent signing (NIP-01) and publishing to relays '
            'arrive once features are wired up.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
