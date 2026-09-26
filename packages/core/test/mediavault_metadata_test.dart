import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('reads the Fero fields used by Fundus', () async {
    final root = await Directory.systemTemp.createTemp('fero-metadata-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/Novel.mediavault.yaml');
    await file.writeAsString('''
title: Novel
author: Person
status: finished
series_title: Reihe
series_sequence: 2
rating_external: 4.43
genres: [Fantasy, Adventure]
tags: [Magic, Time Loop]
''');

    final value = await const MediaVaultMetadataReader().read(file);

    expect(value, isNotNull);
    expect(value!.authors, ['Person']);
    expect(value.publicationStatus, 'completed');
    expect(value.series, 'Reihe');
    expect(value.sequence, 2);
    expect(value.externalRating, 4.43);
    expect(value.genres, ['Fantasy', 'Adventure']);
    expect(value.tags, ['Magic', 'Time Loop']);
  });

  test('does not invent a publication state from in-library', () async {
    final root = await Directory.systemTemp.createTemp('fero-status-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/Novel.mediavault.yaml');
    await file.writeAsString('status: in-library\n');

    final value = await const MediaVaultMetadataReader().read(file);

    expect(value?.publicationStatus, isNull);
  });
}
