import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import 'downloads_screen.dart' show formatBytes;

Future<void> showOfflineSettings(BuildContext context, {String? workId}) {
  final scope = FundusScope.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AnimatedBuilder(
      animation: Listenable.merge([
        scope.library,
        scope.settings,
        scope.protection,
      ]),
      builder: (_, _) => _OfflineSettings(scope: scope, workId: workId),
    ),
  );
}

class OfflineSettingsButton extends StatelessWidget {
  const OfflineSettingsButton({super.key, this.workId});
  final String? workId;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => showOfflineSettings(context, workId: workId),
    icon: Icon(FundusIcons.downloads, size: FundusIcons.sizeSm),
    label: const Text('Automatisch mitnehmen'),
  );
}

class _OfflineSettings extends StatefulWidget {
  const _OfflineSettings({required this.scope, this.workId});
  final FundusScopeState scope;
  final String? workId;
  @override
  State<_OfflineSettings> createState() => _OfflineSettingsState();
}

class _OfflineSettingsState extends State<_OfflineSettings> {
  final _count = TextEditingController();
  final _budget = TextEditingController();
  bool _enabled = false, _wifi = true, _charging = false, _workSelected = false;
  bool _busy = false;
  String? _error;
  String? _libraryId;
  final _rules = <OfflineRule>[];
  List<LibrarySavedView> _shelves = const [];
  Future<void>? _loadingShelves;
  OfflinePlan? _plan;

  @override
  void initState() {
    super.initState();
    try {
      final policy = widget.scope.settings.offlinePolicy;
      _libraryId = widget.scope.library.library?.manifest.libraryId;
      _enabled = policy.enabled;
      _wifi = policy.wifiOnly;
      _charging = policy.chargingOnly;
      _rules.addAll(widget.scope.offline.rules);
      _shelves = widget.scope.savedViews;
      _loadingShelves = _loadShelves();
      final workRule = _rules
          .where(
            (rule) =>
                rule.scope == OfflineRuleScope.work &&
                rule.targetId == widget.workId,
          )
          .firstOrNull;
      _workSelected = workRule != null;
      _count.text = '${workRule?.nextFiles ?? policy.nextFiles}';
      _budget.text = '${(policy.storageBudgetBytes / (1024 * 1024)).ceil()}';
    } on Object catch (error) {
      _error = '$error';
    }
  }

  Future<void> _loadShelves() async {
    final vault = widget.scope.library.library;
    try {
      final shelves =
          await vault?.loadSavedViews() ?? const <LibrarySavedView>[];
      if (mounted && identical(vault, widget.scope.library.library)) {
        setState(() => _shelves = shelves);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _count.dispose();
    _budget.dispose();
    super.dispose();
  }

  OfflinePolicy _policy() => OfflinePolicy(
    enabled: _enabled,
    nextFiles: int.parse(_count.text.trim()),
    storageBudgetBytes: int.parse(_budget.text.trim()) * 1024 * 1024,
    wifiOnly: _wifi,
    chargingOnly: _charging,
  )..validate();

  List<OfflineRule> _selectedRules() => [
    for (final rule in _rules)
      if (widget.workId == null ||
          rule.scope != OfflineRuleScope.work ||
          rule.targetId != widget.workId)
        rule,
    if (widget.workId != null && _workSelected)
      OfflineRule(
        scope: OfflineRuleScope.work,
        targetId: widget.workId!,
        nextFiles: int.parse(_count.text.trim()),
      ),
  ];

  Future<void> _perform({bool save = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = widget.scope;
      if (_libraryId == null ||
          scope.library.library?.manifest.libraryId != _libraryId) {
        throw StateError('Bibliothek gewechselt. Bitte erneut öffnen.');
      }
      if (widget.workId != null &&
          scope.library.workById(widget.workId!) == null) {
        throw StateError('Das Werk ist nicht freigegeben.');
      }
      final policy = _policy();
      final rules = _selectedRules();
      if (save) {
        await scope.settings.setOfflineConfiguration(
          _libraryId!,
          policy,
          rules,
        );
      }
      final plan = await scope.offline.preview(
        policyOverride: policy,
        rulesOverride: rules,
      );
      if (save) await scope.offline.run(force: true);
      if (mounted) setState(() => _plan = plan);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _ruleTitle(OfflineRule rule) {
    final scope = widget.scope;
    if (rule.scope == OfflineRuleScope.work) {
      return scope.library.workById(rule.targetId)?.title;
    }
    final shelf = _shelves
        .where((view) => view.id == rule.targetId)
        .firstOrNull;
    if (shelf == null ||
        LibraryWorkSearch.apply(
          scope.library.works.map((work) => work.summary).toList(),
          shelf.query,
        ).isEmpty) {
      return null;
    }
    return 'Regal: ${shelf.name}';
  }

  Future<void> _addShelf() async {
    final scope = widget.scope;
    await _loadingShelves;
    if (!mounted) return;
    List<LibrarySavedView> shelves() => [
      for (final shelf in _shelves)
        if (LibraryWorkSearch.apply(
          scope.library.works.map((work) => work.summary).toList(),
          shelf.query,
        ).isNotEmpty)
          shelf,
    ];
    final selected = await showDialog<LibrarySavedView>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: scope.library,
        builder: (_, _) {
          final visible = shelves();
          return AlertDialog(
            title: const Text('Gespeichertes Regal wählen'),
            content: SizedBox(
              width: FundusSpace.x16 * 5,
              height: FundusSpace.x16 * 5,
              child: visible.isEmpty
                  ? const Text(
                      'Noch kein gespeichertes Regal mit sichtbaren Werken vorhanden.',
                    )
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, index) => ListTile(
                        title: Text(visible[index].name),
                        onTap: () => Navigator.pop(context, visible[index]),
                      ),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen'),
              ),
            ],
          );
        },
      ),
    );
    if (selected == null || !mounted) return;
    final rule = OfflineRule(
      scope: OfflineRuleScope.shelf,
      targetId: selected.id,
      nextFiles: int.tryParse(_count.text) ?? 3,
    );
    setState(() {
      _rules.removeWhere((old) => old.key == rule.key);
      _rules.add(rule);
      _plan = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = widget.scope;
    final visibleRules = _rules
        .where((rule) => _ruleTitle(rule) != null)
        .toList();
    final files =
        _plan?.files
            .where((file) => scope.library.workById(file.workId) != null)
            .toList() ??
        const <OfflinePlannedFile>[];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(FundusSpace.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Automatisch mitnehmen',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text(
                'Nur bei geöffneter App. Regeln gelten auf diesem Gerät. EPUB/CBZ werden als ganze Dateien geladen, nicht als einzelne enthaltene Kapitel. Originale werden niemals entfernt.',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Automatik aktivieren'),
                value: _enabled,
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _enabled = value;
                        _plan = null;
                      }),
              ),
              TextField(
                controller: _count,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Dateien voraus (1–500)',
                ),
              ),
              const SizedBox(height: FundusSpace.x3),
              TextField(
                controller: _budget,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Gesamtes Offline-Budget in MiB',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Nur ungetaktetes WLAN'),
                subtitle: const Text(
                  'Kann das System WLAN nicht bestätigen, wird gewartet.',
                ),
                value: _wifi,
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _wifi = value;
                        _plan = null;
                      }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Nur während des Ladens'),
                value: _charging,
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _charging = value;
                        _plan = null;
                      }),
              ),
              if (widget.workId != null &&
                  scope.library.workById(widget.workId!) != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'Werk: ${scope.library.workById(widget.workId!)!.title}',
                  ),
                  value: _workSelected,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _workSelected = value;
                          _plan = null;
                        }),
                ),
              if (widget.workId == null) ...[
                TextButton(
                  onPressed: _busy ? null : _addShelf,
                  child: const Text('Regel für gespeichertes Regal hinzufügen'),
                ),
                if (visibleRules.isNotEmpty)
                  SizedBox(
                    height: FundusSpace.x16 * 3,
                    child: ListView.builder(
                      itemCount: visibleRules.length,
                      itemBuilder: (_, index) {
                        final rule = visibleRules[index];
                        return ListTile(
                          title: Text(_ruleTitle(rule) ?? ''),
                          subtitle: Text('${rule.nextFiles} Dateien voraus'),
                          trailing: IconButton(
                            tooltip: 'Regel entfernen',
                            icon: Icon(FundusIcons.close),
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _rules.removeWhere(
                                      (old) => old.key == rule.key,
                                    );
                                    _plan = null;
                                  }),
                          ),
                        );
                      },
                    ),
                  ),
              ],
              if (_error != null)
                Text(_error!, style: TextStyle(color: context.fundus.danger)),
              if (_plan != null) ...[
                Text(
                  '${files.length} Dateien · ${formatBytes(files.fold(0, (sum, file) => sum + file.track.sizeBytes))}',
                ),
                for (final reason
                    in _plan!.deferred.entries
                        .where(
                          (entry) => scope.library.workById(entry.key) != null,
                        )
                        .take(20))
                  Text(
                    '${scope.library.workById(reason.key)!.title}: ${offlineDeferralLabel(reason.value)}',
                  ),
                if (files.isNotEmpty)
                  TextButton(
                    onPressed: () => _showFiles(context, scope, files),
                    child: const Text('Dateiliste anzeigen'),
                  ),
              ],
              Wrap(
                spacing: FundusSpace.x3,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _perform(),
                    child: const Text('Vorschau'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _perform(save: true),
                    child: Text(
                      _busy ? 'Bitte warten …' : 'Speichern und prüfen',
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Schließen'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String offlineDeferralLabel(OfflineDeferral reason) => switch (reason) {
  OfflineDeferral.disabled => 'Automatik ausgeschaltet',
  OfflineDeferral.background => 'App nicht im Vordergrund',
  OfflineDeferral.wifiRequired => 'Wartet auf bestätigtes ungetaktetes WLAN',
  OfflineDeferral.chargingRequired => 'Wartet auf bestätigten Ladestatus',
  OfflineDeferral.positionUnavailable => 'Gewählte Datei nicht mehr verfügbar',
  OfflineDeferral.sizeUnknown => 'Dateigröße noch nicht bekannt',
  OfflineDeferral.budgetExceeded => 'Offline-Budget erreicht',
};

Future<void> _showFiles(
  BuildContext context,
  FundusScopeState scope,
  List<OfflinePlannedFile> files,
) => showDialog<void>(
  context: context,
  builder: (context) => AnimatedBuilder(
    animation: scope.library,
    builder: (_, _) {
      final visible = files
          .where((file) => scope.library.workById(file.workId) != null)
          .toList();
      return AlertDialog(
        title: const Text('Geplante Dateien'),
        content: SizedBox(
          width: FundusSpace.x16 * 5,
          height: FundusSpace.x16 * 6,
          child: ListView.builder(
            itemCount: visible.length,
            itemBuilder: (_, index) {
              final file = visible[index];
              return ListTile(
                title: Text(file.track.title),
                subtitle: Text(
                  '${scope.library.workById(file.workId)!.title} · ${formatBytes(file.track.sizeBytes)}${file.isContainer ? ' · vollständiger Container' : ''}',
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Schließen'),
          ),
        ],
      );
    },
  ),
);
