import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/fundus_log.dart';
import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';
import 'settings_shell.dart';

/// Die Wartungsseite: was da ist, was gerade läuft, was zu tun wäre.
///
/// Sie erfindet nichts. Jede Zahl hier kommt aus dem Katalog, dem Protokoll
/// oder dem Dateisystem — eine Wartungsseite, die schätzt, ist schlimmer als
/// keine, weil man ihr dann bei der einen Zahl nicht glaubt, auf die es
/// ankommt.
class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key});

  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends State<MaintenancePage> {
  List<({String kind, int works, int files, int bytes})> _stock = const [];
  ({int missingFiles, int emptyWorks}) _orphans = (
    missingFiles: 0,
    emptyWorks: 0,
  );
  int _catalogueBytes = 0;
  int? _cacheBytes;
  String? _message;
  bool _working = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _readCatalogue();
    if (_cacheBytes == null) unawaited(_measureCache());
  }

  /// Liest die Zahlen aus dem Katalog. Alles davon ist eine Abfrage, keine
  /// Wanderung durch Ordner — deshalb darf es beim Aufbauen passieren.
  void _readCatalogue() {
    final vault = FundusScope.of(context).library.library;
    if (vault == null) return;
    try {
      _stock = vault.storageByKind();
      _orphans = vault.orphanCount();
      _catalogueBytes = vault.catalogueBytes();
    } on Object {
      // Eine Bibliothek, die gerade neu geöffnet wird, antwortet kurz nicht.
    }
  }

  Future<Directory> _cacheRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'peer-cache'));
  }

  /// Misst den Zwischenspeicher, und macht kein Drama daraus, wenn es nicht
  /// geht: eine Zahl, die niemand messen konnte, ist ein Achselzucken wert.
  Future<void> _measureCache() async {
    var total = 0;
    try {
      final room = await _cacheRoot();
      if (await room.exists()) {
        await for (final entity in room.list(recursive: true)) {
          if (entity is File) total += await entity.length();
        }
      }
    } on Object {
      total = 0;
    }
    if (!mounted) return;
    setState(() => _cacheBytes = total);
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final vault = scope.library.library;
    final log = FundusLog.instance;
    final since = DateTime.now().subtract(const Duration(hours: 24));
    final recent = [
      for (final entry in log.entries)
        if (entry.at.isAfter(since)) entry,
    ];
    final loud = [
      for (final entry in recent)
        if (entry.level == LogLevel.warn || entry.level == LogLevel.error)
          entry,
    ];

    return SettingsPage(
      title: 'Serverwartung',
      subtitle:
          'Was der Bestand belegt, was gerade läuft und was sich aufräumen '
          'lässt. Nichts davon ist unersetzlich.',
      children: [
        _Situation(warnings: loud.length, entries: recent.length),
        _Stock(
          groups: _stock,
          catalogueBytes: _catalogueBytes,
          cacheBytes: _cacheBytes,
          offlineBytes: scope.downloads.storedBytes,
        ),
        const _Running(),
        const _Passes(),
        _Tasks(
          orphans: _orphans,
          catalogueBytes: _catalogueBytes,
          cacheBytes: _cacheBytes,
          working: _working,
          message: _message,
          vault: vault,
          onClearCache: _clearCache,
          onRemoveOrphans: _removeOrphans,
          onCompact: _compact,
          onBackup: _backup,
        ),
        _Journal(entries: recent, loud: loud),
      ],
    );
  }

  Future<void> _clearCache() async {
    setState(() => _working = true);
    try {
      final room = await _cacheRoot();
      if (await room.exists()) await room.delete(recursive: true);
      if (!mounted) return;
      setState(() {
        _cacheBytes = 0;
        _message = 'Zwischenspeicher geleert.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Ging nicht: $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _removeOrphans() async {
    final vault = FundusScope.of(context).library.library;
    if (vault == null) return;
    final counted = _orphans;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verwaiste Einträge aufräumen'),
        content: Text(
          '${counted.missingFiles} Dateien, die es nicht mehr gibt, und die '
          'Werke, die danach leer zurückbleiben, werden aus dem Katalog '
          'entfernt. Was zu ihnen gehörte — Stand, Notizen, Schlagwörter — '
          'geht mit. Die Mediendateien selbst rührt das nicht an.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Aufräumen'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    setState(() => _working = true);
    final removed = vault.removeOrphans();
    FundusScope.of(context).library.refresh();
    if (!mounted) return;
    setState(() {
      _working = false;
      _message =
          '${removed.files} Dateien und ${removed.works} Werke aufgeräumt.';
      _readCatalogue();
    });
  }

  Future<void> _compact() async {
    final vault = FundusScope.of(context).library.library;
    if (vault == null) return;
    setState(() => _working = true);
    try {
      final result = vault.compactCatalogue();
      final freed = result.before - result.after;
      if (!mounted) return;
      setState(() {
        _message = freed > 0
            ? '${formatBytes(freed)} freigeräumt.'
            : 'Der Katalog war schon dicht.';
        _readCatalogue();
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Ging nicht: $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _backup() async {
    final vault = FundusScope.of(context).library.library;
    if (vault == null) return;
    final source = File(
      p.join(
        vault.root.path,
        FundusLibrary.metadataDirectoryName,
        FundusLibrary.databaseFileName,
      ),
    );
    if (!source.existsSync()) return;
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final target = await FilePicker.saveFile(
      dialogTitle: 'Katalog sichern',
      fileName: 'fundus-katalog-$stamp.db',
    );
    if (target == null || !mounted) return;
    setState(() => _working = true);
    try {
      await source.copy(target);
      if (!mounted) return;
      setState(() => _message = 'Katalog gesichert: ${p.basename(target)}');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Ging nicht: $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

/// Der eine Satz oben: läuft alles, oder gab es etwas.
class _Situation extends StatelessWidget {
  const _Situation({required this.warnings, required this.entries});

  final int warnings;
  final int entries;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final vault = scope.library.library;
    final calm = warnings == 0;

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                calm ? FundusIcons.check : FundusIcons.warning,
                size: FundusIcons.sizeMd,
                color: calm ? tokens.accent : tokens.danger,
              ),
              const SizedBox(width: FundusSpace.x3),
              Expanded(
                child: Text(
                  calm ? 'Alles läuft' : 'Es gab etwas',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: FundusSpace.x2),
          Text(
            calm
                ? 'Keine Warnung in den letzten 24 Stunden · '
                      '$entries Einträge im Protokoll.'
                : '$warnings ${warnings == 1 ? 'Warnung' : 'Warnungen'} in den '
                      'letzten 24 Stunden · nichts davon blockiert etwas.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          const SizedBox(height: FundusSpace.x4),
          SettingsFact('Werke im Katalog', '${scope.library.works.length}'),
          SettingsFact('Quellen', '${scope.library.sources.length}'),
          if (vault != null) SettingsFact('Ordner', vault.root.path),
        ],
      ),
    );
  }
}

/// Wohin die Terabyte gegangen sind.
class _Stock extends StatelessWidget {
  const _Stock({
    required this.groups,
    required this.catalogueBytes,
    required this.cacheBytes,
    required this.offlineBytes,
  });

  final List<({String kind, int works, int files, int bytes})> groups;
  final int catalogueBytes;
  final int? cacheBytes;
  final int offlineBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    // Werke derselben Art stehen unter derselben Zeile: „Serie" und „Anime"
    // sind zwei Arten im Katalog, aber eine Frage auf dieser Seite.
    final byType = <String, ({String label, int bytes, int works})>{};
    for (final group in groups) {
      final type = MediaTypes.forWorkKind(group.kind);
      final key = type?.id ?? group.kind;
      final before = byType[key];
      byType[key] = (
        label: type?.label ?? group.kind,
        bytes: (before?.bytes ?? 0) + group.bytes,
        works: (before?.works ?? 0) + group.works,
      );
    }
    final rows = byType.values.toList()
      ..sort((a, b) => b.bytes.compareTo(a.bytes));
    final total = rows.fold(0, (sum, row) => sum + row.bytes);
    final shades = <Color>[
      tokens.accent,
      tokens.accentTint(0.6),
      tokens.textMuted,
      tokens.accentTint(0.3),
      tokens.textFaint,
      tokens.divider,
    ];

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Speicher', style: theme.textTheme.titleMedium),
          const SizedBox(height: FundusSpace.x2),
          Text(
            total == 0
                ? 'Noch nichts eingelesen.'
                : '${formatBytes(total)} an Mediendateien im Katalog.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          if (total > 0) ...[
            const SizedBox(height: FundusSpace.x4),
            ClipRRect(
              borderRadius: FundusRadius.smAll,
              child: SizedBox(
                height: 10,
                child: Row(
                  children: [
                    for (var index = 0; index < rows.length; index++)
                      Expanded(
                        flex: rows[index].bytes < 1 ? 1 : rows[index].bytes,
                        child: ColoredBox(
                          color: shades[index % shades.length],
                          child: const SizedBox.expand(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: FundusSpace.x4),
            for (var index = 0; index < rows.length; index++)
              _StockRow(
                colour: shades[index % shades.length],
                label: rows[index].label,
                detail:
                    '${rows[index].works} '
                    '${rows[index].works == 1 ? 'Werk' : 'Werke'}',
                value: formatBytes(rows[index].bytes),
              ),
          ],
          const Divider(height: FundusSpace.x8),
          SettingsFact('Katalog', formatBytes(catalogueBytes)),
          SettingsFact(
            'Offline auf diesem Gerät',
            offlineBytes == 0 ? 'nichts' : formatBytes(offlineBytes),
          ),
          SettingsFact(
            'Zwischenspeicher',
            cacheBytes == null ? 'wird gemessen …' : formatBytes(cacheBytes!),
          ),
        ],
      ),
    );
  }
}

class _StockRow extends StatelessWidget {
  const _StockRow({
    required this.colour,
    required this.label,
    required this.detail,
    required this.value,
  });

  final Color colour;
  final String label;
  final String detail;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FundusSpace.x1),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: colour,
              borderRadius: FundusRadius.smAll,
            ),
          ),
          const SizedBox(width: FundusSpace.x3),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            detail,
            style: theme.textTheme.labelMedium?.copyWith(
              color: tokens.textFaint,
            ),
          ),
          const SizedBox(width: FundusSpace.x4),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// Was in diesem Moment arbeitet.
class _Running extends StatelessWidget {
  const _Running();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final lines = <Widget>[];

    if (scope.library.isScanning) {
      final visited = scope.library.scanProgress?.fileCount;
      lines.add(
        _RunningLine(
          title: scope.library.lastScanWasFull
              ? 'Bibliothek wird eingelesen'
              : 'Bibliothek wird geprüft',
          detail: visited == null ? 'läuft …' : '$visited Dateien gesehen',
        ),
      );
    }
    for (final job in scope.downloads.jobs) {
      lines.add(
        _RunningLine(
          title: job.title,
          detail: job.total == 0
              ? 'wird geholt'
              : '${job.done} von ${job.total} Dateien',
        ),
      );
    }
    if (scope.host.isRunning) {
      final devices = scope.host.pairedDevices.length;
      lines.add(
        _RunningLine(
          title: 'Freigabe im Netz',
          detail: devices == 0
              ? 'kein Gerät gekoppelt'
              : '$devices ${devices == 1 ? 'Gerät' : 'Geräte'} gekoppelt',
        ),
      );
    }

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Läuft gerade', style: theme.textTheme.titleMedium),
          const SizedBox(height: FundusSpace.x3),
          if (lines.isEmpty)
            Text(
              'Nichts. Der Server wartet.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.textMuted,
              ),
            )
          else
            ...lines,
        ],
      ),
    );
  }
}

class _RunningLine extends StatelessWidget {
  const _RunningLine({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            detail,
            style: theme.textTheme.labelMedium?.copyWith(
              color: tokens.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// Die Durchgänge: welche Quelle wann zuletzt gesprochen hat.
class _Passes extends StatelessWidget {
  const _Passes();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final vault = scope.library.library;
    final mirrored = scope.peerLibraries.hasConnection;

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Durchgänge', style: theme.textTheme.titleMedium),
          const SizedBox(height: FundusSpace.x2),
          Text(
            mirrored
                ? 'Diese Bibliothek ist gespiegelt — eingelesen wird sie auf '
                      'dem Gerät, dem sie gehört. Hier wird der Katalog neu '
                      'geholt.'
                : 'Eingelesen wird beim Start und wenn du es hier sagst. '
                      'Geprüft wird dabei nur, was sich geändert hat.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          const SizedBox(height: FundusSpace.x4),
          for (final source in scope.library.sources)
            _RunningLine(
              title: source.displayName,
              detail: switch (source.status) {
                LibrarySourceStatus.available => 'erreichbar',
                LibrarySourceStatus.unreachable => 'antwortet nicht',
                LibrarySourceStatus.unknown => 'noch nicht gefragt',
              },
            ),
          const SizedBox(height: FundusSpace.x4),
          if (mirrored)
            FilledButton.tonalIcon(
              onPressed: scope.peerLibraries.isBusy
                  ? null
                  : scope.peerLibraries.refresh,
              icon: Icon(FundusIcons.sync, size: FundusIcons.sizeSm),
              label: const Text('Katalog holen'),
            )
          else
            FilledButton.tonalIcon(
              onPressed: scope.library.isScanning || vault == null
                  ? null
                  : scope.library.scan,
              icon: Icon(FundusIcons.sync, size: FundusIcons.sizeSm),
              label: Text(
                scope.library.isScanning ? 'Läuft …' : 'Jetzt einlesen',
              ),
            ),
        ],
      ),
    );
  }
}

/// Die Aufgaben, die man von Hand anstößt.
class _Tasks extends StatelessWidget {
  const _Tasks({
    required this.orphans,
    required this.catalogueBytes,
    required this.cacheBytes,
    required this.working,
    required this.message,
    required this.vault,
    required this.onClearCache,
    required this.onRemoveOrphans,
    required this.onCompact,
    required this.onBackup,
  });

  final ({int missingFiles, int emptyWorks}) orphans;
  final int catalogueBytes;
  final int? cacheBytes;
  final bool working;
  final String? message;
  final FundusLibrary? vault;
  final Future<void> Function() onClearCache;
  final Future<void> Function() onRemoveOrphans;
  final Future<void> Function() onCompact;
  final Future<void> Function() onBackup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final stray = orphans.missingFiles + orphans.emptyWorks;

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Aufgaben', style: theme.textTheme.titleMedium),
          const SizedBox(height: FundusSpace.x2),
          Text(
            'Keine davon läuft von selbst, und keine ist eilig.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          const SizedBox(height: FundusSpace.x4),
          _Task(
            icon: FundusIcons.warning,
            title: 'Verwaiste Einträge aufräumen',
            body: stray == 0
                ? 'Der Katalog zeigt auf nichts, das es nicht gibt.'
                : '${orphans.missingFiles} Dateien fehlen, '
                      '${orphans.emptyWorks} Werke stehen ohne Datei da.',
            action: 'Aufräumen',
            loud: stray > 0,
            onPressed: working || stray == 0 || vault == null
                ? null
                : onRemoveOrphans,
          ),
          _Task(
            icon: FundusIcons.downloads,
            title: 'Katalog sichern',
            body:
                'Stände, Notizen, Zuordnungen — ohne die Mediendateien. '
                '${formatBytes(catalogueBytes)}.',
            action: 'Sichern',
            onPressed: working || vault == null ? null : onBackup,
          ),
          _Task(
            icon: FundusIcons.folder,
            title: 'Katalog verdichten',
            body:
                'Gelöschte Zeilen geben ihren Platz nicht von selbst zurück. '
                'Der Server bleibt dabei erreichbar.',
            action: 'Verdichten',
            onPressed: working || vault == null ? null : onCompact,
          ),
          _Task(
            icon: FundusIcons.sync,
            title: 'Zwischenspeicher leeren',
            body:
                'Seiten und Dateien, die zum Lesen von einem gekoppelten '
                'Gerät geholt wurden. Heruntergeladene Werke gehören nicht '
                'dazu — die bleiben. '
                '${cacheBytes == null ? '' : formatBytes(cacheBytes!)}',
            action: 'Leeren',
            onPressed: working || (cacheBytes ?? 0) == 0 ? null : onClearCache,
          ),
          if (message case final said?) ...[
            const SizedBox(height: FundusSpace.x2),
            Text(
              said,
              style: theme.textTheme.bodyMedium?.copyWith(color: tokens.accent),
            ),
          ],
        ],
      ),
    );
  }
}

class _Task extends StatelessWidget {
  const _Task({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onPressed,
    this.loud = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;
  final bool loud;
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: FundusIcons.sizeMd,
            color: loud ? tokens.danger : tokens.textFaint,
          ),
          const SizedBox(width: FundusSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                Text(
                  body,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: FundusSpace.x3),
          OutlinedButton(
            onPressed: onPressed == null ? null : () => onPressed!(),
            child: Text(action),
          ),
        ],
      ),
    );
  }
}

/// Das Protokoll der letzten 24 Stunden, kurz gefasst.
class _Journal extends StatelessWidget {
  const _Journal({required this.entries, required this.loud});

  final List<LogEntry> entries;
  final List<LogEntry> loud;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final shown = (loud.isEmpty ? entries : loud).reversed.take(8).toList();

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Protokoll', style: theme.textTheme.titleMedium),
          const SizedBox(height: FundusSpace.x2),
          Text(
            'Letzte 24 Stunden · ${entries.length} Einträge, '
            '${loud.length} davon laut. Alles steht unter „Diagnose & '
            'Logging".',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          const SizedBox(height: FundusSpace.x4),
          if (shown.isEmpty)
            Text(
              'Noch nichts aufgeschrieben.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.textFaint,
              ),
            )
          else
            for (final entry in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: FundusSpace.x2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(
                        entry.at.toLocal().toIso8601String().substring(11, 16),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: tokens.textFaint,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        entry.event,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color:
                              entry.level == LogLevel.warn ||
                                  entry.level == LogLevel.error
                              ? tokens.danger
                              : tokens.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
