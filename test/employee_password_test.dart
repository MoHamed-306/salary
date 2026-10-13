import 'package:employee_salary/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('employee password requires at least six characters', () {
    expect(
      employeePasswordValidation('12345', '12345'),
      'كلمة المرور يجب أن تكون 6 أحرف على الأقل',
    );
  });

  test('employee password confirmation must match', () {
    expect(
      employeePasswordValidation('secret1', 'secret2'),
      'كلمتا المرور غير متطابقتين',
    );
  });

  test('matching employee password confirmation is accepted', () {
    expect(employeePasswordValidation('secret1', 'secret1'), isNull);
  });

  test('employee password state is decoded from the company employee list', () {
    final employee = EmployeeRecord.fromJson({
      'id': 'employee-id',
      'name': 'Test Employee',
      'has_password': true,
    });

    expect(employee.hasPassword, isTrue);
  });
}
