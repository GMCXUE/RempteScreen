import 'package:flutter/material.dart';
import 'app_motion.dart';

/// Feedback after a confirmed save does not depend on a later profile refresh.
void showAccountFeedback(BuildContext context, String text) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(
      SnackBar(
          content: Text(text), duration: const Duration(milliseconds: 1200)),
      snackBarAnimationStyle: AppMotion.style(context,
          duration: AppMotion.content, reverseDuration: AppMotion.feedback));
}
