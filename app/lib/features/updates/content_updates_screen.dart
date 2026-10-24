import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';

enum _InboxView { unread, later, history, subscriptions }

class ContentUpdatesScreen extends StatefulWidget {
  const ContentUpdatesScreen({super.key});

  @override
  State<ContentUpdatesScreen> createState() => _ContentUpdatesScreenState();
}

class _ContentUpdatesScreenState extends State<ContentUpdatesScreen> {
  _InboxView _view = _InboxView.unread;
  bool _busy = false;

  Future<void> _run(Future<void> Function() operation) async {
    setState(() => _busy = true);
    try {
      await operation();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Die Änderung konnte nicht gespeichert werden. Bitte die Bibliothek prüfen.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final vault = scope.library.library;
    final events = scope.library.contentUpdates
        .where(
          (event) => switch (_view) {
            _InboxView.unread =>
              event.disposition == ContentUpdateDisposition.unread,
            _InboxView.later =>
              event.disposition == ContentUpdateDisposition.later,
            _InboxView.history =>
              event.disposition == ContentUpdateDisposition.seen ||
                  event.disposition == ContentUpdateDisposition.hidden,
            _InboxView.subscriptions => false,
          },
        )
        .toList();
    final subscriptions = scope.library.works
        .where((work) => vault?.contentSubscriptions.contains(work.id) ?? false)
        .toList();
    final editable =
        vault != null && !vault.isReadOnly && vault.contentUpdatesError == null;
    final count = _view == _InboxView.subscriptions
        ? subscriptions.length
        : events.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(FundusSpace.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Neues für dich',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: FundusSpace.x2),
              const Text(
                'Neue Dateien und Änderungen seit deinem Abo. Bestandsdateien zählen nicht als neu; Fortschritte bleiben unverändert.',
              ),
              const Text(
                'Die letzten 500 bearbeiteten Hinweise bleiben erhalten. Neue und zurückgestellte Hinweise werden nicht automatisch entfernt.',
              ),
              if (vault?.contentUpdatesError != null)
                const Text(
                  'Der gespeicherte Posteingang kann nicht gelesen werden. Er bleibt unverändert erhalten; Abos können derzeit nicht bearbeitet werden.',
                ),
              Wrap(
                spacing: FundusSpace.x3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<_InboxView>(
                    value: _view,
                    onChanged: (value) => setState(() => _view = value!),
                    items: const [
                      DropdownMenuItem(
                        value: _InboxView.unread,
                        child: Text('Neue Hinweise'),
                      ),
                      DropdownMenuItem(
                        value: _InboxView.later,
                        child: Text('Später ansehen'),
                      ),
                      DropdownMenuItem(
                        value: _InboxView.history,
                        child: Text('Gesehen & ausgeblendet'),
                      ),
                      DropdownMenuItem(
                        value: _InboxView.subscriptions,
                        child: Text('Abonnierte Werke'),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: !editable || _busy
                        ? null
                        : () =>
                              _run(scope.library.subscribeStartedContentWorks),
                    child: const Text('Begonnene Werke abonnieren'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: count == 0
              ? FundusEmptyState(
                  title: _view == _InboxView.subscriptions
                      ? 'Noch keine sichtbaren Abos'
                      : 'Keine sichtbaren Hinweise',
                  reason:
                      'Abonniere Werke auf ihrer Detailseite. Hinweise entstehen bei den vorhandenen Bibliotheksprüfungen. Aktive Schutz- und Bibliotheksfilter gelten auch hier.',
                )
              : ListView.builder(
                  itemCount: count,
                  itemBuilder: (context, index) {
                    if (_view == _InboxView.subscriptions) {
                      final work = subscriptions[index];
                      return ListTile(
                        title: Text(work.title),
                        onTap: () => scope.navigation.go(WorkRoute(work.id)),
                        trailing: ContentSubscriptionButton(workId: work.id),
                      );
                    }
                    final event = events[index];
                    final work = scope.library.workById(event.file.workId)!;
                    final kind = switch (event.kind) {
                      ContentUpdateKind.added => 'Neu verfügbar',
                      ContentUpdateKind.changed => 'Datei geändert',
                      ContentUpdateKind.removed => 'Nicht mehr verfügbar',
                    };
                    return ListTile(
                      key: ValueKey('content-update-${event.id}'),
                      title: Text(work.title),
                      subtitle: Text('$kind · ${event.file.title}'),
                      onTap: () => scope.navigation.go(WorkRoute(work.id)),
                      trailing: PopupMenuButton<String>(
                        enabled: !_busy,
                        tooltip: 'Hinweis bearbeiten',
                        icon: Icon(
                          FundusIcons.moreVertical,
                          size: FundusIcons.sizeSm,
                        ),
                        onSelected: (value) => _run(() async {
                          if (value == 'open') {
                            // Resolve again: an index rebuild may have changed file IDs.
                            final currentWork = scope.library.workById(
                              event.file.workId,
                            );
                            if (currentWork == null) return;
                            final fileId = vault?.resolveContentUpdateFile(
                              event,
                            );
                            if (fileId == null) {
                              scope.navigation.go(WorkRoute(currentWork.id));
                            } else {
                              await scope.play(
                                currentWork,
                                startAt: fileId,
                                chapterId: event.file.chapterId,
                              );
                            }
                          } else {
                            final disposition = ContentUpdateDisposition.values
                                .firstWhere((entry) => entry.name == value);
                            await scope.library.setContentUpdateDisposition(
                              event.id,
                              disposition,
                            );
                          }
                        }),
                        itemBuilder: (_) => [
                          if (event.kind != ContentUpdateKind.removed)
                            const PopupMenuItem(
                              value: 'open',
                              child: Text('Diesen Teil öffnen'),
                            ),
                          if (editable) ...[
                            const PopupMenuItem(
                              value: 'later',
                              child: Text('Später ansehen'),
                            ),
                            const PopupMenuItem(
                              value: 'seen',
                              child: Text('Als gesehen markieren'),
                            ),
                            const PopupMenuItem(
                              value: 'hidden',
                              child: Text('Hinweis ausblenden'),
                            ),
                            if (event.disposition !=
                                ContentUpdateDisposition.unread)
                              const PopupMenuItem(
                                value: 'unread',
                                child: Text('Wieder als neu anzeigen'),
                              ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// The same opt-in action for local works and mirrored catalogues.
class ContentSubscriptionButton extends StatefulWidget {
  const ContentSubscriptionButton({super.key, required this.workId});
  final String workId;

  @override
  State<ContentSubscriptionButton> createState() =>
      _ContentSubscriptionButtonState();
}

class _ContentSubscriptionButtonState extends State<ContentSubscriptionButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final vault = scope.library.library;
    final subscribed =
        vault?.contentSubscriptions.contains(widget.workId) ?? false;
    return OutlinedButton.icon(
      onPressed:
          _busy ||
              vault == null ||
              vault.isReadOnly ||
              vault.contentUpdatesError != null
          ? null
          : () async {
              setState(() => _busy = true);
              try {
                await scope.library.setContentSubscription(
                  widget.workId,
                  !subscribed,
                );
              } on Object {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Abo konnte nicht gespeichert werden.'),
                    ),
                  );
                }
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
      icon: Icon(FundusIcons.activity, size: FundusIcons.sizeSm),
      label: Text(subscribed ? 'Abonniert' : 'Updates abonnieren'),
    );
  }
}
