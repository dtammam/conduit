import 'package:conduit/features/chat/providers/assistant_name_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the name from the answer', () {
    expect(parseAssistantName({'name': ' Pal '}), 'Pal');
  });

  test('ignores answers without a usable name', () {
    expect(parseAssistantName(null), isNull);
    expect(parseAssistantName('x'), isNull);
    expect(parseAssistantName({'name': ''}), isNull);
    expect(parseAssistantName({'name': 3}), isNull);
    expect(parseAssistantName({'name': 'x' * 41}), isNull);
  });
}
