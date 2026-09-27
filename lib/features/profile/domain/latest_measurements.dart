import 'models/measurement_session.dart';

class LatestMeasurement {
  final double value;
  final double? previousValue;
  final String unit;
  final DateTime date;

  const LatestMeasurement(this.value, this.previousValue, this.unit, this.date);

  double? get change => previousValue == null ? null : value - previousValue!;
}

/// Selects values by time, with no inference about body composition.
Map<String, LatestMeasurement> latestMeasurements(
    Iterable<MeasurementSession> sessions) {
  final ordered = sessions.toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  final first = <String, LatestMeasurement>{};
  for (final session in ordered) {
    for (final measurement in session.measurements) {
      final previous = first[measurement.type];
      if (previous == null) {
        first[measurement.type] = LatestMeasurement(
            measurement.value, null, measurement.unit, session.timestamp);
      } else if (previous.previousValue == null) {
        first[measurement.type] = LatestMeasurement(
            previous.value, measurement.value, previous.unit, previous.date);
      }
    }
  }
  return first;
}
