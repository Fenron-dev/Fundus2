import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

/// Die Seite einer Einstellungskategorie: Überschrift, ein Satz dazu, Karten.
///
/// Eigene Datei, weil die Wartungsseite dieselbe Hülle braucht und eine
/// zweite Kopie davon zwei Seiten wären, die langsam auseinanderlaufen.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    required this.title,
    required this.subtitle,
    required this.children,
    super.key,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final narrow =
        MediaQuery.sizeOf(context).width < FundusShellMetrics.compactBreakpoint;
    return ListView(
      padding: EdgeInsets.all(narrow ? FundusSpace.x4 : FundusSpace.x10),
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

class SettingsCard extends StatelessWidget {
  const SettingsCard({required this.child, super.key});

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

class SettingsFact extends StatelessWidget {
  const SettingsFact(this.label, this.value, {super.key});

  final String label;
  final String value;

  /// Below this a row of two columns stops being readable.
  static const _stackBelow = 420.0;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final name = Text(
      label,
      style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
    );
    final body = SelectableText(value, style: theme.textTheme.bodyMedium);

    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x3),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < _stackBelow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [name, body],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 160, child: name),
                  Expanded(child: body),
                ],
              ),
      ),
    );
  }
}

/// Eine Größe in Worten, die jemand lesen kann.
String formatBytes(int bytes) {
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
