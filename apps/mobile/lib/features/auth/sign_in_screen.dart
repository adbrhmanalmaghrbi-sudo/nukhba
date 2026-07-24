/// The sign-in screen: shown by the router whenever there is no valid session.
///
/// Per the ratified contract (see SessionController), the backend has no
/// password route — Supabase mints the access token and the server only
/// verifies it. So this screen collects an access token and hands it to
/// [SessionController.signIn], which persists and validates it via GET /me.
/// When a real Supabase client flow is added (a later, separately-ratified
/// slice), it plugs into the exact same signIn(token) seam without any change
/// to this widget or the controller.
///
/// The screen is a ConsumerStatefulWidget over the session controller: it
/// shows a progress affordance while [SessionAuthenticating], and renders the
/// typed failure via ErrorPresenter when the last attempt is [SessionFailed]
/// — never branching on raw error codes itself. Only presentation changed with
/// the "Midnight Pitch" design system; the keys and mechanism are unchanged.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../core/error/error_presenter.dart';
import '../../core/theme/app_colors.dart';
import 'session_controller.dart';
import 'session_state.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState {
  final TextEditingController _tokenController = TextEditingController();
  final GlobalKey _formKey = GlobalKey();
  bool _obscure = true;

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  void _submit(SessionState current) {
    if (current is SessionAuthenticating) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    unawaited(
      ref
          .read(sessionControllerProvider.notifier)
          .signIn(_tokenController.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue asyncSession = ref.watch(
      sessionControllerProvider,
    );
    final SessionState session = asyncSession.value ?? const SessionUnknown();
    final bool inFlight =
        asyncSession.isLoading || session is SessionAuthenticating;
    final AppError? failure = session is SessionFailed ? session.error : null;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: AppColors.backgroundGradient,
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _Header(),
                    const SizedBox(height: 32),
                    _card(inFlight, failure, session),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(bool inFlight, AppError? failure, SessionState session) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Sign in',
              key: Key('signIn.title'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Enter your Nukhba access token to continue.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 24),
            if (failure != null) ...[
              _ErrorBanner(
                key: const Key('signIn.errorBanner'),
                message: ErrorPresenter.message(failure),
              ),
              const SizedBox(height: 16),
            ],
            TextFormField(
              key: const Key('signIn.tokenField'),
              controller: _tokenController,
              enabled: !inFlight,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Access token',
                prefixIcon: const Icon(
                  Icons.vpn_key_outlined,
                  color: AppColors.textMuted,
                ),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show token' : 'Hide token',
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: AppColors.textMuted,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'Please enter your access token.'
                  : null,
              onFieldSubmitted: (_) => _submit(session),
            ),
            const SizedBox(height: 24),
            _SubmitButton(
              inFlight: inFlight,
              onPressed: inFlight ? null : () => _submit(session),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            gradient: AppColors.primaryGradient,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(
            Icons.sports_soccer,
            color: AppColors.onPrimary,
            size: 40,
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Nukhba',
          style: TextStyle(
            fontSize: 38,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'The elite football prediction platform',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({required this.inFlight, required this.onPressed});

  final bool inFlight;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: inFlight ? null : AppColors.primaryGradient,
          color: inFlight ? AppColors.surfaceHigh : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: FilledButton(
          key: const Key('signIn.submit'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
          ),
          onPressed: onPressed,
          child: inFlight
              ? const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppColors.onPrimary,
                  ),
                )
              : const Text(
                  'Sign in',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.onPrimary,
                  ),
                ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
