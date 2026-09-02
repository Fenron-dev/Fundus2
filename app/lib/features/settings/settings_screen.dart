import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';

/// Settings, with the scope of each one visible.
///
/// The categories and their order come from the design; areas that only
/// arrive with a later slice say so plainly instead of showing controls that
/// do nothing.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    return switch (category) {
      'darstellung' => const _Appearance(),
      'bibliotheken' => const _Libraries(),
      'server' => const _Devices(),
      'diagnose' => const _Diagnostics(),
      _ => _Planned(category: category),
    };
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

class _Devices extends StatefulWidget {
  const _Devices();

  @override
  State<_Devices> createState() => _DevicesState();
}

class _DevicesState extends State<_Devices> {
  final _nameController = TextEditingController();
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
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final profiles = _profiles;

    return _SettingsPage(
      title: 'Server & Geräte',
      subtitle:
          'Gerätekennung und Schlüssel bleiben lokal. Was jedes Gerät sich '
          'merkt — Reader und Darstellung — liegt bei der Bibliothek.',
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Dieses Gerät',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: FundusSpace.x3),
              TextField(
                controller: _nameController,
                onSubmitted: scope.settings.setDeviceName,
                decoration: const InputDecoration(labelText: 'Gerätename'),
              ),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Kennung ${scope.settings.deviceKey}',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
              ),
            ],
          ),
        ),
        if (profiles != null)
          FutureBuilder<List<DeviceProfile>>(
            future: profiles,
            builder: (context, snapshot) {
              final profiles = (snapshot.data ?? const <DeviceProfile>[])
                  .where((p) => p.key != scope.settings.deviceKey)
                  .toList();
              if (profiles.isEmpty) return const SizedBox.shrink();
              return _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Einstellungen übernehmen',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: FundusSpace.x2),
                    Text(
                      'Diese Bibliothek trägt Einstellungen anderer Geräte. '
                      'Nach einer Neuinstallation lassen sie sich hier '
                      'zurückholen — die Kennung bleibt dabei diese.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
                    ),
                    const SizedBox(height: FundusSpace.x4),
                    for (final profile in profiles)
                      Padding(
                        padding: const EdgeInsets.only(bottom: FundusSpace.x2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${profile.displayName}'
                                '${profile.platform.isEmpty ? '' : ' · ${profile.platform}'}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                            OutlinedButton(
                              onPressed: () =>
                                  scope.adoptDeviceProfile(profile),
                              child: const Text('Übernehmen'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LAN-Freigabe',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Der Peer-Server aus packages/server wird mit dem Netz-Schnitt '
                'angeschlossen: TLS, QR-Pairing und widerrufbare '
                'Geräteberechtigungen sind dort bereits gebaut.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
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

class _Planned extends StatelessWidget {
  const _Planned({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    const descriptions = <String, (String, String)>{
      'wiedergabe': (
        'Wiedergabe',
        'Geschwindigkeit, Sprungweiten, Sleep-Timer und Konfliktauflösung '
            'gehören zur Medien-Engine und kommen mit ihr.',
      ),
      'reader': (
        'Reader',
        'Leserichtung, Doppelseiten und Schriftgröße sind gerätegebunden und '
            'werden mit dem jeweiligen Reader gebaut.',
      ),
      'suche': (
        'Suche & Filter',
        'Gespeicherte Ansichten und Suchbereich folgen, sobald die Suche über '
            'mehrere Quellen läuft.',
      ),
      'wartung': (
        'Serverwartung',
        'Speicher, Scan-Zeitplan und Wartungsaufgaben gehören zum Peer-Server.',
      ),
      'synchronisation': (
        'Synchronisation',
        'Konfliktregeln je Entität stehen fest; sie greifen, sobald das '
            'Journal läuft.',
      ),
      'schutz': (
        'Schutzmodus',
        'PIN, unscharfe Vorschau und vollständiges Ausblenden greifen quer '
            'durch Suche, Fortsetzen und Protokolle — deshalb erst, wenn diese '
            'Wege alle stehen.',
      ),
    };
    final entry = descriptions[category] ?? ('Einstellungen', '');

    return _SettingsPage(
      title: entry.$1,
      subtitle: entry.$2,
      children: const [],
    );
  }
}
