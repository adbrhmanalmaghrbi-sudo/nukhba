/// The authenticated landing screen for the Auth slice.
///
/// Scope note (Flutter App phase, §4 Core-scope decision #1): this home renders
/// the canonical principal from `GET /me` (the [SessionAuthenticated.user] the
/// controller is already holding) plus a sign-out control, and — now that the
/// Competition browse slice exists — a single entry point into it
/// ([CompetitionListScreen]). It still builds NO Prediction / Leaderboard
/// surface (those are the next in-scope screens) and NO out-of-scope feature
/// stubs (Ledger / Groups / Social / Notifications / Admin).
///
/// It reads the verified user straight off the session state (no extra network
/// call) and delegates sign-out to [SessionController.signOut], after which the
/// router returns the user to the sign-in screen.
library;

import 'dart:async';

import 'package:contracts/contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../competition/competition_list_screen.dart';
import 'session_controller.dart';

/// Shows the signed-in user's identity and a sign-out action.
class AccountScreen extends ConsumerWidget {
  /// Creates the account/home screen for [user].
  const AccountScreen({required this.user, super.key});

  /// The canonical principal returned by `GET /me`.
  final AuthenticatedUserDto user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nukhba'),
        actions: <Widget>[
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'Signed in',
                  key: Key('account.title'),
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                _Field(
                  label: 'User ID',
                  value: user.userId,
                  valueKey: const Key('account.userId'),
                ),
                _Field(
                  label: 'Role',
                  value: user.role,
                  valueKey: const Key('account.role'),
                ),
                _Field(
                  label: 'Status',
                  value: user.status,
                  valueKey: const Key('account.status'),
                ),
                if (user.email != null)
                  _Field(
                    label: 'Email',
                    value: user.email!,
                    valueKey: const Key('account.email'),
                  ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const Key('account.browseCompetitions'),
                  icon: const Icon(Icons.emoji_events_outlined),
                  label: const Text('Browse competitions'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CompetitionListScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled read-only identity field.
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
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(value, key: valueKey),
        ],
      ),
    );
  }
}
