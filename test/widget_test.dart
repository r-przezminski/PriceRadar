import 'package:flutter_test/flutter_test.dart';
import 'package:priceradar/main.dart';

void main() {
  testWidgets('PriceRadar smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PriceRadarApp());
    expect(find.text('PriceRadar'), findsOneWidget);
  });
}
