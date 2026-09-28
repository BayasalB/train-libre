import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/database_helper.dart';
import '../../today/domain/daily_record_models.dart';
import '../data/history_repository.dart';
import 'day_detail_screen.dart';

class HistoryScreen extends StatefulWidget {
  final HistoryRepository? repository;
  final DateTime? initialMonth;
  final ValueChanged<DateTime>? onOpenDiary;

  const HistoryScreen(
      {super.key, this.repository, this.initialMonth, this.onOpenDiary});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final HistoryRepository _repository = widget.repository ??
      HistoryRepository(DatabaseHelper.instance.dbInstance);
  late DateTime _month = DateTime((widget.initialMonth ?? DateTime.now()).year,
      (widget.initialMonth ?? DateTime.now()).month);
  late Stream<List<HistoryDaySummary>> _days = _repository.watchMonth(_month);

  void _selectMonth(DateTime date) {
    setState(() {
      _month = DateTime(date.year, date.month);
      _days = _repository.watchMonth(_month);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('History')),
        body: Column(children: [
          Row(children: [
            IconButton(
                tooltip: 'Previous month',
                onPressed: () =>
                    _selectMonth(DateTime(_month.year, _month.month - 1)),
                icon: const Icon(Icons.chevron_left)),
            Expanded(
                child: TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                          context: context,
                          initialDate: _month,
                          firstDate: DateTime(1900),
                          lastDate: DateTime(2100));
                      if (picked != null && mounted) _selectMonth(picked);
                    },
                    child: Text(DateFormat.yMMMM().format(_month),
                        key: const ValueKey('history-month')))),
            IconButton(
                tooltip: 'Next month',
                onPressed: () =>
                    _selectMonth(DateTime(_month.year, _month.month + 1)),
                icon: const Icon(Icons.chevron_right)),
          ]),
          Expanded(
              child: StreamBuilder<List<HistoryDaySummary>>(
                  key: ValueKey(localDateKey(_month)),
                  stream: _days,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                          child: TextButton(
                              onPressed: () => _selectMonth(_month),
                              child:
                                  const Text('Could not load History. Retry')));
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final days = snapshot.data!.reversed.toList();
                    return ListView.builder(
                        key: const ValueKey('history-days'),
                        itemCount: days.length,
                        itemBuilder: (context, index) {
                          final day = days[index];
                          final dateKey = localDateKey(day.date);
                          return ListTile(
                              key: ValueKey('history-day-$dateKey'),
                              title: Text(DateFormat.MMMd().format(day.date)),
                              subtitle: Text(day.hasActivity
                                  ? '${day.trainingType.label} · ${day.calories.toStringAsFixed(0)} kcal · P ${day.protein.toStringAsFixed(1)} g'
                                  : 'No entries'),
                              trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (day.locked)
                                      const Icon(Icons.lock_outline,
                                          size: 17,
                                          semanticLabel: 'Locked day'),
                                    const Icon(Icons.chevron_right),
                                  ]),
                              onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) => DayDetailScreen(
                                          date: day.date,
                                          repository: _repository,
                                          onOpenDiary: widget.onOpenDiary))));
                        });
                  }))
        ]),
      );
}
