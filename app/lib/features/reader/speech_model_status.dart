import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/fundus_scope.dart';
import '../../app/offline_conditions.dart';
import '../settings/settings_shell.dart' show formatBytes;

class SpeechModelStatus extends StatelessWidget {
  const SpeechModelStatus({super.key});
  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final models = scope.speechModels;
    return ListenableBuilder(
      listenable: models,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (models.isBusy) ...[
            LinearProgressIndicator(value: models.progress),
            const SizedBox(height: FundusSpace.x2),
            Text(
              'Vorlesemodell von „${models.serverName ?? 'Server'}“: ${models.progress == null ? 'Angebot wird geprüft …' : '${(models.progress! * 100).toStringAsFixed(1)} %'}',
            ),
          ] else if (models.installed != null)
            const Text(
              'Vorlesemodell auf diesem Gerät gespeichert; auch offline nutzbar.',
            )
          else ...[
            if (models.failure case final message?) Text(message),
            OutlinedButton.icon(
              onPressed: () => requestSpeechModelFromServer(context),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Vorlesemodell vom Server laden'),
            ),
          ],
          const _UnusedModels(),
        ],
      ),
    );
  }
}

/// Asks the paired servers for a model, shows its size and the network it
/// would travel over, and downloads only after an explicit yes.
///
/// Returns the installed folder, or null when nothing was installed.
Future<String?> requestSpeechModelFromServer(BuildContext context) async {
  final scope = FundusScope.of(context);
  final models = scope.speechModels;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final offer = await models.findOffer();
  if (!context.mounted) return null;
  if (offer == null) {
    final message = models.failure;
    if (message != null) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
    return null;
  }
  final size = offer.model.totalBytes;
  final conditions = await readOfflineConditions();
  final support = await getApplicationSupportDirectory();
  final free = await readFreeBytes(support.path);
  if (!context.mounted) return null;
  if (free != null && free < size + freeSpaceReserveBytes) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nicht genug Speicher'),
        content: Text(
          'Das Vorlesemodell braucht ${formatBytes(size)}, frei sind nur '
          '${formatBytes(free)}. Bitte zuerst Platz schaffen, etwa unter '
          'Downloads oder durch das Entfernen nicht verwendeter Modelle.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return null;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Vorlesemodell laden?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '„${offer.server.name}“ bietet ein Vorlesemodell mit '
            '${formatBytes(size)} an. Es wird nur auf diesem Gerät '
            'gespeichert und ist danach auch offline nutzbar.',
          ),
          if (free != null) ...[
            const SizedBox(height: FundusSpace.x2),
            Text('Frei auf diesem Gerät: ${formatBytes(free)}'),
          ],
          if (conditions.wifi != true) ...[
            const SizedBox(height: FundusSpace.x3),
            Text(
              conditions.wifi == false
                  ? 'Du bist nicht im WLAN. Über mobile Daten können Kosten '
                        'entstehen.'
                  : 'Ob gerade WLAN genutzt wird, ist nicht bekannt. Über '
                        'mobile Daten können Kosten entstehen.',
              style: TextStyle(color: context.fundus.danger),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Laden'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return null;
  final installed = await models.install(offer);
  final failure = models.failure;
  if (installed == null && failure != null) {
    messenger?.showSnackBar(SnackBar(content: Text(failure)));
  }
  return installed;
}

/// Models Fundus once stored and nothing refers to any more.
class _UnusedModels extends StatefulWidget {
  const _UnusedModels();

  @override
  State<_UnusedModels> createState() => _UnusedModelsState();
}

class _UnusedModelsState extends State<_UnusedModels> {
  Future<List<({String path, int bytes})>>? _unused;
  bool _removing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _unused ??= FundusScope.of(context).speechModels.unusedModels();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<({String path, int bytes})>>(
      future: _unused,
      builder: (context, snapshot) {
        final unused = snapshot.data ?? const [];
        if (unused.isEmpty) return const SizedBox.shrink();
        final bytes = unused.fold(0, (sum, model) => sum + model.bytes);
        return Padding(
          padding: const EdgeInsets.only(top: FundusSpace.x3),
          child: OutlinedButton.icon(
            onPressed: _removing
                ? null
                : () async {
                    final models = FundusScope.of(context).speechModels;
                    setState(() => _removing = true);
                    await models.pruneUnused();
                    if (!mounted) return;
                    setState(() {
                      _removing = false;
                      _unused = models.unusedModels();
                    });
                  },
            icon: const Icon(Icons.delete_outline),
            label: Text(
              unused.length == 1
                  ? 'Nicht verwendetes Modell entfernen (${formatBytes(bytes)})'
                  : '${unused.length} nicht verwendete Modelle entfernen '
                        '(${formatBytes(bytes)})',
            ),
          ),
        );
      },
    );
  }
}
