import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('generated IDs are safe protocol path components', () {
    expect(FundusId.isSafe(FundusId.generate()), isTrue);
    expect(FundusId.isSafe('work_01-abc'), isTrue);
  });

  test('path syntax and empty IDs are rejected', () {
    expect(FundusId.isSafe('../outside'), isFalse);
    expect(FundusId.isSafe(r'..\outside'), isFalse);
    expect(FundusId.isSafe(''), isFalse);
    expect(FundusId.isSafe('x.y'), isFalse);
  });
}
