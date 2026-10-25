import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';

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
          ] else if (scope.settings.phononModelDirectory != null)
            const Text(
              'Vorlesemodell auf diesem Gerät gespeichert; auch offline nutzbar.',
            )
          else ...[
            if (models.failure case final message?) Text(message),
            OutlinedButton.icon(
              onPressed: () => models.ensureAvailable(retry: true),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Vorlesemodell vom Server laden'),
            ),
          ],
        ],
      ),
    );
  }
}
