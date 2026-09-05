import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../app/pairing_scanner.dart';
import '../../data/media_type.dart';
import '../../media/comic_layout.dart';
import '../../data/protection.dart';
import '../../data/work_filter.dart';
import '../../data/server_host.dart';
import '../library/unassigned_folders_card.dart';
import '../../media/playback_preference.dart';
import 'settings_catalog.dart';

/// Settings, with the scope of each one visible.
///
/// The categories and their order come from the design; areas that only
/// arrive with a later slice say so plainly instead of showing controls that
/// do nothing.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.category});

  /// Null shows the overview rather than an area chosen for the person.
  final String? category;

  @override
  Widget build(BuildContext context) {
    return switch (category) {
      null => const _Index(),
      'darstellung' => const _Appearance(),
      'wiedergabe' => const _Playback(),
      'reader' => const _Reader(),
      'suche' => const _Search(),
      'wartung' => const _Maintenance(),
      'bibliotheken' => const _Libraries(),
      'synchronisation' => const _Sync(),
      'schutz' => const _Protection(),
      'diagnose' => const _Diagnostics(),
      _ => _Unknown(category: category!),
    };
  }
}

/// Every area, one tap away.
///
/// The navigation column carries this list on a desktop. A phone has no
/// column, so without this the settings were whichever area happened to be
/// the default — and nothing else was reachable at all.
class _Index extends StatelessWidget {
  const _Index();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;

    return _SettingsPage(
      title: 'Einstellungen',
      subtitle:
          'Was hier steht, gilt für dieses Gerät. Was zur Bibliothek gehört, '
          'steht unter „Bibliotheken".',
      children: [
        for (final area in SettingsAreas.all)
          _Card(
            child: InkWell(
              borderRadius: FundusRadius.mdAll,
              onTap: () =>
                  scope.navigation.go(SettingsRoute(category: area.key)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: FundusSpace.x2),
                child: Row(
                  children: [
                    Icon(
                      area.icon,
                      size: FundusIcons.sizeLg,
                      color: tokens.textMuted,
                    ),
                    const SizedBox(width: FundusSpace.x4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(area.label, style: theme.textTheme.titleSmall),
                          const SizedBox(height: FundusSpace.x1),
                          Text(
                            area.description,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: tokens.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      FundusIcons.forward,
                      size: FundusIcons.sizeMd,
                      color: tokens.textFaint,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return ListView(
      padding: const EdgeInsets.all(FundusSpace.x10),
      children: [
        Text(title, style: Theme.of(context).textTheme.displayMedium),
        const SizedBox(height: FundusSpace.x2),
        Text(
          subtitle,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: tokens.textMuted),
        ),
        const SizedBox(height: FundusSpace.x8),
        ...children,
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Container(
      margin: const EdgeInsets.only(bottom: FundusSpace.x4),
      padding: const EdgeInsets.all(FundusSpace.x6),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: FundusRadius.lgAll,
        border: Border.fromBorderSide(BorderSide(color: tokens.divider)),
      ),
      child: child,
    );
  }
}

class _Appearance extends StatelessWidget {
  const _Appearance();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;

    return _SettingsPage(
      title: 'Darstellung',
      subtitle:
          'Gilt für dieses Gerät. Die Werte reisen mit der Bibliothek, '
          'damit eine Neuinstallation sie nicht kostet.',
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Thema', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: FundusSpace.x3),
              SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dunkel')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Hell')),
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ],
                selected: {scope.settings.themeMode},
                onSelectionChanged: (value) => scope.setThemeMode(value.first),
              ),
            ],
          ),
        ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Dichte', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Kompakt zeigt mehr Werke gleichzeitig und verkleinert Zeilen '
                'und Kacheln.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
              ),
              const SizedBox(height: FundusSpace.x3),
              SegmentedButton<FundusDensity>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: FundusDensity.comfortable,
                    label: Text('Komfortabel'),
                  ),
                  ButtonSegment(
                    value: FundusDensity.compact,
                    label: Text('Kompakt'),
                  ),
                ],
                selected: {scope.settings.density},
                onSelectionChanged: (value) => scope.setDensity(value.first),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Libraries extends StatelessWidget {
  const _Libraries();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final sources = scope.library.sources;

    return _SettingsPage(
      title: 'Bibliotheken',
      subtitle:
          'Die geöffnete Bibliothek ist selbst eine Quelle — gekoppelte Server '
          'erscheinen später in derselben Liste.',
      children: [
        const UnassignedFoldersCard(),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Medienordner',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Eingelesen wird nur, was unter diesen Ordnernamen liegt. '
                'Die Zuordnung steht in der Bibliothek und gilt auf jedem '
                'Gerät.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
              ),
              const SizedBox(height: FundusSpace.x4),
              for (final entry in _mediaRoots(scope))
                Padding(
                  padding: const EdgeInsets.only(bottom: FundusSpace.x2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 190,
                        child: Text(
                          entry.$1,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: tokens.textFaint),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          entry.$2,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        for (final source in sources)
          _Card(
            child: Row(
              children: [
                FundusOriginMark(
                  source.status == LibrarySourceStatus.available
                      ? FundusOrigin.local
                      : FundusOrigin.unreachable,
                ),
                const SizedBox(width: FundusSpace.x4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.displayName,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        source.vaultPath ?? source.baseUrl ?? '',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: tokens.textFaint),
                      ),
                    ],
                  ),
                ),
                FundusTag(
                  source.isVault ? 'Bibliothek' : 'Server',
                  tone: FundusTagTone.outline,
                ),
              ],
            ),
          ),
        _Card(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Neu einlesen',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      'Der Scan ist unterbrechbar und läuft weiter, wenn man '
                      'die Ansicht wechselt.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
                    ),
                  ],
                ),
              ),
              FilledButton(
                onPressed: scope.library.isScanning
                    ? scope.library.cancelScan
                    : scope.library.scan,
                child: Text(scope.library.isScanning ? 'Abbrechen' : 'Scannen'),
              ),
            ],
          ),
        ),
        _Card(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Bibliothek schließen und eine andere öffnen.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              OutlinedButton(
                onPressed: () {
                  scope.library.close();
                  scope.navigation.reset(const VaultRoute());
                },
                child: const Text('Wechseln'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The configured media roots, as area label and folder names.
List<(String, String)> _mediaRoots(FundusScopeState scope) {
  final library = scope.library.library;
  if (library == null) return const [];
  final entries = <(String, String)>[];
  for (final type in MediaTypes.all) {
    final kind = type.configurationKind;
    if (kind == null) continue;
    final roots = library.configuration.rootsFor(kind);
    if (roots.isEmpty) continue;
    entries.add((type.label, roots.join(' · ')));
  }
  return entries;
}

class _Diagnostics extends StatelessWidget {
  const _Diagnostics();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final library = scope.library.library;

    return _SettingsPage(
      title: 'Diagnose & Logging',
      subtitle:
          'Ohne absolute Medienpfade — Protokolle verlassen das Gerät '
          'nur, wenn du sie exportierst.',
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Fact('Bibliothek', library?.root.path ?? '—'),
              _Fact(
                'Formatversion',
                '${library?.manifest.formatVersion ?? '—'}',
              ),
              _Fact('Schemaversion', '${FundusDatabase.schemaVersion}'),
              _Fact('Werke', '${scope.library.works.length}'),
              _Fact('Quellen', '${scope.library.sources.length}'),
            ],
          ),
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.textFaint),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Speed, skip distances and the sleep timer.
///
/// All three are habits rather than properties of a work — someone who
/// listens at 1.4× listens to everything at 1.4× — so they are kept per
/// device, in the vault, where a reinstall cannot take them.
class _Playback extends StatelessWidget {
  const _Playback();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    final habits = player.habits;
    final theme = Theme.of(context);
    final tokens = context.fundus;

    return _SettingsPage(
      title: 'Wiedergabe',
      subtitle:
          'Gilt für dieses Gerät und liegt bei der Bibliothek — nach einer '
          'Neuinstallation ist es wieder da.',
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Geschwindigkeit', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x3),
              Wrap(
                spacing: FundusSpace.x2,
                runSpacing: FundusSpace.x2,
                children: [
                  for (final rate in PlaybackPreference.rates)
                    ChoiceChip(
                      selected: (habits.rate - rate).abs() < 0.001,
                      onSelected: (_) => player.setRate(rate),
                      label: Text('$rate×'),
                    ),
                ],
              ),
            ],
          ),
        ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sprungweiten', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Zurück meist kürzer als vor: man springt zurück, um etwas '
                'noch einmal zu hören, und vor, um etwas zu überspringen.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
              const SizedBox(height: FundusSpace.x4),
              Text('Zurück', style: theme.textTheme.labelLarge),
              const SizedBox(height: FundusSpace.x2),
              Wrap(
                spacing: FundusSpace.x2,
                runSpacing: FundusSpace.x2,
                children: [
                  for (final seconds in PlaybackPreference.skips)
                    ChoiceChip(
                      selected: habits.skipBack.inSeconds == seconds,
                      onSelected: (_) => scope.setPlaybackHabits(
                        habits.copyWith(skipBack: Duration(seconds: seconds)),
                      ),
                      label: Text('$seconds s'),
                    ),
                ],
              ),
              const SizedBox(height: FundusSpace.x4),
              Text('Vor', style: theme.textTheme.labelLarge),
              const SizedBox(height: FundusSpace.x2),
              Wrap(
                spacing: FundusSpace.x2,
                runSpacing: FundusSpace.x2,
                children: [
                  for (final seconds in PlaybackPreference.skips)
                    ChoiceChip(
                      selected: habits.skipForward.inSeconds == seconds,
                      onSelected: (_) => scope.setPlaybackHabits(
                        habits.copyWith(
                          skipForward: Duration(seconds: seconds),
                        ),
                      ),
                      label: Text('$seconds s'),
                    ),
                ],
              ),
            ],
          ),
        ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sleep-Timer', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Die Voreinstellung, wenn der Timer im Player ohne Auswahl '
                'gestartet wird.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
              const SizedBox(height: FundusSpace.x4),
              Wrap(
                spacing: FundusSpace.x2,
                runSpacing: FundusSpace.x2,
                children: [
                  for (final minutes in PlaybackPreference.sleepChoices)
                    ChoiceChip(
                      selected: habits.sleepTimer.inMinutes == minutes,
                      onSelected: (_) => scope.setPlaybackHabits(
                        habits.copyWith(sleepTimer: Duration(minutes: minutes)),
                      ),
                      label: Text('$minutes min'),
                    ),
                ],
              ),
              const SizedBox(height: FundusSpace.x3),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: habits.sleepAtChapterEnd,
                onChanged: (value) => scope.setPlaybackHabits(
                  habits.copyWith(sleepAtChapterEnd: value),
                ),
                title: const Text('Bis zum Kapitelende weiterlaufen'),
                subtitle: Text(
                  'Mitten im Satz aufzuhören spart vier Minuten und kostet '
                  'die Stelle, an der man eingeschlafen ist.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The protected shelf.
///
/// Two separate things, deliberately: whether protected works are hidden,
/// and whether this session is unlocked. The first is a setting; the second
/// happens once and lapses when the app closes, because a lock that stays
/// open is a decoration.
class _Protection extends StatefulWidget {
  const _Protection();

  @override
  State<_Protection> createState() => _ProtectionState();
}

class _ProtectionState extends State<_Protection> {
  final _pinController = TextEditingController();
  final _unlockController = TextEditingController();
  String? _complaint;

  @override
  void dispose() {
    _pinController.dispose();
    _unlockController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final protection = scope.protection;
    final theme = Theme.of(context);
    final tokens = context.fundus;

    return _SettingsPage(
      title: 'Schutzmodus',
      subtitle:
          'Gilt für dieses Gerät. Die PIN liegt hier und nicht in der '
          'Bibliothek — ein Bibliotheksordner wird geteilt, ein Schlüssel '
          'nicht.',
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Was verdeckt wird', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x3),
              RadioGroup<ProtectionMode>(
                groupValue: protection.mode,
                onChanged: (value) =>
                    value == null ? null : protection.setMode(value),
                child: Column(
                  children: [
                    for (final mode in ProtectionMode.values)
                      RadioListTile<ProtectionMode>(
                        contentPadding: EdgeInsets.zero,
                        value: mode,
                        title: Text(mode.label),
                        subtitle: Text(
                          mode.description,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.textMuted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('PIN', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x2),
              Text(
                protection.hasPin
                    ? 'Eine PIN ist gesetzt. Eine neue ersetzt sie; ein '
                          'leeres Feld nimmt sie weg.'
                    : 'Ohne PIN lässt sich der Schutz nur ein- und '
                          'ausschalten, nicht öffnen.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
              const SizedBox(height: FundusSpace.x4),
              Row(
                children: [
                  SizedBox(
                    width: 180,
                    child: TextField(
                      controller: _pinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Neue PIN'),
                    ),
                  ),
                  const SizedBox(width: FundusSpace.x4),
                  FilledButton(
                    onPressed: () async {
                      await protection.setPin(_pinController.text);
                      _pinController.clear();
                      setState(() => _complaint = null);
                    },
                    child: const Text('Übernehmen'),
                  ),
                  if (protection.hasPin) ...[
                    const SizedBox(width: FundusSpace.x3),
                    TextButton(
                      onPressed: () => protection.setPin(''),
                      child: const Text('PIN entfernen'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        if (protection.mode != ProtectionMode.off && protection.hasPin)
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Für diese Sitzung',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      protection.isUnlocked ? 'Entsperrt' : 'Gesperrt',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: protection.isUnlocked
                            ? tokens.success
                            : tokens.textFaint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: FundusSpace.x2),
                Text(
                  'Beim nächsten Start ist wieder zu — das ist der Sinn.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.textMuted,
                  ),
                ),
                const SizedBox(height: FundusSpace.x4),
                if (protection.isUnlocked)
                  OutlinedButton.icon(
                    onPressed: protection.lock,
                    icon: Icon(FundusIcons.protected, size: FundusIcons.sizeSm),
                    label: const Text('Jetzt sperren'),
                  )
                else
                  Row(
                    children: [
                      SizedBox(
                        width: 180,
                        child: TextField(
                          controller: _unlockController,
                          obscureText: true,
                          keyboardType: TextInputType.number,
                          onSubmitted: (_) => _unlock(protection),
                          decoration: const InputDecoration(labelText: 'PIN'),
                        ),
                      ),
                      const SizedBox(width: FundusSpace.x4),
                      FilledButton(
                        onPressed: () => _unlock(protection),
                        child: const Text('Entsperren'),
                      ),
                    ],
                  ),
                if (_complaint case final complaint?) ...[
                  const SizedBox(height: FundusSpace.x3),
                  Text(
                    complaint,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.danger,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  void _unlock(ProtectionController protection) {
    final opened = protection.unlock(_unlockController.text);
    setState(() => _complaint = opened ? null : 'Die PIN stimmt nicht.');
    if (opened) _unlockController.clear();
  }
}

/// What a reader starts with.
///
/// A work that has been read keeps its own setting — someone who reads one
/// series right to left does not want that for everything — so what is set
/// here is the starting point for works that have not been opened yet. It
/// lives in the vault, beside the per-work settings it stands in for.
class _Reader extends StatefulWidget {
  const _Reader();

  @override
  State<_Reader> createState() => _ReaderState();
}

class _ReaderState extends State<_Reader> {
  PublicationReaderProfile? _pages;
  ReflowReaderProfile? _text;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) unawaited(_load());
  }

  Future<void> _load() async {
    final vault = FundusScope.of(context).library.library;
    if (vault == null) {
      setState(() => _loading = false);
      return;
    }
    final pages = await vault.loadReaderProfile();
    final text = await vault.loadTextProfile();
    if (!mounted) return;
    setState(() {
      _pages = pages;
      _text = text;
      _loading = false;
    });
  }

  Future<void> _savePages(PublicationReaderProfile value) async {
    setState(() => _pages = value);
    await FundusScope.of(context).library.library?.saveReaderProfile(value);
  }

  Future<void> _saveText(ReflowReaderProfile value) async {
    setState(() => _text = value);
    await FundusScope.of(context).library.library?.saveTextProfile(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final pages = _pages;
    final text = _text;

    return _SettingsPage(
      title: 'Reader',
      subtitle:
          'Womit ein Werk aufgeht, das noch nie geöffnet wurde. Ein gelesenes '
          'Werk behält, was dort eingestellt wurde.',
      children: [
        if (_loading)
          const _Card(child: LinearProgressIndicator())
        else if (pages == null || text == null)
          _Card(
            child: Text(
              'Ohne geöffnete Bibliothek gibt es nichts einzustellen — die '
              'Voreinstellungen liegen bei der Bibliothek.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.textMuted,
              ),
            ),
          )
        else ...[
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Comics, Manga und Dokumente',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: FundusSpace.x4),
                _Choices(
                  label: 'Anzeige',
                  children: [
                    for (final layout in PublicationReaderLayout.values)
                      ChoiceChip(
                        selected: pages.layout == layout,
                        onSelected: (_) =>
                            _savePages(pages.copyWith(layout: layout)),
                        label: Text(layout.label),
                      ),
                  ],
                ),
                _Choices(
                  label: 'Leserichtung',
                  children: [
                    for (final direction in PublicationReadingDirection.values)
                      ChoiceChip(
                        selected: pages.readingDirection == direction,
                        onSelected: (_) => _savePages(
                          pages.copyWith(readingDirection: direction),
                        ),
                        label: Text(direction.label),
                      ),
                  ],
                ),
                _Choices(
                  label: 'Größe',
                  children: [
                    for (final scale in PublicationPageScale.values)
                      ChoiceChip(
                        selected: pages.pageScale == scale,
                        onSelected: (_) =>
                            _savePages(pages.copyWith(pageScale: scale)),
                        label: Text(scale.label),
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: pages.firstPageIsCover,
                  onChanged: (value) =>
                      _savePages(pages.copyWith(firstPageIsCover: value)),
                  title: const Text('Erste Seite ist das Cover'),
                  subtitle: Text(
                    'Sonst steht sie in der ersten Doppelseite.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.textMuted,
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: pages.invertTapZones,
                  onChanged: (value) =>
                      _savePages(pages.copyWith(invertTapZones: value)),
                  title: const Text('Tippbereiche vertauschen'),
                  subtitle: Text(
                    'Für Linkshänder oder für Leserichtungen, die sich falsch '
                    'anfühlen.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bücher und Light Novels',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: FundusSpace.x4),
                _Choices(
                  label: 'Schrift',
                  children: [
                    for (final family in ReflowFontFamily.values)
                      ChoiceChip(
                        selected: text.fontFamily == family,
                        onSelected: (_) =>
                            _saveText(text.copyWith(fontFamily: family)),
                        label: Text(_fontLabel(family)),
                      ),
                  ],
                ),
                _Choices(
                  label: 'Grund',
                  children: [
                    for (final ground in ReflowTheme.values)
                      ChoiceChip(
                        selected: text.theme == ground,
                        onSelected: (_) =>
                            _saveText(text.copyWith(theme: ground)),
                        label: Text(_groundLabel(ground)),
                      ),
                  ],
                ),
                const SizedBox(height: FundusSpace.x3),
                Text('Schriftgröße', style: theme.textTheme.labelLarge),
                Slider(
                  value: text.fontSize,
                  min: 13,
                  max: 32,
                  divisions: 19,
                  label: '${text.fontSize.round()} pt',
                  onChanged: (value) =>
                      setState(() => _text = text.copyWith(fontSize: value)),
                  onChangeEnd: (value) =>
                      _saveText(text.copyWith(fontSize: value)),
                ),
                Text('Zeilenabstand', style: theme.textTheme.labelLarge),
                Slider(
                  value: text.lineHeight,
                  min: 1.2,
                  max: 2.2,
                  divisions: 10,
                  label: text.lineHeight.toStringAsFixed(2),
                  onChanged: (value) =>
                      setState(() => _text = text.copyWith(lineHeight: value)),
                  onChangeEnd: (value) =>
                      _saveText(text.copyWith(lineHeight: value)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String _fontLabel(ReflowFontFamily family) => switch (family) {
    ReflowFontFamily.system => 'System',
    ReflowFontFamily.serif => 'Serif',
    ReflowFontFamily.sansSerif => 'Serifenlos',
    ReflowFontFamily.monospace => 'Feste Breite',
  };

  static String _groundLabel(ReflowTheme ground) => switch (ground) {
    ReflowTheme.followApp => 'Wie die App',
    ReflowTheme.paper => 'Papier',
    ReflowTheme.sepia => 'Sepia',
    ReflowTheme.night => 'Nacht',
  };
}

/// A labelled row of choices, as the reader's own sheet lays them out.
class _Choices extends StatelessWidget {
  const _Choices({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FundusSpace.x4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: FundusSpace.x2),
        Wrap(
          spacing: FundusSpace.x2,
          runSpacing: FundusSpace.x2,
          children: children,
        ),
      ],
    ),
  );
}

/// Saved views — a filter given a name.
///
/// What is saved is what is *filtered*: the area, the origin, the sort and
/// the search text. Not „Ordnen nach": that is a toggle people flip while
/// looking at something, not part of what they were looking for. The views
/// live in the vault, so they are the same on every device that opens it.
class _Search extends StatefulWidget {
  const _Search();

  @override
  State<_Search> createState() => _SearchState();
}

class _SearchState extends State<_Search> {
  final _nameController = TextEditingController();
  List<LibrarySavedView>? _views;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_views == null) unawaited(_load());
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final vault = FundusScope.of(context).library.library;
    final views = await vault?.loadSavedViews() ?? const <LibrarySavedView>[];
    if (!mounted) return;
    setState(() => _views = views);
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final views = _views;
    final filter = scope.filter;

    return _SettingsPage(
      title: 'Suche & Filter',
      subtitle:
          'Eine Ansicht ist ein Filter mit einem Namen. Sie liegt bei der '
          'Bibliothek, gilt also auf jedem Gerät, das sie öffnet.',
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Aktuelle Ansicht sichern',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: FundusSpace.x2),
              Text(
                _describe(filter),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
              const SizedBox(height: FundusSpace.x4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Name der Ansicht',
                      ),
                    ),
                  ),
                  const SizedBox(width: FundusSpace.x4),
                  FilledButton(
                    onPressed: () async {
                      final name = _nameController.text.trim();
                      if (name.isEmpty) return;
                      final vault = scope.library.library;
                      if (vault == null) return;
                      final saved = await vault.saveView(
                        name,
                        scope.filter.toQuery(),
                      );
                      _nameController.clear();
                      if (!mounted) return;
                      setState(() => _views = saved);
                    },
                    child: const Text('Sichern'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Gespeicherte Ansichten',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: FundusSpace.x3),
              if (views == null)
                const LinearProgressIndicator()
              else if (views.isEmpty)
                Text(
                  'Noch keine. Stelle in der Bibliothek ein, was du sehen '
                  'willst, und sichere es hier unter einem Namen.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: tokens.textFaint,
                  ),
                )
              else
                for (final view in views)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      FundusIcons.filter,
                      size: FundusIcons.sizeMd,
                      color: tokens.textMuted,
                    ),
                    title: Text(view.name),
                    subtitle: Text(
                      _describeQuery(view.query),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: tokens.textFaint,
                      ),
                    ),
                    onTap: () => scope.applySavedView(view),
                    trailing: IconButton(
                      onPressed: () async {
                        final vault = scope.library.library;
                        if (vault == null) return;
                        final left = await vault.deleteSavedView(view.id);
                        if (!mounted) return;
                        setState(() => _views = left);
                      },
                      icon: Icon(FundusIcons.close, size: FundusIcons.sizeMd),
                      tooltip: 'Ansicht löschen',
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  static String _describe(WorkFilter filter) {
    final parts = <String>[
      if (filter.mediaTypeId case final id?)
        MediaTypes.byId(id)?.label ?? id
      else
        'Alle Werke',
      if (filter.text.isNotEmpty) 'Suche „${filter.text}"',
      if (filter.origins.isNotEmpty)
        filter.origins.map((origin) => origin.label).join(', '),
      filter.sort.label,
    ];
    return parts.join(' · ');
  }

  static String _describeQuery(LibraryWorkQuery query) {
    final parts = <String>[
      if (query.text.isNotEmpty) 'Suche „${query.text}"',
      if (query.kinds.isNotEmpty)
        MediaTypes.all
            .where(
              (type) => type.workKinds.intersection(query.kinds).isNotEmpty,
            )
            .map((type) => type.label)
            .join(', ')
            .toString(),
      if (query.offlineOnly) 'Offline gesichert',
    ];
    return parts.isEmpty ? 'Alles' : parts.join(' · ');
  }
}

/// What the shared side costs and what to do about it.
///
/// „Wartung" here means the two things that actually accumulate: the copies
/// fetched for reading, and the index of a paired library. Neither holds
/// anything irreplaceable — that is the point of showing them together with
/// a way to throw them away.
class _Maintenance extends StatefulWidget {
  const _Maintenance();

  @override
  State<_Maintenance> createState() => _MaintenanceState();
}

class _MaintenanceState extends State<_Maintenance> {
  int? _cacheBytes;
  bool _working = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cacheBytes == null) unawaited(_measure());
  }

  Future<Directory> _cacheRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'peer-cache'));
  }

  /// Measures the cache, and does not make a fuss if it cannot.
  ///
  /// Asking the platform where its storage is can fail — in a preview, in a
  /// test, on a system that answers differently. A number nobody could
  /// measure is worth a shrug, not an error screen over the settings.
  Future<void> _measure() async {
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
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final vault = scope.library.library;
    final peer = scope.peerLibrary.peer;

    return _SettingsPage(
      title: 'Serverwartung',
      subtitle:
          'Was sich mit der Zeit ansammelt, und wie man es wieder loswird. '
          'Nichts davon ist unersetzlich.',
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Zwischenspeicher', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Seiten und Dateien, die zum Lesen von einem gekoppelten '
                'Gerät geholt wurden. Heruntergeladene Werke gehören nicht '
                'dazu — die stehen unter „Downloads" und bleiben.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
              const SizedBox(height: FundusSpace.x4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _cacheBytes == null
                          ? 'wird gemessen …'
                          : _size(_cacheBytes!),
                      style: theme.textTheme.headlineMedium,
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _working || (_cacheBytes ?? 0) == 0
                        ? null
                        : () async {
                            setState(() => _working = true);
                            final room = await _cacheRoot();
                            if (await room.exists()) {
                              await room.delete(recursive: true);
                            }
                            if (!mounted) return;
                            setState(() {
                              _working = false;
                              _cacheBytes = 0;
                            });
                          },
                    child: const Text('Leeren'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Bestand', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x3),
              _Fact('Werke im Index', '${scope.library.works.length}'),
              _Fact('Quellen', '${scope.library.sources.length}'),
              if (peer != null) _Fact('Gespiegelt von', peer.name),
              if (vault != null) _Fact('Ordner', vault.root.path),
            ],
          ),
        ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Neu einlesen', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x2),
              Text(
                scope.peerLibrary.isOpen
                    ? 'Diese Bibliothek ist gespiegelt — eingelesen wird sie '
                          'auf dem Gerät, dem sie gehört. Hier wird der '
                          'Katalog neu geholt.'
                    : 'Liest den Bibliotheksordner erneut ein. Nötig, wenn '
                          'außerhalb von Fundus Dateien dazugekommen sind.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
              const SizedBox(height: FundusSpace.x4),
              if (scope.peerLibrary.isOpen)
                FilledButton.tonalIcon(
                  onPressed: scope.peerLibrary.isBusy
                      ? null
                      : scope.peerLibrary.refresh,
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
        ),
      ],
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['kB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
  }
}

/// A category nothing claims.
///
/// Every area in the catalogue has a page now, so this is reached only by an
/// address that was mistyped or one that used to exist. Saying so beats a
/// blank screen.
class _Unknown extends StatelessWidget {
  const _Unknown({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) => _SettingsPage(
    title: 'Einstellungen',
    subtitle: 'Den Bereich „$category" gibt es nicht.',
    children: const [],
  );
}

/// This device, the devices it is connected to, and the door between them.
///
/// One page rather than two: a device that is only named and a device that is
/// connected are the same device, and splitting them meant one screen showed
/// half the story while the other announced the rest as planned.
class _Sync extends StatefulWidget {
  const _Sync();

  @override
  State<_Sync> createState() => _SyncState();
}

class _SyncState extends State<_Sync> {
  final _codeController = TextEditingController();
  final _pinController = TextEditingController();
  final _nameController = TextEditingController();
  final _pinFocus = FocusNode();
  Future<List<DeviceProfile>>? _profiles;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = FundusScope.of(context);
    if (_nameController.text.isEmpty) {
      _nameController.text = scope.settings.deviceName;
    }
    // Created once: a future built inside build() restarts on every rebuild.
    _profiles ??= scope.library.library?.listDeviceProfiles();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _pinController.dispose();
    _nameController.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  /// Reads the code off the other screen and puts the cursor in the PIN field.
  ///
  /// The PIN stays out of the code on purpose — a code that carries it would
  /// make a photograph of the screen enough — so the scan ends one step short,
  /// and the least it can do is say which step.
  Future<void> _scan(PairingScanner scanner) async {
    final code = await scanner.scan(context);
    if (code == null || !mounted) return;
    _codeController.text = code;
    _pinFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final sync = scope.sync;
    final tokens = context.fundus;
    final theme = Theme.of(context);

    return _SettingsPage(
      title: 'Geräte & Abgleich',
      subtitle:
          'Zwei Geräte, dieselbe Bibliothek, derselbe Stand. Abgeglichen wird, '
          'was man mit sich trägt: wo man ist, und was man sich angestrichen '
          'hat. Dateien wandern nicht mit.',
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Dieses Gerät', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x3),
              // Saved as it is typed. It used to save on Enter only, and a
              // phone keyboard has a Done key most people never press — so
              // the name someone set before pairing was thrown away, and the
              // device turned up on the other side as „Android-Gerät".
              TextField(
                controller: _nameController,
                textInputAction: TextInputAction.done,
                onChanged: scope.settings.setDeviceName,
                decoration: const InputDecoration(labelText: 'Gerätename'),
              ),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Kennung ${scope.settings.deviceKey} · unter diesem Namen '
                'erscheint das Gerät auf der anderen Seite.',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: tokens.textFaint,
                ),
              ),
            ],
          ),
        ),
        _Sharing(host: scope.host),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Gerät koppeln', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Lass dir auf dem anderen Gerät den Kopplungscode zeigen — '
                'scanne den QR-Code oder füge den Text ein — und gib die '
                'sechsstellige PIN dazu ein. Der Code allein reicht nicht: wer '
                'ihn abfotografiert, hat noch keine Verbindung.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
              if (scope.scanner.isAvailable) ...[
                const SizedBox(height: FundusSpace.x4),
                FilledButton.tonalIcon(
                  onPressed: sync.isBusy ? null : () => _scan(scope.scanner),
                  icon: Icon(FundusIcons.scan, size: FundusIcons.sizeSm),
                  label: const Text('QR-Code scannen'),
                ),
              ],
              const SizedBox(height: FundusSpace.x4),
              TextField(
                controller: _codeController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Kopplungscode',
                  hintText: '{"type":"fundus_pairing", …}',
                ),
              ),
              const SizedBox(height: FundusSpace.x3),
              Row(
                children: [
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: _pinController,
                      focusNode: _pinFocus,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'PIN'),
                    ),
                  ),
                  const SizedBox(width: FundusSpace.x4),
                  FilledButton(
                    onPressed: sync.isBusy
                        ? null
                        : () async {
                            final paired = await sync.pair(
                              code: _codeController.text,
                              pin: _pinController.text,
                            );
                            if (!paired) return;
                            _codeController.clear();
                            _pinController.clear();
                          },
                    child: const Text('Koppeln'),
                  ),
                ],
              ),
              if (sync.failure case final failure?) ...[
                const SizedBox(height: FundusSpace.x3),
                Text(
                  failure,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: tokens.danger,
                  ),
                ),
              ],
            ],
          ),
        ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Verbundene Geräte',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (sync.peers.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: sync.isBusy ? null : sync.syncAll,
                      icon: Icon(FundusIcons.sync, size: FundusIcons.sizeSm),
                      label: const Text('Jetzt abgleichen'),
                    ),
                ],
              ),
              const SizedBox(height: FundusSpace.x3),
              if (sync.peers.isEmpty)
                Text(
                  'Noch keins. Ein gekoppeltes Gerät steht hier mit dem '
                  'Zeitpunkt seines letzten Abgleichs.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: tokens.textFaint,
                  ),
                )
              else
                for (final peer in sync.peers)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(peer.name),
                    subtitle: Text(
                      peer.lastSyncAt == null
                          ? peer.baseUrl
                          : '${peer.baseUrl} · zuletzt '
                                '${_when(peer.lastSyncAt!)}'
                                '${peer.lastResult == null ? '' : ' · ${peer.lastResult}'}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: sync.isBusy
                              ? null
                              : () => sync.syncWith(peer),
                          icon: Icon(
                            FundusIcons.sync,
                            size: FundusIcons.sizeMd,
                          ),
                          tooltip: 'Abgleichen',
                        ),
                        IconButton(
                          onPressed: () => sync.forget(peer.serverId),
                          icon: Icon(
                            FundusIcons.close,
                            size: FundusIcons.sizeMd,
                          ),
                          tooltip: 'Verbindung entfernen',
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: FundusSpace.x3),
              Text(
                'Das Zugangstoken liegt bei diesem Gerät, nicht in der '
                'Bibliothek — ein Bibliotheksordner wird geteilt, ein Schlüssel '
                'nicht. Eine Neuinstallation kostet daher die Kopplung.',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: tokens.textFaint,
                ),
              ),
            ],
          ),
        ),
        if (scope.peerLibrary.isOpen) _peerLibraryCard(context),
        _adoption(context),
      ],
    );
  }

  /// The paired library that is open, and the way to read it in again.
  ///
  /// The catalogue is a copy, so it goes out of date the moment the other
  /// machine scans. Fetching it again is one button rather than a rule about
  /// when to do it behind the person's back.
  Widget _peerLibraryCard(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final peer = scope.peerLibrary.peer;
    final mirror = scope.peerLibrary.lastMirror;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Geöffnete Fremdbibliothek',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              FundusConnectionDot(state: scope.peerLibrary.connection),
            ],
          ),
          const SizedBox(height: FundusSpace.x2),
          Text(
            'Der Katalog von „${peer?.name ?? ''}" liegt hier als Kopie — '
            'deshalb ist die Liste auch ohne Netz da. Die Dateien werden '
            'beim Abspielen geholt.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          if (mirror != null) ...[
            const SizedBox(height: FundusSpace.x2),
            // What the last pass *changed*, not how large the library is:
            // only what differs is fetched, so „0 geändert" is the normal
            // and the good answer.
            Text(
              mirror.written == 0 && mirror.removed == 0
                  ? 'Zuletzt: nichts zu holen, alles war aktuell'
                  : 'Zuletzt: ${mirror.written} Werke geholt'
                        '${mirror.removed == 0 ? '' : ', ${mirror.removed} entfallen'}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textFaint,
              ),
            ),
          ],
          const SizedBox(height: FundusSpace.x4),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: scope.peerLibrary.isBusy
                    ? null
                    : scope.peerLibrary.refresh,
                icon: Icon(FundusIcons.sync, size: FundusIcons.sizeSm),
                label: const Text('Katalog holen'),
              ),
              const SizedBox(width: FundusSpace.x3),
              TextButton(
                onPressed: scope.peerLibrary.isBusy
                    ? null
                    : scope.closePeerLibrary,
                child: const Text('Bibliothek schließen'),
              ),
            ],
          ),
          if (scope.peerLibrary.failure case final failure?) ...[
            const SizedBox(height: FundusSpace.x3),
            Text(
              failure,
              style: theme.textTheme.bodyMedium?.copyWith(color: tokens.danger),
            ),
          ],
        ],
      ),
    );
  }

  /// What the vault remembers of other devices.
  ///
  /// Not a sync — these settings never left the library folder. It is the
  /// answer to a reinstall: the reader settings are still lying there under
  /// another device's name, and this fetches them back.
  Widget _adoption(BuildContext context) {
    final profiles = _profiles;
    if (profiles == null) return const SizedBox.shrink();
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;

    return FutureBuilder<List<DeviceProfile>>(
      future: profiles,
      builder: (context, snapshot) {
        final others = (snapshot.data ?? const <DeviceProfile>[])
            .where((profile) => profile.key != scope.settings.deviceKey)
            .toList();
        if (others.isEmpty) return const SizedBox.shrink();
        return _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Einstellungen übernehmen',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Diese Bibliothek trägt Einstellungen anderer Geräte. Nach '
                'einer Neuinstallation lassen sie sich hier zurückholen — die '
                'Kennung bleibt dabei diese.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
              const SizedBox(height: FundusSpace.x4),
              for (final profile in others)
                Padding(
                  padding: const EdgeInsets.only(bottom: FundusSpace.x2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${profile.displayName}'
                          '${profile.platform.isEmpty ? '' : ' · ${profile.platform}'}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => scope.adoptDeviceProfile(profile),
                        child: const Text('Übernehmen'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _when(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}. ${two(local.hour)}:'
        '${two(local.minute)}';
  }
}

/// This device as the side that answers.
///
/// Two Fundus installations cannot both be only clients, so the same screen
/// carries both halves: below, the connections this device made; here, the
/// door it opens for the other one. It stays shut until it is opened.
class _Sharing extends StatelessWidget {
  const _Sharing({required this.host});

  final ServerHostController host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final session = host.pairingSession;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Dieses Gerät freigeben',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (host.isRunning) ...[
                FundusConnectionDot(
                  state: host.hasConnectedDevice
                      ? FundusConnectionState.connected
                      : FundusConnectionState.idle,
                  label: host.hasConnectedDevice ? 'Gerät verbunden' : 'Bereit',
                ),
                const SizedBox(width: FundusSpace.x4),
              ],
              Switch(
                value: host.isRunning,
                onChanged: host.isBusy
                    ? null
                    : (value) => host.setSharing(value),
              ),
            ],
          ),
          const SizedBox(height: FundusSpace.x2),
          Text(
            'Solange die Freigabe an ist, kann ein gekoppeltes Gerät im '
            'selben Netz die hier geöffnete Bibliothek erreichen. Die '
            'Verbindung ist verschlüsselt, und das Zertifikat steht im '
            'Kopplungscode — ein anderes wird nicht angenommen.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          if (host.failure case final failure?) ...[
            const SizedBox(height: FundusSpace.x3),
            Text(
              failure,
              style: theme.textTheme.bodyMedium?.copyWith(color: tokens.danger),
            ),
          ],
          if (host.isRunning) ...[
            const SizedBox(height: FundusSpace.x4),
            if (host.addresses.isEmpty)
              Text(
                'Dieses Gerät hat keine Netzwerkadresse, unter der es '
                'erreichbar wäre. Ohne WLAN oder Kabel gibt es nichts zu '
                'koppeln.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textFaint,
                ),
              )
            else ...[
              Text('Erreichbar unter', style: theme.textTheme.labelLarge),
              const SizedBox(height: FundusSpace.x2),
              Wrap(
                spacing: FundusSpace.x2,
                runSpacing: FundusSpace.x2,
                children: [
                  for (final address in host.addresses)
                    ChoiceChip(
                      selected: address == host.address,
                      onSelected: (_) => host.useAddress(address),
                      label: Text('${address.host}:${address.port}'),
                    ),
                ],
              ),
              const SizedBox(height: FundusSpace.x4),
              if (session == null)
                OutlinedButton.icon(
                  onPressed: host.beginPairing,
                  icon: Icon(FundusIcons.devices, size: FundusIcons.sizeSm),
                  label: const Text('Gerät koppeln'),
                )
              else
                _PairingInvitation(host: host, session: session),
            ],
          ],
          if (host.pairedDevices.isNotEmpty) ...[
            const SizedBox(height: FundusSpace.x4),
            Text('Gekoppelte Geräte', style: theme.textTheme.labelLarge),
            for (final device in host.pairedDevices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: FundusConnectionDot(
                  state: host.connectionFor(device),
                  showLabel: false,
                ),
                title: Text(device.name),
                subtitle: Text(
                  host.connectionFor(device) == FundusConnectionState.connected
                      ? 'jetzt verbunden'
                      : device.lastSeenAt == null
                      ? 'gekoppelt am ${_date(device.pairedAt)}'
                      : 'zuletzt ${_moment(device.lastSeenAt!)}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
                trailing: IconButton(
                  onPressed: () => host.revoke(device.id),
                  icon: Icon(FundusIcons.close, size: FundusIcons.sizeMd),
                  tooltip: 'Zugang entziehen',
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _date(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year}';
  }

  static String _moment(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}. ${two(local.hour)}:'
        '${two(local.minute)}';
  }
}

/// The code and the PIN, side by side.
///
/// Deliberately two separate things to hand over: the code may be copied,
/// photographed or pasted, the six digits have to be read off this screen.
/// One of them travelling alone is worth nothing.
class _PairingInvitation extends StatelessWidget {
  const _PairingInvitation({required this.host, required this.session});

  final ServerHostController host;
  final FundusPairingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final code = host.pairingCode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PIN', style: theme.textTheme.labelLarge),
        const SizedBox(height: FundusSpace.x1),
        SelectableText(
          session.pin,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 6,
          ),
        ),
        const SizedBox(height: FundusSpace.x4),
        Text('Kopplungscode', style: theme.textTheme.labelLarge),
        const SizedBox(height: FundusSpace.x2),
        if (code != null)
          // On white, always: a scanner reads contrast, not a colour scheme,
          // and a dark code on a dark ground is a code nothing reads.
          Container(
            padding: const EdgeInsets.all(FundusSpace.x3),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: FundusRadius.mdAll,
            ),
            child: QrImageView(
              data: code,
              size: 260,
              backgroundColor: Colors.white,
              // The code carries a certificate fingerprint, so it is long;
              // the lowest correction level keeps the squares large enough to
              // read from arm's length.
              errorCorrectionLevel: QrErrorCorrectLevel.L,
            ),
          ),
        const SizedBox(height: FundusSpace.x3),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: code == null
                  ? null
                  : () => Clipboard.setData(ClipboardData(text: code)),
              icon: Icon(FundusIcons.note, size: FundusIcons.sizeSm),
              label: const Text('Code kopieren'),
            ),
            const SizedBox(width: FundusSpace.x3),
            TextButton(
              onPressed: host.cancelPairing,
              child: const Text('Abbrechen'),
            ),
          ],
        ),
        const SizedBox(height: FundusSpace.x2),
        // Kept, but out of the way: scanning is the normal path, pasting the
        // one for a device without a camera.
        ExpansionTile(
          title: Text('Code als Text', style: theme.textTheme.labelLarge),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(FundusSpace.x3),
              decoration: BoxDecoration(
                color: tokens.background,
                borderRadius: FundusRadius.mdAll,
              ),
              child: SelectableText(
                code ?? '',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: tokens.textMuted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: FundusSpace.x2),
        Text(
          'Gültig bis ${_time(session.expiresAt)}. Danach braucht es einen '
          'neuen Code.',
          style: theme.textTheme.labelMedium?.copyWith(color: tokens.textFaint),
        ),
      ],
    );
  }

  static String _time(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)} Uhr';
  }
}
