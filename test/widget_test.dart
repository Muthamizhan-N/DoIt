import 'package:flutter_test/flutter_test.dart';

import 'package:task_mate/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const DoItApp());

    // Verify that the app title 'DoIt' is displayed in the AppBar.
    expect(find.text('DoIt'), findsWidgets);
  });
}
