import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/library_controller.dart';

/// Choosing a vault — the one screen that works without one.
///
/// A vault is a folder and nothing else: everything inside it is relative, so
/// it can live on an external drive and be opened from any device.
class VaultScreen extends StatelessWidget {
  const VaultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final theme = Theme.of(context);

    // A phone has no room for the desktop's generous frame, and at a large
    // system font the title stopped fitting between the margins.
    final narrow =
        MediaQuery.sizeOf(context).width < FundusShellMetrics.compactBreakpoint;

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(narrow ? FundusSpace.x6 : FundusSpace.x16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: tokens.accentTint(0.16),
                      borderRadius: FundusRadius.mdAll,
                    ),
                    child: Icon(
                      FundusIcons.vault,
                      size: FundusIcons.sizeLg,
                      color: tokens.accent,
                    ),
                  ),
                  const SizedBox(width: FundusSpace.x4),
                  Flexible(
                    child: Text(
                      'Fundus',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.displayMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: FundusSpace.x4),
              Text(
                'Eine Bibliothek ist ein Ordner. Alles darin ist relativ, '
                'damit sie auf eine externe Platte passt und auf jedem Gerät '
                'dieselbe bleibt.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
              const SizedBox(height: FundusSpace.x10),
              if (scope.library.status == LibraryStatus.failed)
                _FailureNotice(message: scope.library.error ?? ''),
              // Wrap statt Row: die beiden Beschriftungen sind auf einem
              // schmalen Fenster zusammen breiter als die Spalte.
              Wrap(
                spacing: FundusSpace.x3,
                runSpacing: FundusSpace.x3,
                children: [
                  FilledButton.icon(
                    onPressed: () => _pick(context, createIfMissing: false),
                    icon: Icon(FundusIcons.folder, size: FundusIcons.sizeSm),
                    label: const Text('Bibliothek öffnen'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _pick(context, createIfMissing: true),
                    icon: Icon(
                      FundusIcons.newMediaType,
                      size: FundusIcons.sizeSm,
                    ),
                    label: const Text('Neue Bibliothek anlegen'),
                  ),
                ],
              ),
              const SizedBox(height: FundusSpace.x10),
              Text('ZULETZT VERWENDET', style: theme.textTheme.labelSmall),
              const SizedBox(height: FundusSpace.x3),
              if (scope.settings.recentVaults.isEmpty)
                Text(
                  'Noch keine. Der zuletzt geöffnete Ordner steht künftig hier.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.textFaint,
                  ),
                )
              else
                for (final path in scope.settings.recentVaults)
                  _RecentVaultTile(path: path),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pick(
    BuildContext context, {
    required bool createIfMissing,
  }) async {
    final scope = FundusScope.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Auf Android muss der Zugriff auf die Dateien erst erteilt werden. Ohne
    // ihn liefert die Auswahl einen Ordner, den niemand lesen kann — und die
    // Bibliothek bliebe ohne Erklärung leer.
    if (scope.storage.isRequired && !await scope.storage.isGranted()) {
      final granted = await scope.storage.request();
      if (!granted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Ohne Dateizugriff lässt sich keine Bibliothek öffnen. '
              'Der Zugriff lässt sich in den Systemeinstellungen erteilen.',
            ),
          ),
        );
        return;
      }
    }

    final String? selected;
    try {
      selected = await FilePicker.getDirectoryPath(
        dialogTitle: createIfMissing
            ? 'Ordner für die neue Bibliothek'
            : 'Bibliotheksordner öffnen',
        initialDirectory: await scope.storage.storageRoot(),
      );
    } on Object catch (error) {
      // Ein Dialog, der nicht aufgeht, darf nicht als Absturz enden — der
      // Weg über einen zuletzt benutzten Ordner bleibt ja offen.
      messenger.showSnackBar(
        SnackBar(
          content: Text('Der Ordnerdialog lässt sich nicht öffnen: $error'),
        ),
      );
      return;
    }
    if (selected == null) return;
    await _open(scope, selected, createIfMissing: createIfMissing);
  }

  static Future<void> _open(
    FundusScopeState scope,
    String path, {
    required bool createIfMissing,
  }) async {
    await scope.library.open(Directory(path), createIfMissing: createIfMissing);
    if (!scope.library.isOpen) return;
    await scope.settings.rememberVault(path);
    // The vault carries this device's own settings; after a reinstall this is
    // where they come back from.
    await scope.restoreShellProfile();
    // Sharing was a decision about this device, not about this session: if it
    // was on when the app was last closed, it comes back on — but only now,
    // with a library open, because there is nothing to serve without one.
    await scope.host.restore();
    scope.navigation.reset(const DashboardRoute());
  }
}

class _RecentVaultTile extends StatelessWidget {
  const _RecentVaultTile({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final exists = Directory(path).existsSync();
    final name = path.split(Platform.pathSeparator).last;

    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x2),
      child: InkWell(
        borderRadius: FundusRadius.mdAll,
        onTap: exists
            ? () => VaultScreen._open(scope, path, createIfMissing: false)
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: FundusSpace.x4,
            vertical: FundusSpace.x3,
          ),
          decoration: BoxDecoration(
            borderRadius: FundusRadius.mdAll,
            border: Border.fromBorderSide(BorderSide(color: tokens.divider)),
          ),
          child: Row(
            children: [
              FundusOriginMark(
                exists ? FundusOrigin.local : FundusOrigin.unreachable,
              ),
              const SizedBox(width: FundusSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, style: Theme.of(context).textTheme.bodyMedium),
                    Text(
                      exists ? path : '$path — Laufwerk nicht gefunden',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: exists ? tokens.textFaint : tokens.danger,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => scope.settings.forgetVault(path),
                icon: Icon(FundusIcons.close, size: FundusIcons.sizeSm),
                tooltip: 'Aus der Liste entfernen',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FailureNotice extends StatelessWidget {
  const _FailureNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Container(
      margin: const EdgeInsets.only(bottom: FundusSpace.x6),
      padding: const EdgeInsets.all(FundusSpace.x4),
      decoration: BoxDecoration(
        color: tokens.dangerGround,
        borderRadius: FundusRadius.mdAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            FundusIcons.warning,
            size: FundusIcons.sizeMd,
            color: tokens.danger,
          ),
          const SizedBox(width: FundusSpace.x3),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.danger),
            ),
          ),
        ],
      ),
    );
  }
}
