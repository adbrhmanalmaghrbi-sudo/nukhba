/// A small, reusable renderer for the four browse states of an async list read:
/// **loading**, **error**, **legitimate-empty**, and **data**.
///
/// Every Competition browse screen watches a `FutureProvider` and must present
/// the same four outcomes consistently. Centralising them here keeps each screen
/// free of `AsyncValue` boilerplate and guarantees the *legitimate empty* case
/// (an empty catalogue / seasonless competition / roundless season / fixtureless
/// round — all valid `Ok(<empty>)` reads, never failures) is shown as an
/// informational empty affordance, never as an error.
///
/// Errors arrive as a thrown [AppError] (see `competition_providers.dart`) and
/// are rendered through `ErrorPresenter` — the single place error text is
/// produced — with a retry affordance only when the failure is retryable
/// (transient). The widget never branches on raw error codes itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import '../../../core/error/error_presenter.dart';

/// Renders an [AsyncValue] holding a `List<T>` as one of loading / error /
/// empty / data.
///
/// [itemBuilder] builds a row for each element; [emptyMessage] is shown when the
/// read succeeds with no elements; [onRetry] is invoked when the user taps the
/// retry affordance offered on a retryable failure (typically
/// `ref.invalidate(theProvider)`).
class AsyncListView<T> extends StatelessWidget {
  /// Creates an async list view over [value].
  const AsyncListView({
    required this.value,
    required this.itemBuilder,
    required this.emptyMessage,
    required this.onRetry,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
    super.key,
  });

  /// The async list state to render.
  final AsyncValue<List<T>> value;

  /// Builds a widget for a single element.
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// The message shown when the list is a legitimate empty result.
  final String emptyMessage;

  /// Called when the user asks to retry after a retryable failure.
  final VoidCallback onRetry;

  /// The padding around the list.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: false,
      loading: () => const _Loading(),
      error: (error, _) => _ErrorView(error: error, onRetry: onRetry),
      data: (items) {
        if (items.isEmpty) {
          return _EmptyView(message: emptyMessage);
        }
        return ListView.separated(
          key: const Key('browse.list'),
          padding: padding,
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) => itemBuilder(context, items[index]),
        );
      },
    );
  }
}

/// Renders an [AsyncValue] holding a single object [T] as loading / error /
/// data (there is no "empty" case for a single-item read — a missing item is an
/// [AppError], not an empty success).
class AsyncObjectView<T> extends StatelessWidget {
  /// Creates an async object view over [value].
  const AsyncObjectView({
    required this.value,
    required this.builder,
    required this.onRetry,
    super.key,
  });

  /// The async single-object state to render.
  final AsyncValue<T> value;

  /// Builds the widget for the loaded object.
  final Widget Function(BuildContext context, T data) builder;

  /// Called when the user asks to retry after a retryable failure.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: false,
      loading: () => const _Loading(),
      error: (error, _) => _ErrorView(error: error, onRetry: onRetry),
      data: (data) => builder(context, data),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(
    key: Key('browse.loading'),
    child: Padding(
      padding: EdgeInsets.all(32),
      child: CircularProgressIndicator(),
    ),
  );
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const Key('browse.empty'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.inbox_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              message,
              key: const Key('browse.empty.message'),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  /// The thrown failure. Providers throw a typed [AppError]; anything else is
  /// coerced to a generic transient so the user still sees sensible copy and a
  /// retry affordance rather than a raw exception.
  final Object error;
  final VoidCallback onRetry;

  AppError get _appError => error is AppError
      ? error as AppError
      : const AppError.transient(
          'client.unexpected',
          'Something went wrong. Please try again.',
        );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final appError = _appError;
    return Center(
      key: const Key('browse.error'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              ErrorPresenter.message(appError),
              key: const Key('browse.error.message'),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurface),
            ),
            if (ErrorPresenter.isRetryable(appError)) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton.tonal(
                key: const Key('browse.error.retry'),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
