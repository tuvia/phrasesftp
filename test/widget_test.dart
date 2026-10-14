import 'package:flutter_test/flutter_test.dart';
import 'package:phrasesftp/main.dart';

void main() {
  test('renameFirstDash reemplaza solo el primer guión', () {
    expect(renameFirstDash('IMG-20261014-WA0001.jpg'),
        'IMG_20261014-WA0001.jpg');
    expect(renameFirstDash('singuion.jpg'), 'singuion.jpg');
  });
}
