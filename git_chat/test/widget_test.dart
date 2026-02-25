import 'package:flutter_test/flutter_test.dart';

import 'package:git_chat/main.dart';

void main() {
  testWidgets('GitChat app launches', (WidgetTester tester) async {
    await tester.pumpWidget(const GitChatApp(showOnboarding: true));

    // Verify the onboarding screen shows
    expect(find.text('CONNECT'), findsOneWidget);
  });
}
