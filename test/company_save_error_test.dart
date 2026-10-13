import 'package:employee_salary/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('duplicate employee username gets a clear Arabic message', () {
    expect(
      companySaveErrorMessage(
        Exception(
          'duplicate key value violates unique constraint '
          '"companies_employee_username_key"',
        ),
      ),
      'اسم مستخدم الموظفين مستخدم بالفعل. اختر اسمًا آخر.',
    );
  });

  test('duplicate manager username gets a clear Arabic message', () {
    expect(
      companySaveErrorMessage(
        Exception(
          'duplicate key value violates unique constraint '
          '"companies_manager_username_key"',
        ),
      ),
      'اسم مستخدم المدير مستخدم بالفعل. اختر اسمًا آخر.',
    );
  });

  test('other company save errors retain their details', () {
    expect(
      companySaveErrorMessage(Exception('network unavailable')),
      'تعذر حفظ بيانات المؤسسة: Exception: network unavailable',
    );
  });
}
