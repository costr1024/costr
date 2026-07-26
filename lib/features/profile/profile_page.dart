/// Profile page — placeholder.
library;

import 'package:flutter/material.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Profile\n\nKey management, metadata (NIP-05), and follows '
            'arrive once features are wired up.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
