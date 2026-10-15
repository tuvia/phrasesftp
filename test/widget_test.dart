import 'package:flutter_test/flutter_test.dart';
import 'package:phrasesftp/main.dart';

void main() {
  test('remoteFileName usa el formato IMG_AAAAMMDD.jpg', () {
    expect(remoteFileName(DateTime(2026, 10, 14)), 'IMG_20261014.jpg');
    expect(remoteFileName(DateTime(2026, 1, 5)), 'IMG_20260105.jpg');
  });
}
