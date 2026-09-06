import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/work_view.dart';
import '../library/work_poster.dart';
import 'person_credits.dart';

/// Alles von einer Person, quer durch die Bibliotheken.
///
/// Eine Person steht am Werk und nicht am Regal. Wer einen Sprecher antippt,
/// will seine Hörbücher sehen — und wenn derselbe Mensch woanders geschrieben
/// hat, das auch. Deshalb gibt es hier keine Medientypen, sondern Rollen.
class PersonScreen extends StatelessWidget {
  const PersonScreen({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final stage = FundusStageSize.of(context);
    final credits = worksOfPerson(
      name,
      scope.library.works,
      library: scope.library.library,
    );

    if (credits.isEmpty) {
      return FundusEmptyState(
        icon: FundusIcons.person,
        title: name,
        reason:
            'Zu dieser Person steht gerade nichts im Katalog. Vielleicht hat '
            'ein Abgleich sie inzwischen anders geschrieben.',
      );
    }

    final byRole = <String, List<WorkView>>{};
    for (final entry in credits) {
      for (final role in entry.roles) {
        byRole.putIfAbsent(role, () => []).add(entry.work);
      }
    }

    return ListView(
      padding: EdgeInsets.all(stage.gutter),
      children: [
        Row(
          children: [
            PersonAvatar(
              name: name,
              size: 72,
              imagePath: scope.library.library?.personImage(name),
              root: scope.library.library?.root.path,
            ),
            const SizedBox(width: FundusSpace.x4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: theme.textTheme.displaySmall),
                  const SizedBox(height: FundusSpace.x1),
                  Text(
                    byRole.keys.join(' · '),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: FundusSpace.x8),
        for (final entry in byRole.entries) ...[
          Text(
            '${entry.key.toUpperCase()} · ${entry.value.length}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: tokens.textFaint,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: FundusSpace.x3),
          Wrap(
            spacing: stage.railGap,
            runSpacing: stage.railGap,
            children: [
              for (final work in entry.value)
                WorkPoster(
                  work: work,
                  width: stage.posterWidth,
                  onTap: () => scope.navigation.go(WorkRoute(work.id)),
                ),
            ],
          ),
          const SizedBox(height: FundusSpace.x8),
        ],
      ],
    );
  }
}

/// Die Kachel einer Person: zwei Buchstaben auf einer Fläche.
///
/// Personenbilder führt Fundus nicht — es hat keine, und ein erfundenes
/// Gesicht wäre schlimmer als keines. Die Farbe kommt aus dem Namen, damit
/// dieselbe Person überall gleich aussieht und zwei nebeneinander
/// unterscheidbar sind.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.size = 56,
    this.imagePath,
    this.root,
  });

  final String name;
  final double size;

  /// Der Pfad des Bildes, relativ zur Bibliothek — wo der Abgleich eines
  /// mitgebracht hat.
  final String? imagePath;
  final String? root;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final tint = tokens.accentTint(0.10 + (name.hashCode.abs() % 12) / 100);
    final relative = imagePath;
    final base = root;
    final file = relative == null || base == null
        ? null
        : File(p.join(base, p.joinAll(p.posix.split(relative))));

    return ClipRRect(
      borderRadius: FundusRadius.mdAll,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tint,
          border: Border.fromBorderSide(BorderSide(color: tokens.divider)),
        ),
        // Ein Gesicht, wo eines da ist; sonst ein Platzhalter. Erfunden wird
        // keines — die Anfangsbuchstaben unter dem Zeichen sagen wenigstens,
        // wer gemeint ist.
        child: file != null && file.existsSync()
            ? Image.file(
                file,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) =>
                    _Placeholder(name: name, size: size),
              )
            : _Placeholder(name: name, size: size),
      ),
    );
  }
}

/// Das Platzhalterbild: ein Zeichen und zwei Buchstaben.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          FundusIcons.person,
          size: size / 2.6,
          color: tokens.textFaint.withValues(alpha: 0.7),
        ),
        if (size >= 72) ...[
          SizedBox(height: size / 20),
          Text(
            initialsOf(name),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: tokens.textFaint,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}
