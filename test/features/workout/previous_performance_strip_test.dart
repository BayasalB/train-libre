import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:train_libre/features/workout/domain/models/set_log.dart';
import 'package:train_libre/features/workout/presentation/widgets/previous_performance_strip.dart';
import 'package:train_libre/services/unit_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'previous completed sets are visible in the preferred weight unit',
      (tester) async {
    SharedPreferences.setMockInitialValues({'unit_system': 'metric'});
    final units = UnitService();
    await units.reload();
    final sets = [
      SetLog(
          workoutLogId: 1,
          exerciseName: 'OHP',
          setType: 'normal',
          weightKg: 60.5,
          reps: 12,
          isCompleted: true),
      SetLog(
          workoutLogId: 1,
          exerciseName: 'OHP',
          setType: 'normal',
          weightKg: 90,
          reps: 1,
          isCompleted: false),
    ];
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: units,
        child: MaterialApp(
            home: Scaffold(body: PreviousPerformanceStrip(sets: sets)))));
    expect(find.textContaining('60.5 kg × 12'), findsOneWidget);
    expect(find.textContaining('90'), findsNothing);
    await units.setUnitSystem(UnitSystem.imperial);
    await tester.pump();
    expect(find.textContaining('lbs × 12'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    units.dispose();
  });
}
