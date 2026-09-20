import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('ratings are stored per work and file and survive reopen', () async {
    final root = await Directory.systemTemp.createTemp('fundus-rating-');
    addTearDown(() => root.delete(recursive: true));
    final media = Directory('${root.path}/Manga')..createSync(recursive: true);
    File('${media.path}/Chapter 1.cbz').writeAsBytesSync(const [80, 75]);
    final library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    final work = library.listWorks().single;
    final file = library.playbackTracks(work.id).single;
    var annotations = await library.setRating(
      workId: work.id,
      fileId: file.fileId,
      value: 1,
    );
    expect(annotations.thumbsUpCount, 1);
    annotations = await library.setRating(
      workId: work.id,
      fileId: file.fileId,
      value: -1,
    );
    expect(annotations.thumbsDownCount, 1);
    library.close();
    final reopened = await FundusLibrary.open(root);
    expect(reopened.loadAnnotations(work.id).ratings.single.value, -1);
    reopened.close();
  });
}
