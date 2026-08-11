/// Navigation helpers.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Push a post's detail page (`/n/:id`) onto the stack, but skip if that post
/// is already on top of the navigation stack.
///
/// Why: the post detail page ([PostDetailPage]) renders the focused post as an
/// [EventCard], whose own `onTap` would otherwise push the *same* `/n/:id`
/// again on every tap — stacking duplicate detail pages so back has to be
/// pressed once per stray tap. Inspecting the top of go_router's match list
/// (which includes imperative/pushed routes via `matchedLocation`) catches
/// "already viewing this exact post" and no-ops; tapping a *different* post
/// (e.g. a reply or parent in the thread) still pushes normally.
void pushPostDetail(BuildContext context, String id) {
  final matches = GoRouter.of(context).routerDelegate.currentConfiguration;
  final top = matches.matches.isEmpty
      ? null
      : matches.matches.last.matchedLocation;
  if (top == '/n/$id') return;
  context.push('/n/$id');
}
