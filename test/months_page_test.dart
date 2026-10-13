import 'dart:io';

import 'package:employee_salary/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

class _EmptyMonthStore extends MonthStore {
  @override
  Future<List<MonthRecord>> loadMonths() async => [];
}

void main() {
  setUpAll(() => initializeDateFormatting('ar'));

  test('a fresh employee month store has no months', () async {
    final directory = await Directory.systemTemp.createTemp('salary-months-');
    try {
      expect(await MonthStore(directory: directory).loadMonths(), isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('a fresh employee month store is empty and greets the user', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MonthsPage(
          store: _EmptyMonthStore(),
          userName: 'Test User',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('مرحبًا، Test User'), findsOneWidget);
    expect(find.textContaining('مفيش شهور مضافة لسه'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('employee month list does not show the delete-month button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MonthsPage(
          store: _EmptyMonthStore(),
          userName: 'Test User',
          employeeMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('إضافة شهر'), findsOneWidget);
    expect(find.text('حذف شهر'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('manager month actions remain available on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: MonthsPage(
          store: _EmptyMonthStore(),
          userName: 'Test Manager',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('إضافة شهر'), findsOneWidget);
    expect(find.text('حذف شهر'), findsOneWidget);
    expect(find.byTooltip('الإنفو'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('superadmin month view is read-only and shows salary details', (
    tester,
  ) async {
    final month = MonthRecord(
      year: 2026,
      month: 10,
      hourlyRate: 50,
      vacationDays: 2,
      workDays: 30,
      days: {1: const DayRecord(arrival: '09:00', departure: '17:00')},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MonthPage(
          month: month,
          store: MonthStore(readOnlyMonths: [month]),
          readOnly: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('إجمالي المرتب'), findsOneWidget);
    expect(find.text('سعر الساعة'), findsOneWidget);
    expect(find.text('أيام العمل'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(
      tester.widgetList<Checkbox>(find.byType(Checkbox)).every(
            (checkbox) => checkbox.onChanged == null,
          ),
      isTrue,
    );
  });

  testWidgets('superadmin employee folder exposes months without edit actions',
      (
    tester,
  ) async {
    final month = MonthRecord(year: 2026, month: 10);
    await tester.pumpWidget(
      MaterialApp(
        home: MonthsPage(
          store: MonthStore(readOnlyMonths: [month]),
          userName: 'Test Employee',
          readOnly: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('أكتوبر 2026'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('إضافة شهر'), findsNothing);
    expect(find.text('حذف شهر'), findsNothing);
  });

  test('read-only month store rejects writes', () async {
    final month = MonthRecord(year: 2026, month: 10);
    final store = MonthStore(readOnlyMonths: [month]);

    expect(() => store.save(month), throwsStateError);
    expect(() => store.delete(month), throwsStateError);
  });
}
