/// The authenticated landing screen for the Auth slice.
///
/// Scope note (Flutter App phase, §4 Core-scope decision #1): this home renders
/// the canonical principal from GET /me (the [SessionAuthenticated.user] the
/// controller is already holding) plus a sign-out control, and — now that the
/// Competition browse slice exists — a single entry point into it
/// ([CompetitionListScreen]). It still builds NO Prediction / Leaderboard
/// surface here and NO out-of-scope feature stubs.
///
/// It reads the verified user straight off the session state (no extra network
/// call) and delegates sign-out to [SessionController.signOut]. Presentation
/// uses the "Midnight Pitch" design system; every test key is unchanged.
library;

import 'dart:async';

import 'package:contracts/contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../competition/competition_list_screen.dart';
import 'session_controller.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({required this.user, super.key});

  final AuthenticatedUserDto user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nukhba'),
        actions: [
          IconButton(
            key: const Key('account.signOut'),
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => unawaited(
              ref.read(sessionControllerProvider.notifier).signOut(),
            ),
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: AppColors.backgroundGradient,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _IdentityHeader(user: user),
                  const SizedBox(height: 24),
                  _IdentityCard(user: user),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('account.browseCompetitions'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.emoji_events_outlined),
                    label: const Text('Browse competitions'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CompetitionListScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({required this.user});

  final AuthenticatedUserDto user;

  @override
  Widget build(BuildContext context) {
    final String initial = user.userId.isNotEmpty
        ? user.userId.substring(0, 1).toUpperCase()
        : '?';
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: AppColors.primaryGradient,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.35),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            initial,
            style: const TextStyle(
              color: AppColors.onPrimary,
              fontSize: 30,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Signed in',
          key: Key('account.title'),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.user});

  final AuthenticatedUserDto user;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _Field(
            label: 'User ID',
            value: user.userId,
            valueKey: const Key('account.userId'),
          ),
          const Divider(color: AppColors.border, height: 1),
          _Field(
            label: 'Role',
            value: user.role,
            valueKey: const Key('account.role'),
          ),
          const Divider(color: AppColors.border, height: 1),
          _Field(
            label: 'Status',
            value: user.status,
            valueKey: const Key('account.status'),
          ),
          if (user.email != null) ...[
            const Divider(color: AppColors.border, height: 1),
            _Field(
              label: 'Email',
              value: user.email!,
              valueKey: const Key('account.email'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              key: valueKey,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
