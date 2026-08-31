import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/site_browser_log.dart';
import 'package:vault/agent/site_gateway.dart';
import 'package:vault/screens/agent/site_logs_screen.dart';

void main() {
  test('formatSiteLogEvent includes time level type and message', () {
    final event = SiteBrowserEvent(
      at: DateTime(2026, 8, 31, 9, 8, 7),
      slug: 'demo',
      type: 'gateway',
      level: 'error',
      message: '不支持 WebSocket',
      count: 2,
    );
    expect(
      formatSiteLogEvent(event),
      contains('09:08:07  error  gateway ×2  不支持 WebSocket'),
    );
  });

  testWidgets('shows empty hints and HTTP-only caption', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SiteLogsScreen(
          title: '网站',
          pollInterval: Duration.zero,
          loadProcessLog: () async => null,
          loadEvents: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(kSiteLogEmptyProcessHint), findsOneWidget);
    expect(find.text(kSiteGatewayHttpOnlyCaption), findsOneWidget);

    await tester.tap(find.text('浏览器 / 网关'));
    await tester.pumpAndSettle();
    expect(find.text(kSiteLogEmptyEventsHint), findsOneWidget);
  });

  testWidgets('shows process log tail', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SiteLogsScreen(
          title: '网站',
          pollInterval: Duration.zero,
          loadProcessLog: () async => 'Traceback: boom',
          loadEvents: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Traceback: boom'), findsOneWidget);
    expect(find.text(kSiteLogEmptyProcessHint), findsNothing);
  });

  testWidgets('shows browser and gateway events', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SiteLogsScreen(
          title: '网站',
          pollInterval: Duration.zero,
          loadProcessLog: () async => 'ok',
          loadEvents: () async => [
            SiteBrowserEvent(
              at: DateTime(2026, 8, 31, 10, 0, 0),
              slug: 'demo',
              type: 'console',
              level: 'error',
              message: 'Uncaught TypeError',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('浏览器 / 网关'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Uncaught TypeError'), findsOneWidget);
    expect(find.textContaining('console'), findsOneWidget);
  });
}
