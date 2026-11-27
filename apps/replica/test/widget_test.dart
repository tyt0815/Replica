import 'package:flutter_test/flutter_test.dart';
import 'package:replica/main.dart';

void main() {
  testWidgets('검색 화면을 표시한다', (tester) async {
    await tester.pumpWidget(const ReplicaApp());
    expect(find.text('음악 · 영상 검색'), findsOneWidget);
    expect(find.text('Jazz'), findsOneWidget);
  });
}
