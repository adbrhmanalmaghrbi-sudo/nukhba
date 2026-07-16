/// The sign-in screen: shown by the router whenever there is no valid session.
///
/// Per the ratified contract (see `SessionController`), the backend has no
/// password route — Supabase mints the access token and the server only
/// verifies it. So this screen collects an **access token** and hands it to
/// [SessionController.signIn], which persists and validates it via `GET /me`.
/// When a real Supabase client flow is added (a later, separately-ratified
/// slice), it plugs into the exact same `signIn(token)` seam without any change
/// to this widget or the controller.
///
/// The screen is a plain `ConsumerWidget` over the session controller: it shows
/// a progress affordance while [SessionAuthenticating], and renders the typed
/// failure via `ErrorPresenter` when the last attempt is [SessionFailed] —
/// never branching on raw error codes itself.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../core/error/error_presenter.dart';
import 'session_controller.dart';
import 'session_state.dart';

/// A stateful consumer so the token `TextEditingController` lives for the
/// screen's lifetime (Flutter requires disposing text controllers).
class SignInScreen extends ConsumerStatefulWidget {
  /// Creates the sign-in screen.
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final TextEditingController _tokenController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  void _submit(SessionState current) {
    if (current is SessionAuthenticating) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // Fire-and-forget: the controller drives state; the UI reacts to it.
    unawaited(
      ref
          .read(sessionControllerProvider.notifier)
          .signIn(_tokenController.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final asyncSession = ref.watch(sessionControllerProvider);
    // While loading or authenticating the submit control is disabled; the
    // failure (if any) drives the error banner below.
    final session = asyncSession.value ?? const SessionUnknown();
    final bool inFlight =
        asyncSession.isLoading || session is SessionAuthenticating;
    final AppError? failure = session is SessionFailed ? session.error : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Nukhba — Sign in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Text(
                    'Sign in',
                    key: Key('signIn.title'),
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text('Enter your Nukhba access token to continue.'),
                  const SizedBox(height: 24),
                  if (failure != null)
                    _ErrorBanner(
                      key: const Key('signIn.errorBanner'),
                      message: ErrorPresenter.message(failure),
                    ),
                  if (failure != null) const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('signIn.tokenField'),
                    controller: _tokenController,
                    enabled: !inFlight,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Access token',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? 'Please enter your access token.'
                        : null,
                    onFieldSubmitted: (_) => _submit(session),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('signIn.submit'),
                    onPressed: inFlight ? null : () => _submit(session),
                    child: inFlight
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Sign in'),
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

/// A simple inline error banner used by the sign-in form.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
