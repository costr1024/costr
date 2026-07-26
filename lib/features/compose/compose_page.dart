/// Compose page — placeholder (发帖功能将在后续版本推出).
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
            '发帖功能将在后续版本推出。',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
