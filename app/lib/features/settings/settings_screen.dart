import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';
import '../../data/server_host.dart';
import '../library/unassigned_folders_card.dart';

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
      'synchronisation' => const _Sync(),
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

/// Connecting to another Fundus, and keeping both sides in step.
class _Sync extends StatefulWidget {
  const _Sync();

  @override
  State<_Sync> createState() => _SyncState();
}

class _SyncState extends State<_Sync> {
  final _codeController = TextEditingController();
  final _pinController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final sync = scope.sync;
    final tokens = context.fundus;
    final theme = Theme.of(context);

    return _SettingsPage(
      title: 'Synchronisation',
      subtitle:
          'Zwei Geräte, dieselbe Bibliothek, derselbe Stand. Abgeglichen wird, '
          'was man mit sich trägt: wo man ist, und was man sich angestrichen '
          'hat. Dateien wandern nicht mit.',
      children: [
        _Sharing(host: scope.host),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Gerät koppeln', style: theme.textTheme.titleMedium),
              const SizedBox(height: FundusSpace.x2),
              Text(
                'Lass dir auf dem anderen Gerät den Kopplungscode zeigen und '
                'gib die sechsstellige PIN dazu ein. Der Code allein reicht '
                'nicht — wer ihn abfotografiert, hat noch keine Verbindung.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
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
      ],
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
                title: Text(device.name),
                subtitle: Text(
                  'gekoppelt am ${_date(device.pairedAt)}',
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
        const SizedBox(height: FundusSpace.x3),
        Text('Kopplungscode', style: theme.textTheme.labelLarge),
        const SizedBox(height: FundusSpace.x1),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(FundusSpace.x3),
          decoration: BoxDecoration(
            color: tokens.background,
            borderRadius: FundusRadius.mdAll,
          ),
          child: SelectableText(
            code ?? '',
            maxLines: 4,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: tokens.textMuted,
            ),
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
