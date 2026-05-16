import 'package:audiorelay_clone/app/audio_bridge_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the audio relay dashboard', (tester) async {
    await tester.pumpWidget(const AudioBridgeApp());
    await tester.pump();

    expect(find.text('AudioBridge'), findsOneWidget);
    expect(find.text('Sender'), findsWidgets);
    expect(find.text('Receiver'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsWidgets);
    expect(find.text('USB tether'), findsOneWidget);
    expect(find.text('Native USB'), findsOneWidget);
    expect(find.text('Audio settings'), findsOneWidget);
    expect(find.text('Simple'), findsNothing);
    expect(find.text('Advanced'), findsNothing);
    expect(find.text('Gaming'), findsOneWidget);
    expect(find.text('Balanced'), findsWidgets);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('Format and bandwidth'), findsOneWidget);
    expect(find.text('Latency and stability'), findsOneWidget);
    expect(find.text('Sender buffer'), findsOneWidget);
    expect(find.text('Receiver buffer'), findsOneWidget);
    expect(find.text('Receiver adaptive buffer'), findsOneWidget);
    expect(find.byIcon(Icons.tune_rounded), findsWidgets);
  });
}
