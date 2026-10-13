import 'dart:io';

import 'package:employee_salary/cloud_backend.dart';
import 'package:employee_salary/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEmployeeStore extends EmployeeStore {
  _FakeEmployeeStore({super.cloudSession});

  final _employees = <EmployeeRecord>[];

  @override
  Future<List<EmployeeRecord>> loadEmployees() async => List.of(_employees);

  @override
  Future<EmployeeRecord> createEmployee(String name) async {
    final employee = EmployeeRecord(id: '${_employees.length}', name: name);
    _employees.add(employee);
    return employee;
  }

  @override
  Future<void> deleteEmployee(EmployeeRecord employee) async {
    _employees.removeWhere((entry) => entry.id == employee.id);
  }
}

void main() {
  testWidgets('manager actions and employee folder fit on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _FakeEmployeeStore(
      cloudSession: const CloudAppSession(
        token: 'test-token',
        role: 'manager',
        companyId: 'test-company',
        companyName: 'Test Company',
        username: 'manager',
      ),
    );
    await store.createEmployee('Visible Employee');
    expect(await store.loadEmployees(), hasLength(1));

    await tester.pumpWidget(
      MaterialApp(home: EmployeesPage(store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('نظام الحضور'), findsOneWidget);
    expect(find.text('إضافة موظف'), findsOneWidget);
    expect(find.byTooltip('حذف موظف'), findsOneWidget);
    expect(find.byTooltip('الإنفو'), findsOneWidget);
    expect(find.text('Visible Employee'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('employee password controls remain visible with employee list', (
    tester,
  ) async {
    final store = _FakeEmployeeStore(
      cloudSession: const CloudAppSession(
        token: 'test-token',
        role: 'employee',
        companyId: 'test-company',
        companyName: 'Test Company',
        username: 'employee',
      ),
    );
    await store.createEmployee('Visible Employee');

    await tester.pumpWidget(
      MaterialApp(home: EmployeeSelectionPage(store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('إعدادات الباسورد'), findsOneWidget);
    expect(find.text('Visible Employee'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding an employee closes the dialog and refreshes the list', (
    tester,
  ) async {
    final store = _FakeEmployeeStore();
    await tester.pumpWidget(
      MaterialApp(home: EmployeesPage(store: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Test Employee');
    await tester.tap(find.widgetWithText(FilledButton, 'إضافة'));
    await tester.pumpAndSettle();

    expect(find.text('Test Employee'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('employee app shows employees created in the manager app', (
    tester,
  ) async {
    final store = _FakeEmployeeStore();
    await store.createEmployee('Shared Employee');

    await tester.pumpWidget(
      MaterialApp(home: EmployeeSelectionPage(store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('تطبيق الموظفين'), findsOneWidget);
    expect(find.text('Shared Employee'), findsOneWidget);
  });

  testWidgets('deleting an employee removes it from the manager list', (
    tester,
  ) async {
    final store = _FakeEmployeeStore();
    await store.createEmployee('Delete Me');

    await tester.pumpWidget(
      MaterialApp(home: EmployeesPage(store: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('حذف موظف'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Delete Me').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Me'), findsNothing);
  });

  test('manager and employee stores share employee month records', () async {
    final directory = await Directory.systemTemp.createTemp('salary-shared-');
    try {
      final managerStore = EmployeeStore(
        directory: Directory('${directory.path}/employees'),
      );
      final employeeStore = EmployeeStore(
        directory: Directory('${directory.path}/employees'),
      );

      final employee = await managerStore.createEmployee('Test Employee');
      final visibleEmployees = await employeeStore.loadEmployees();
      final managerMonths = await managerStore.monthsDirectory(employee);
      final employeeMonths = await employeeStore.monthsDirectory(
        visibleEmployees.single,
      );
      final month = MonthRecord(year: 2026, month: 10, hourlyRate: 50);

      await MonthStore(directory: managerMonths).save(month);

      expect(visibleEmployees.single.id, employee.id);
      expect(await MonthStore(directory: employeeMonths).loadMonths(), [
        isA<MonthRecord>()
            .having((record) => record.id, 'id', '2026-10')
            .having((record) => record.hourlyRate, 'hourlyRate', 50),
      ]);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
