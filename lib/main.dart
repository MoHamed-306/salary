import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:employee_salary/cloud_backend.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

const _appDescription =
    'تطبيق ذكي يساعدك على إدارة رواتب الموظفين بسهولة يقوم بحساب ساعات العمل من خلال الحضور و الانصرف و يحدد إجمالي ساعات العمل الشهرية بدقة و يقوم بضرب ساعات العمل في قيمة الساعة لتحديد صافي الراتب.';
const _buildRole = String.fromEnvironment('APP_ROLE', defaultValue: 'combined');

AppRole? get _fixedRole => switch (_buildRole) {
      'employee' => AppRole.employee,
      'manager' => AppRole.manager,
      'superadmin' => AppRole.superadmin,
      'combined' => null,
      _ => throw StateError(
          'APP_ROLE must be employee, manager, superadmin, or combined',
        ),
    };

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar');
  await CloudBackend.initialize();
  runApp(SalaryApp(fixedRole: _fixedRole));
}

class SalaryApp extends StatelessWidget {
  const SalaryApp({this.fixedRole, super.key});

  final AppRole? fixedRole;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: switch (fixedRole) {
        AppRole.employee => 'salary - الموظف',
        AppRole.manager => 'salary - المدير',
        AppRole.superadmin => 'salary - سوبر أدمن',
        null => 'salary',
      },
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF176B5B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: RoleGate(fixedRole: fixedRole),
    );
  }
}

enum AppRole { employee, manager, superadmin }

class CloudRoleGate extends StatefulWidget {
  const CloudRoleGate({required this.role, super.key});

  final String role;

  @override
  State<CloudRoleGate> createState() => _CloudRoleGateState();
}

class _CloudRoleGateState extends State<CloudRoleGate> {
  CloudAppSession? _session;
  Timer? _heartbeatTimer;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    if (!CloudBackend.isConfigured) {
      setState(() {
        _loading = false;
        _error = 'لم يتم إعداد اتصال قاعدة البيانات السحابية.';
      });
      return;
    }
    try {
      final session = await CloudBackend.restoreSession();
      if (!mounted) return;
      if (session != null && session.role == widget.role) {
        _setSession(session);
      } else {
        if (session != null) await CloudBackend.logout(session);
        setState(() => _loading = false);
      }
    } on Exception catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'تعذر الاتصال بالخادم: $error';
        });
      }
    }
  }

  void _setSession(CloudAppSession session) {
    _heartbeatTimer?.cancel();
    setState(() {
      _session = session;
      _loading = false;
      _error = null;
    });
    _heartbeatTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshSession(session),
    );
  }

  Future<void> _refreshSession(CloudAppSession session) async {
    try {
      await CloudBackend.heartbeat(session);
    } on Exception catch (error) {
      _heartbeatTimer?.cancel();
      if (mounted) {
        setState(() {
          _session = null;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _signIn(String username, String password) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = await CloudBackend.login(
        role: widget.role,
        username: username,
        password: password,
      );
      if (mounted) _setSession(session);
    } on Exception catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _signOut() async {
    final session = _session;
    if (session == null) return;
    setState(() => _loading = true);
    try {
      await CloudBackend.logout(session);
      _heartbeatTimer?.cancel();
      if (mounted) {
        setState(() {
          _session = null;
          _loading = false;
          _error = null;
        });
      }
    } on Exception catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'تعذر تسجيل الخروج من الخادم: $error';
        });
      }
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_session case final session?) {
      Future<void> onLogout() async {
        await _signOut();
        if (context.mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      }

      if (session.role == 'superadmin') {
        return SuperAdminPage(session: session, onLogout: onLogout);
      }
      if (session.role == 'manager') {
        return EmployeesPage(
          store: EmployeeStore(cloudSession: session),
          userName: session.companyName,
          appTitle: 'تطبيق المدير',
          onLogout: onLogout,
        );
      }
      return EmployeeSelectionPage(
        store: EmployeeStore(cloudSession: session),
        onLogout: onLogout,
      );
    }
    if (!CloudBackend.isConfigured) {
      return const _BackendSetupPage();
    }
    return _CloudLoginPage(
      role: widget.role,
      error: _error,
      onLogin: _signIn,
    );
  }
}

class _BackendSetupPage extends StatelessWidget {
  const _BackendSetupPage();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('إعداد الاتصال')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'أضف SUPABASE_URL ومعه SUPABASE_PUBLISHABLE_KEY أو SUPABASE_ANON_KEY عند البناء.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}

class _CloudLoginPage extends StatefulWidget {
  const _CloudLoginPage({
    required this.role,
    required this.onLogin,
    this.error,
  });

  final String role;
  final String? error;
  final Future<void> Function(String username, String password) onLogin;

  @override
  State<_CloudLoginPage> createState() => _CloudLoginPageState();
}

class _CloudLoginPageState extends State<_CloudLoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _title => switch (widget.role) {
        'manager' => 'تسجيل دخول المدير',
        'employee' => 'ربط تطبيق الموظفين بالمؤسسة',
        _ => 'تسجيل دخول سوبر أدمن',
      };

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    await widget.onLogin(_username.text, _password.text);
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.business_outlined, size: 64),
                    const SizedBox(height: 16),
                    Text(_title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _username,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? 'أدخل اسم المستخدم'
                              : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'كلمة المرور',
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? 'أدخل كلمة المرور'
                          : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    if (widget.role == 'employee') ...[
                      const SizedBox(height: 12),
                      const Text(
                        'استخدم بيانات الموظفين التي أنشأها سوبر أدمن للمؤسسة. سيتم ربط هذا الجهاز بها.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (widget.error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        widget.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const CircularProgressIndicator()
                            : const Text('تسجيل الدخول'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class SuperAdminPage extends StatefulWidget {
  const SuperAdminPage({
    required this.session,
    required this.onLogout,
    super.key,
  });

  final CloudAppSession session;
  final Future<void> Function() onLogout;

  @override
  State<SuperAdminPage> createState() => _SuperAdminPageState();
}

class _SuperAdminPageState extends State<SuperAdminPage> {
  late Future<List<Map<String, dynamic>>> _companies;

  @override
  void initState() {
    super.initState();
    _companies = CloudDataStore(widget.session).listCompanies();
  }

  void _reload() {
    setState(() => _companies = CloudDataStore(widget.session).listCompanies());
  }

  Future<void> _editCompany([Map<String, dynamic>? company]) async {
    final details = await showDialog<_CompanyFormData>(
      context: context,
      builder: (_) => _CompanyEditorDialog(company: company),
    );
    if (details == null || !mounted) return;
    try {
      final store = CloudDataStore(widget.session);
      if (company == null) {
        await store.createCompany(
          name: details.name,
          employeeUsername: details.employeeUsername,
          employeePassword: details.employeePassword,
          managerUsername: details.managerUsername,
          managerPassword: details.managerPassword,
        );
      } else {
        await store.updateCompany(
          companyId: company['id'] as String,
          active: details.isActive,
          employeeUsername: details.employeeUsername,
          employeePassword: details.employeePassword,
          managerUsername: details.managerUsername,
          managerPassword: details.managerPassword,
        );
      }
      _reload();
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(companySaveErrorMessage(error))),
        );
      }
    }
  }

  Future<void> _toggleCompany(
    Map<String, dynamic> company,
    bool active,
  ) async {
    try {
      await CloudDataStore(widget.session).updateCompany(
        companyId: company['id'] as String,
        active: active,
        employeeUsername: company['employee_username'] as String,
        employeePassword: '',
        managerUsername: company['manager_username'] as String,
        managerPassword: '',
      );
      _reload();
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تغيير حالة المؤسسة: $error')),
        );
      }
    }
  }

  Future<void> _deleteCompany() async {
    late final List<Map<String, dynamic>> companies;
    try {
      companies = await CloudDataStore(widget.session).listCompanies();
    } on Exception catch (error) {
      if (mounted) {
        _showCompanyActionMessage('تعذر تحميل المؤسسات: $error');
      }
      return;
    }
    if (!mounted) return;
    if (companies.isEmpty) {
      _showCompanyActionMessage('لا توجد مؤسسات لحذفها');
      return;
    }

    final company = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('حذف مؤسسة'),
        content: SizedBox(
          width: 420,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: companies.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final company = companies[index];
              return ListTile(
                title: Text(company['name'] as String),
                subtitle: Text(
                  'الموظفين: ${company['employee_username']}  •  المدير: ${company['manager_username']}',
                ),
                onTap: () => Navigator.of(context).pop(company),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
    if (company == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: Text(
          'هل تريد حذف المؤسسة "${company['name']}" نهائيًا؟ سيتم حذف جميع الموظفين وسجلات الحضور والرواتب التابعة لها.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await CloudDataStore(widget.session)
          .deleteCompany(company['id'] as String);
      _reload();
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تعذر حذف المؤسسة: $error. نفّذ ترحيل 20261011130000_fix_superadmin_company_rpcs.sql في Supabase.',
            ),
          ),
        );
      }
    }
  }

  void _showCompanyActionMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: _homeAppBarTitle(
            widget.session.username,
            appTitle: 'سوبر أدمن',
          ),
          actions: [
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        floatingActionButton: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingActionButton.extended(
              heroTag: 'add-company',
              onPressed: _editCompany,
              icon: const Icon(Icons.add_business),
              label: const Text('إضافة مؤسسة'),
            ),
            const SizedBox(width: 8),
            FloatingActionButton.small(
              heroTag: 'delete-company',
              tooltip: 'حذف مؤسسة',
              onPressed: _deleteCompany,
              child: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _companies,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('تعذر تحميل المؤسسات'),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _reload,
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final companies = snapshot.data!;
            if (companies.isEmpty) {
              return const Center(
                child: Text('لا توجد مؤسسات بعد. أضف مؤسسة للبدء.'),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: companies.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final company = companies[index];
                final active = company['is_active'] as bool;
                return Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: Icon(
                          active ? Icons.business : Icons.business_outlined,
                        ),
                        subtitle: const Text('فتح مجلد المؤسسة'),
                        title: Text(company['name'] as String),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _CompanyFolderPage(
                                session: widget.session,
                                company: company,
                                onEdit: () => _editCompany(company),
                              ),
                            ),
                          );
                          if (mounted) _reload();
                        },
                        trailing: Switch(
                          value: active,
                          onChanged: (value) => _toggleCompany(company, value),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      );
}

class _CompanyFolderPage extends StatefulWidget {
  const _CompanyFolderPage({
    required this.session,
    required this.company,
    required this.onEdit,
  });

  final CloudAppSession session;
  final Map<String, dynamic> company;
  final Future<void> Function() onEdit;

  @override
  State<_CompanyFolderPage> createState() => _CompanyFolderPageState();
}

class _CompanyFolderPageState extends State<_CompanyFolderPage> {
  late Map<String, dynamic> _company;
  late Future<List<Map<String, dynamic>>> _employees;

  @override
  void initState() {
    super.initState();
    _company = widget.company;
    _employees = _loadEmployees();
  }

  Future<List<Map<String, dynamic>>> _loadEmployees() =>
      CloudDataStore(widget.session)
          .listCompanyEmployees(_company['id'] as String);

  Future<void> _editCredentials() async {
    await widget.onEdit();
    if (!mounted) return;
    try {
      final companies = await CloudDataStore(widget.session).listCompanies();
      final updated = companies.where(
        (company) => company['id'] == _company['id'],
      );
      if (updated.isNotEmpty && mounted) {
        setState(() => _company = updated.first);
      }
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحديث بيانات المؤسسة: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Icon(Icons.folder_open_outlined),
              const SizedBox(width: 8),
              Expanded(child: Text(_company['name'] as String)),
            ],
          ),
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _employees,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('تعذر تحميل بيانات المؤسسة'),
                    const SizedBox(height: 8),
                    const Text(
                      'نفّذ ترحيل 20261011130000_fix_superadmin_company_rpcs.sql في Supabase ثم أعد المحاولة.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      'تفاصيل الخطأ: ${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => setState(
                        () => _employees = _loadEmployees(),
                      ),
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final employees = snapshot.data!;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _company['name'] as String,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            IconButton(
                              tooltip: 'تعديل اسم المستخدم وكلمات المرور',
                              onPressed: _editCredentials,
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ],
                        ),
                        const Divider(),
                        const Text(
                          'حساب الموظفين',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SelectableText(
                          'المستخدم: ${_company['employee_username']}',
                        ),
                        SelectableText(
                          'كلمة المرور: ${_company['employee_password']}',
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'حساب المدير',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SelectableText(
                          'المستخدم: ${_company['manager_username']}',
                        ),
                        SelectableText(
                          'كلمة المرور: ${_company['manager_password']}',
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: OutlinedButton.icon(
                            onPressed: _editCredentials,
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('تعديل بيانات الدخول'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'الموظفون',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (employees.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        'لا يوجد موظفون في هذه المؤسسة حتى الآن.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else
                  for (final employee in employees)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(employee['name'] as String),
                        subtitle: const Text('فتح مجلد الموظف وسجلاته'),
                        trailing: const Icon(Icons.chevron_left),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _EmployeeFolderPage(
                                session: widget.session,
                                employee: employee,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
              ],
            );
          },
        ),
      );
}

class _EmployeeFolderPage extends StatefulWidget {
  const _EmployeeFolderPage({
    required this.session,
    required this.employee,
  });

  final CloudAppSession session;
  final Map<String, dynamic> employee;

  @override
  State<_EmployeeFolderPage> createState() => _EmployeeFolderPageState();
}

class _EmployeeFolderPageState extends State<_EmployeeFolderPage> {
  late Future<List<MonthRecord>> _months;

  Future<List<MonthRecord>> _loadMonths() async {
    final records = await CloudDataStore(widget.session)
        .listEmployeeMonthsForSuperadmin(widget.employee['id'] as String);
    return records.map(MonthRecord.fromJson).toList();
  }

  @override
  void initState() {
    super.initState();
    _months = _loadMonths();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Icon(Icons.folder_open_outlined),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.employee['name'] as String)),
            ],
          ),
        ),
        body: FutureBuilder<List<MonthRecord>>(
          future: _months,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('تعذر تحميل سجلات الموظف'),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => setState(() => _months = _loadMonths()),
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final months = snapshot.data!;
            if (months.isEmpty) {
              return const Center(
                child: Text('لا توجد سجلات حضور لهذا الموظف حتى الآن.'),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: months.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final month = months[index];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(
                      DateFormat('MMMM yyyy', 'ar')
                          .format(DateTime(month.year, month.month)),
                    ),
                    subtitle: Text(
                      'إجمالي الساعات: ${_formatNumber(month.totalHours)}',
                    ),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => MonthPage(
                            month: month,
                            store: MonthStore(readOnlyMonths: months),
                            readOnly: true,
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            );
          },
        ),
      );
}

String companySaveErrorMessage(Object error) {
  final details = error.toString();
  if (details.contains('companies_employee_username_key')) {
    return 'اسم مستخدم الموظفين مستخدم بالفعل. اختر اسمًا آخر.';
  }
  if (details.contains('companies_manager_username_key')) {
    return 'اسم مستخدم المدير مستخدم بالفعل. اختر اسمًا آخر.';
  }
  if (details.contains('companies_name_key')) {
    return 'اسم المؤسسة مستخدم بالفعل. اختر اسمًا آخر.';
  }
  return 'تعذر حفظ بيانات المؤسسة: $error';
}

class _CompanyFormData {
  const _CompanyFormData({
    required this.name,
    required this.employeeUsername,
    required this.employeePassword,
    required this.managerUsername,
    required this.managerPassword,
    required this.isActive,
  });

  final String name;
  final String employeeUsername;
  final String employeePassword;
  final String managerUsername;
  final String managerPassword;
  final bool? isActive;
}

class _CompanyEditorDialog extends StatefulWidget {
  const _CompanyEditorDialog({this.company});

  final Map<String, dynamic>? company;

  @override
  State<_CompanyEditorDialog> createState() => _CompanyEditorDialogState();
}

class _CompanyEditorDialogState extends State<_CompanyEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _employeeUsername;
  late final TextEditingController _employeePassword;
  late final TextEditingController _managerUsername;
  late final TextEditingController _managerPassword;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    final company = widget.company;
    _name = TextEditingController(text: company?['name'] as String? ?? '');
    _employeeUsername = TextEditingController(
      text: company?['employee_username'] as String? ?? '',
    );
    _employeePassword = TextEditingController(
      text: company?['employee_password'] as String? ?? '',
    );
    _managerUsername = TextEditingController(
      text: company?['manager_username'] as String? ?? '',
    );
    _managerPassword = TextEditingController(
      text: company?['manager_password'] as String? ?? '',
    );
    _active = company?['is_active'] as bool? ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _employeeUsername.dispose();
    _employeePassword.dispose();
    _managerUsername.dispose();
    _managerPassword.dispose();
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'هذا الحقل مطلوب' : null;

  String? _passwordValidator(String? value) {
    if (widget.company != null && (value == null || value.isEmpty)) return null;
    if (value == null || value.length < 8) {
      return 'كلمة المرور 8 أحرف على الأقل';
    }
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      _CompanyFormData(
        name: _name.text.trim(),
        employeeUsername: _employeeUsername.text.trim(),
        employeePassword: _employeePassword.text,
        managerUsername: _managerUsername.text.trim(),
        managerPassword: _managerPassword.text,
        isActive: widget.company == null ? null : _active,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.company == null ? 'إضافة مؤسسة' : 'إعدادات المؤسسة'),
        content: SizedBox(
          width: 520,
          child: Theme(
            data: Theme.of(context).copyWith(
              inputDecorationTheme:
                  Theme.of(context).inputDecorationTheme.copyWith(
                        isDense: false,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 18,
                        ),
                      ),
            ),
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.company == null) ...[
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'اسم المؤسسة',
                        ),
                        validator: _required,
                      ),
                      const SizedBox(height: 18),
                    ],
                    TextFormField(
                      controller: _employeeUsername,
                      decoration: const InputDecoration(
                        labelText: 'اسم مستخدم الموظفين',
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _employeePassword,
                      decoration: InputDecoration(
                        labelText: widget.company == null
                            ? 'كلمة مرور الموظفين'
                            : 'كلمة مرور جديدة للموظفين (اختياري)',
                      ),
                      validator: _passwordValidator,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _managerUsername,
                      decoration: const InputDecoration(
                        labelText: 'اسم مستخدم المدير',
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _managerPassword,
                      decoration: InputDecoration(
                        labelText: widget.company == null
                            ? 'كلمة مرور المدير'
                            : 'كلمة مرور جديدة للمدير (اختياري)',
                      ),
                      validator: _passwordValidator,
                    ),
                    if (widget.company != null) ...[
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('المؤسسة مفعلة'),
                        value: _active,
                        onChanged: (value) => setState(() => _active = value),
                      ),
                    ],
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'تُشفّر كلمات المرور في قاعدة البيانات بمفتاح محفوظ في Supabase Vault.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: _submit,
            child: Text(widget.company == null ? 'إنشاء المؤسسة' : 'حفظ'),
          ),
        ],
      );
}

class SharedSalaryDirectory {
  static Future<Directory> get() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory('${documents.path}/salary_shared_data');
    await directory.create(recursive: true);
    return directory;
  }
}

class AppSettingsStore {
  AppSettingsStore({this.role, this.shared = false});

  final AppRole? role;
  final bool shared;

  Future<File> _settingsFile() async {
    if (shared) {
      final directory = await SharedSalaryDirectory.get();
      final settings = Directory('${directory.path}/settings');
      await settings.create(recursive: true);
      return File('${settings.path}/${role!.name}_settings.json');
    }
    final documents = await getApplicationDocumentsDirectory();
    return File('${documents.path}/app_settings.json');
  }

  Future<AppSettings?> loadSettings() async {
    final file = await _settingsFile();
    if (!await file.exists()) return null;
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final role = switch (decoded['role']) {
      'employee' => AppRole.employee,
      'manager' => AppRole.manager,
      _ => null,
    };
    if (role == null || (this.role != null && role != this.role)) return null;
    return AppSettings(
      role: role,
      name: (decoded['name'] as String?)?.trim(),
    );
  }

  Future<void> saveSettings(AppRole role, String name) async {
    final file = await _settingsFile();
    await file.writeAsString(
      jsonEncode({'role': role.name, 'name': name}),
      flush: true,
    );
  }
}

class AppSettings {
  const AppSettings({required this.role, required this.name});

  final AppRole role;
  final String? name;
}

class RoleGate extends StatefulWidget {
  const RoleGate({this.fixedRole, super.key});

  final AppRole? fixedRole;

  @override
  State<RoleGate> createState() => _RoleGateState();
}

class _RoleGateState extends State<RoleGate> {
  late final AppSettingsStore _settings;
  late Future<AppSettings?> _settingsFuture;
  bool _promptingForName = false;

  @override
  void initState() {
    super.initState();
    _settings = AppSettingsStore(
      role: widget.fixedRole,
      shared: widget.fixedRole != null,
    );
    _settingsFuture = widget.fixedRole == AppRole.employee
        ? Future.value(null)
        : _settings.loadSettings();
  }

  Future<void> _selectRole(AppRole role) async {
    final name = await _requestName();
    if (name == null) return;
    await _settings.saveSettings(role, name);
    if (mounted) {
      setState(() {
        _settingsFuture = Future.value(AppSettings(role: role, name: name));
      });
    }
  }

  Future<String?> _requestName() => showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _UserNameDialog(),
      );

  void _requestMissingName(AppRole role) {
    if (_promptingForName) return;
    _promptingForName = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final name = await _requestName();
      if (name != null) {
        try {
          await _settings.saveSettings(role, name);
          if (mounted) {
            setState(() {
              _settingsFuture = Future.value(
                AppSettings(role: role, name: name),
              );
            });
          }
        } on FileSystemException catch (error) {
          if (mounted) {
            setState(() => _settingsFuture = Future.value(null));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('تعذر حفظ الاسم: ${error.message}')),
            );
          }
        }
      }
      _promptingForName = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fixedRole == AppRole.employee) {
      return const CloudRoleGate(role: 'employee');
    }
    if (widget.fixedRole == AppRole.manager) {
      return const CloudRoleGate(role: 'manager');
    }
    if (widget.fixedRole == AppRole.superadmin) {
      return const CloudRoleGate(role: 'superadmin');
    }
    return FutureBuilder<AppSettings?>(
      future: _settingsFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Scaffold(
            body: Center(child: Text('تعذر تحميل إعدادات التطبيق')),
          );
        }
        if (!snapshot.hasData &&
            snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final settings = snapshot.data;
        if (settings != null) {
          final role = settings.role;
          final name = settings.name;
          if (name == null || name.isEmpty) {
            _requestMissingName(role);
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (role == AppRole.manager) {
            return EmployeesPage(
              store: widget.fixedRole == AppRole.manager
                  ? EmployeeStore(shared: true)
                  : null,
              userName: name,
            );
          }
          if (role == AppRole.employee) return MonthsPage(userName: name);
        }
        return RoleSelectionPage(
          fixedRole: widget.fixedRole,
          onSelectRole: _selectRole,
        );
      },
    );
  }
}

class _UserNameDialog extends StatefulWidget {
  const _UserNameDialog();

  @override
  State<_UserNameDialog> createState() => _UserNameDialogState();
}

class _UserNameDialogState extends State<_UserNameDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_nameController.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('من فضلك أدخل اسمك'),
        content: Form(
          key: _formKey,
          child: TextFormField(
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'الاسم'),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'اكتب اسمك للمتابعة'
                : null,
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: _submit,
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
  }
}

class RoleSelectionPage extends StatefulWidget {
  const RoleSelectionPage({
    required this.onSelectRole,
    this.fixedRole,
    super.key,
  });

  final Future<void> Function(AppRole role) onSelectRole;
  final AppRole? fixedRole;

  @override
  State<RoleSelectionPage> createState() => _RoleSelectionPageState();
}

class _RoleSelectionPageState extends State<RoleSelectionPage> {
  bool _saving = false;
  String? _error;

  Future<void> _selectRole(AppRole role) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSelectRole(role);
    } on FileSystemException catch (error) {
      if (mounted) {
        setState(() => _error = 'تعذر حفظ الاختيار: ${error.message}');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('salary')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.badge_outlined, size: 64),
              const SizedBox(height: 16),
              Text(
                widget.fixedRole == AppRole.manager
                    ? 'تسجيل دخول المدير'
                    : 'اختار طريقة الاستخدام',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              if (widget.fixedRole != AppRole.manager)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed:
                        _saving ? null : () => _selectRole(AppRole.employee),
                    icon: const Icon(Icons.person_outline),
                    label: const Text('استخدام موظف'),
                  ),
                ),
              if (widget.fixedRole != AppRole.manager)
                const SizedBox(height: 12),
              if (widget.fixedRole != AppRole.employee)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed:
                        _saving ? null : () => _selectRole(AppRole.manager),
                    icon: const Icon(Icons.manage_accounts_outlined),
                    label: Text(
                      widget.fixedRole == AppRole.manager
                          ? 'متابعة كمدير'
                          : 'استخدام مدير',
                    ),
                  ),
                ),
              if (_saving) ...[
                const SizedBox(height: 16),
                const CircularProgressIndicator(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class EmployeeRecord {
  const EmployeeRecord({
    required this.id,
    required this.name,
    this.hasPassword = false,
  });

  final String id;
  final String name;
  final bool hasPassword;

  factory EmployeeRecord.fromJson(Map<String, dynamic> json) => EmployeeRecord(
        id: json['id'] as String,
        name: json['name'] as String,
        hasPassword: json['has_password'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'has_password': hasPassword,
      };
}

Widget _homeAppBarTitle(String? userName, {String appTitle = 'salary'}) {
  final greeting =
      userName == null || userName.isEmpty ? 'مرحبًا' : 'مرحبًا، $userName';
  return Row(
    children: [
      Expanded(
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            appTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10),
          ),
        ),
      ),
      Expanded(
        flex: 2,
        child: Center(
          child: Text(
            greeting,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ),
      const Expanded(
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Text(
            'Made by Moro',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.grey,
              fontSize: 10,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ],
  );
}

class EmployeeStore {
  EmployeeStore({this.directory, this.shared = false, this.cloudSession});

  final Directory? directory;
  final bool shared;
  final CloudAppSession? cloudSession;

  Future<Directory> _employeesDirectory() async {
    final customDirectory = directory;
    if (customDirectory != null) {
      await customDirectory.create(recursive: true);
      return customDirectory;
    }
    if (shared) {
      final root = await SharedSalaryDirectory.get();
      final employees = Directory('${root.path}/employees');
      await employees.create(recursive: true);
      return employees;
    }
    final documents = await getApplicationDocumentsDirectory();
    final employeeDirectory = Directory('${documents.path}/employees');
    await employeeDirectory.create(recursive: true);
    return employeeDirectory;
  }

  Future<List<EmployeeRecord>> loadEmployees() async {
    final cloud = cloudSession;
    if (cloud != null) {
      final records = await CloudDataStore(cloud).loadEmployees();
      return records.map((record) => EmployeeRecord.fromJson(record)).toList();
    }
    final root = await _employeesDirectory();
    final entities = await root.list(followLinks: false).toList();
    final employees = <EmployeeRecord>[];
    for (final entity in entities.whereType<Directory>()) {
      final file = File('${entity.path}/employee.json');
      if (!await file.exists()) continue;
      final decoded = jsonDecode(await file.readAsString());
      employees.add(
        EmployeeRecord.fromJson(decoded as Map<String, dynamic>),
      );
    }
    employees.sort(
      (first, second) =>
          first.name.toLowerCase().compareTo(second.name.toLowerCase()),
    );
    return employees;
  }

  Future<EmployeeRecord> createEmployee(String name) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Employee name is required');
    }
    final cloud = cloudSession;
    if (cloud != null) {
      return EmployeeRecord.fromJson(
        await CloudDataStore(cloud).createEmployee(normalizedName),
      );
    }
    final root = await _employeesDirectory();
    final safeName = Uri.encodeComponent(normalizedName)
        .replaceAll('.', '%2E')
        .replaceAll(RegExp(r'[^A-Za-z0-9_%\-]'), '_');
    final id = '$safeName-${DateTime.now().microsecondsSinceEpoch}';
    final employee = EmployeeRecord(id: id, name: normalizedName);
    final directory = Directory('${root.path}/$id');
    await directory.create(recursive: true);
    await File('${directory.path}/employee.json').writeAsString(
      jsonEncode(employee.toJson()),
      flush: true,
    );
    await Directory('${directory.path}/months').create(recursive: true);
    return employee;
  }

  Future<bool> employeeHasPassword(String employeeId) async {
    final cloud = cloudSession;
    if (cloud == null || cloud.role != 'employee') {
      throw StateError('Employee password settings require an employee login');
    }
    return CloudDataStore(cloud).employeeHasPassword(employeeId);
  }

  Future<bool> verifyEmployeePassword(
    String employeeId,
    String password,
  ) async {
    final cloud = cloudSession;
    if (cloud == null || cloud.role != 'employee') {
      throw StateError(
          'Employee password verification requires an employee login');
    }
    return CloudDataStore(cloud).verifyEmployeePassword(
      employeeId: employeeId,
      password: password,
    );
  }

  Future<bool> updateEmployeePassword({
    required String employeeId,
    required String currentPassword,
    required String newPassword,
  }) async {
    final cloud = cloudSession;
    if (cloud == null || cloud.role != 'employee') {
      throw StateError('Employee password settings require an employee login');
    }
    return CloudDataStore(cloud).updateEmployeePassword(
      employeeId: employeeId,
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  Future<void> deleteEmployee(EmployeeRecord employee) async {
    final cloud = cloudSession;
    if (cloud != null) {
      await CloudDataStore(cloud).deleteEmployee(employee.id);
      return;
    }
    final root = await _employeesDirectory();
    final directory = Directory('${root.path}/${employee.id}');
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<Directory> monthsDirectory(EmployeeRecord employee) async {
    if (!RegExp(r'^[A-Za-z0-9_%\-]+$').hasMatch(employee.id)) {
      throw ArgumentError.value(
          employee.id, 'employee.id', 'Invalid employee ID');
    }
    final root = await _employeesDirectory();
    final directory = Directory('${root.path}/${employee.id}/months');
    await directory.create(recursive: true);
    return directory;
  }
}

class EmployeeSelectionPage extends StatefulWidget {
  const EmployeeSelectionPage({required this.store, this.onLogout, super.key});

  final EmployeeStore store;
  final Future<void> Function()? onLogout;

  @override
  State<EmployeeSelectionPage> createState() => _EmployeeSelectionPageState();
}

class _EmployeeSelectionPageState extends State<EmployeeSelectionPage> {
  late Future<List<EmployeeRecord>> _employeesFuture;

  @override
  void initState() {
    super.initState();
    _employeesFuture = widget.store.loadEmployees();
  }

  Future<void> _openEmployee(EmployeeRecord employee) async {
    try {
      final cloud = widget.store.cloudSession;
      if (cloud != null && cloud.role == 'employee') {
        final hasPassword = await widget.store.employeeHasPassword(employee.id);
        if (!mounted) return;
        if (hasPassword) {
          final password = await showDialog<String>(
            context: context,
            builder: (_) => _EmployeeFolderPasswordDialog(
              employeeName: employee.name,
            ),
          );
          if (password == null || !mounted) return;
          final verified = await widget.store.verifyEmployeePassword(
            employee.id,
            password,
          );
          if (!mounted) return;
          if (!verified) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('كلمة مرور الموظف غير صحيحة')),
            );
            return;
          }
        }
      }
      final directory = widget.store.cloudSession == null
          ? await widget.store.monthsDirectory(employee)
          : null;
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MonthsPage(
            store: directory != null
                ? MonthStore(directory: directory)
                : MonthStore(
                    cloudSession: widget.store.cloudSession,
                    employeeId: employee.id,
                  ),
            userName: employee.name,
            appTitle: 'تطبيق الموظفين',
            employeeMode: true,
            onLogout: widget.onLogout,
          ),
        ),
      );
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر فتح سجل الموظف: ${error.message}')),
        );
      }
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر فتح سجل الموظف: $error')),
        );
      }
    }
  }

  Future<void> _manageEmployeePasswords() async {
    final cloud = widget.store.cloudSession;
    if (cloud == null || cloud.role != 'employee') return;

    late final List<EmployeeRecord> employees;
    try {
      employees = await widget.store.loadEmployees();
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحميل قائمة الموظفين: $error')),
        );
      }
      return;
    }
    if (!mounted) return;
    if (employees.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد موظفون لإعداد كلمات مرورهم')),
      );
      return;
    }

    final employee = await showModalBottomSheet<EmployeeRecord>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'اختار الموظف لإعداد كلمة المرور',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            for (final employee in employees)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(employee.name),
                subtitle: Text(
                  employee.hasPassword
                      ? 'تعديل أو مسح كلمة المرور'
                      : 'تعيين كلمة مرور',
                ),
                onTap: () => Navigator.of(context).pop(employee),
              ),
          ],
        ),
      ),
    );
    if (employee == null || !mounted) return;

    late final bool hasPassword;
    try {
      hasPassword = await widget.store.employeeHasPassword(employee.id);
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر التحقق من كلمة المرور: $error')),
        );
      }
      return;
    }
    if (!mounted) return;
    final selectedEmployee = EmployeeRecord(
      id: employee.id,
      name: employee.name,
      hasPassword: hasPassword,
    );

    final currentPassword =
        await _readCurrentEmployeePassword(selectedEmployee);
    if (currentPassword == null || !mounted) return;
    if (hasPassword) {
      late final bool verified;
      try {
        verified = await widget.store.verifyEmployeePassword(
          employee.id,
          currentPassword,
        );
      } on Exception catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تعذر التحقق من كلمة المرور: $error')),
          );
        }
        return;
      }
      if (!mounted) return;
      if (!verified) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('كلمة المرور الحالية غير صحيحة')),
        );
        return;
      }
    }
    final newPassword = await showDialog<_EmployeePasswordChange>(
      context: context,
      builder: (_) => _EmployeePasswordSettingsDialog(
        employeeName: selectedEmployee.name,
        hasPassword: hasPassword,
      ),
    );
    if (newPassword == null || !mounted) return;

    try {
      await widget.store.updateEmployeePassword(
        employeeId: employee.id,
        currentPassword: currentPassword,
        newPassword: newPassword.password,
      );
      if (!mounted) return;
      setState(() => _employeesFuture = widget.store.loadEmployees());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newPassword.password.isEmpty
                ? 'تم مسح كلمة مرور ${employee.name}'
                : 'تم حفظ كلمة مرور ${employee.name}',
          ),
        ),
      );
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحديث كلمة المرور: $error')),
        );
      }
    }
  }

  Future<String?> _readCurrentEmployeePassword(EmployeeRecord employee) async {
    if (!employee.hasPassword) return '';
    return showDialog<String>(
      context: context,
      builder: (_) => _CurrentEmployeePasswordDialog(
        employeeName: employee.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تطبيق الموظفين'),
        actions: [
          IconButton(
            tooltip: 'تحديث قائمة الموظفين',
            onPressed: () {
              setState(() {
                _employeesFuture = widget.store.loadEmployees();
              });
            },
            icon: const Icon(Icons.refresh),
          ),
          if (widget.onLogout != null)
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      bottomNavigationBar: widget.store.cloudSession?.role == 'employee'
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  16,
                  8,
                  16,
                  12,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  heightFactor: 1,
                  child: OutlinedButton.icon(
                    onPressed: _manageEmployeePasswords,
                    icon: const Icon(Icons.password_outlined),
                    label: const Text('إعدادات الباسورد'),
                  ),
                ),
              ),
            )
          : null,
      body: FutureBuilder<List<EmployeeRecord>>(
        future: _employeesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('تعذر تحميل قائمة الموظفين'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final employees = snapshot.data!;
          if (employees.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.people_outline, size: 64),
                    SizedBox(height: 16),
                    Text(
                      'لا يوجد موظفون مضافون بعد.\nافتح تطبيق المدير لإضافة الموظفين أولًا.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: employees.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final employee = employees[index];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person_outline),
                  ),
                  title: Text(employee.name),
                  subtitle: const Text('فتح سجل الحضور وساعات العمل'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => _openEmployee(employee),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class EmployeesPage extends StatefulWidget {
  const EmployeesPage({
    super.key,
    this.store,
    this.userName,
    this.appTitle = 'salary',
    this.onLogout,
  });

  final EmployeeStore? store;
  final String? userName;
  final String appTitle;
  final Future<void> Function()? onLogout;

  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeeNameDialog extends StatefulWidget {
  const _EmployeeNameDialog();

  @override
  State<_EmployeeNameDialog> createState() => _EmployeeNameDialogState();
}

class _EmployeeNameDialogState extends State<_EmployeeNameDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_nameController.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة موظف'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'اسم الموظف'),
          validator: (value) =>
              value == null || value.trim().isEmpty ? 'اكتب اسم الموظف' : null,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('إضافة'),
        ),
      ],
    );
  }
}

class _EmployeeFolderPasswordDialog extends StatefulWidget {
  const _EmployeeFolderPasswordDialog({required this.employeeName});

  final String employeeName;

  @override
  State<_EmployeeFolderPasswordDialog> createState() =>
      _EmployeeFolderPasswordDialogState();
}

class _EmployeeFolderPasswordDialogState
    extends State<_EmployeeFolderPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('كلمة مرور ${widget.employeeName}'),
        content: Form(
          key: _formKey,
          child: TextFormField(
            controller: _password,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'كلمة المرور'),
            validator: (value) =>
                value == null || value.isEmpty ? 'أدخل كلمة المرور' : null,
            onFieldSubmitted: (_) {
              if (_formKey.currentState!.validate()) {
                Navigator.of(context).pop(_password.text);
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              if (_formKey.currentState!.validate()) {
                Navigator.of(context).pop(_password.text);
              }
            },
            child: const Text('فتح المجلد'),
          ),
        ],
      );
}

class _CurrentEmployeePasswordDialog extends StatefulWidget {
  const _CurrentEmployeePasswordDialog({required this.employeeName});

  final String employeeName;

  @override
  State<_CurrentEmployeePasswordDialog> createState() =>
      _CurrentEmployeePasswordDialogState();
}

class _CurrentEmployeePasswordDialogState
    extends State<_CurrentEmployeePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('تأكيد كلمة مرور ${widget.employeeName}'),
        content: Form(
          key: _formKey,
          child: TextFormField(
            controller: _password,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'كلمة المرور الحالية',
            ),
            validator: (value) => value == null || value.isEmpty
                ? 'أدخل كلمة المرور الحالية'
                : null,
            onFieldSubmitted: (_) {
              if (_formKey.currentState!.validate()) {
                Navigator.of(context).pop(_password.text);
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              if (_formKey.currentState!.validate()) {
                Navigator.of(context).pop(_password.text);
              }
            },
            child: const Text('متابعة'),
          ),
        ],
      );
}

class _EmployeePasswordChange {
  const _EmployeePasswordChange(this.password);

  final String password;
}

String? employeePasswordValidation(String password, String confirmation) {
  if (password.length < 6) {
    return 'كلمة المرور يجب أن تكون 6 أحرف على الأقل';
  }
  if (password != confirmation) {
    return 'كلمتا المرور غير متطابقتين';
  }
  return null;
}

class _EmployeePasswordSettingsDialog extends StatefulWidget {
  const _EmployeePasswordSettingsDialog({
    required this.employeeName,
    required this.hasPassword,
  });

  final String employeeName;
  final bool hasPassword;

  @override
  State<_EmployeePasswordSettingsDialog> createState() =>
      _EmployeePasswordSettingsDialogState();
}

class _EmployeePasswordSettingsDialogState
    extends State<_EmployeePasswordSettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  String? _validatePassword(String? value) {
    if (value == null || value.length < 6) {
      return 'كلمة المرور يجب أن تكون 6 أحرف على الأقل';
    }
    return null;
  }

  String? _validateConfirmation(String? value) {
    return employeePasswordValidation(_password.text, value ?? '');
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_EmployeePasswordChange(_password.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
          widget.hasPassword
              ? 'تعديل كلمة مرور ${widget.employeeName}'
              : 'تعيين كلمة مرور ${widget.employeeName}',
        ),
        content: SizedBox(
          width: 420,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _password,
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور الجديدة',
                  ),
                  validator: _validatePassword,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _confirmation,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'تأكيد كلمة المرور',
                  ),
                  validator: _validateConfirmation,
                  onFieldSubmitted: (_) => _save(),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          if (widget.hasPassword)
            TextButton(
              onPressed: () => Navigator.of(context).pop(
                const _EmployeePasswordChange(''),
              ),
              child: const Text('مسح كلمة المرور'),
            ),
          FilledButton(
            onPressed: _save,
            child: const Text('حفظ'),
          ),
        ],
      );
}

enum AttendanceMode { manual, required }

class _AttendanceModeDialog extends StatefulWidget {
  const _AttendanceModeDialog({required this.session});

  final CloudAppSession session;

  @override
  State<_AttendanceModeDialog> createState() => _AttendanceModeDialogState();
}

class _AttendanceModeDialogState extends State<_AttendanceModeDialog> {
  late Future<AttendanceMode> _mode;
  AttendanceMode? _selected;
  bool _saving = false;

  Future<AttendanceMode> _loadMode() async {
    final mode = await CloudDataStore(widget.session).getAttendanceMode();
    return mode == 'required' ? AttendanceMode.required : AttendanceMode.manual;
  }

  @override
  void initState() {
    super.initState();
    _mode = _loadMode();
  }

  Future<void> _save() async {
    final selected = _selected;
    if (selected == null) return;
    setState(() => _saving = true);
    try {
      await CloudDataStore(widget.session).setAttendanceMode(
        selected == AttendanceMode.required ? 'required' : 'manual',
      );
      if (mounted) Navigator.of(context).pop(selected);
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تغيير نظام الحضور: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('نظام الحضور'),
        content: FutureBuilder<AttendanceMode>(
          future: _mode,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('تعذر تحميل نظام الحضور الحالي'),
                  TextButton(
                    onPressed: () => setState(() => _mode = _loadMode()),
                    child: const Text('إعادة المحاولة'),
                  ),
                ],
              );
            }
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 72,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final selected = _selected ?? snapshot.data!;
            return RadioGroup<AttendanceMode>(
              groupValue: selected,
              onChanged: (value) => setState(() => _selected = value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const RadioListTile<AttendanceMode>(
                    contentPadding: EdgeInsets.zero,
                    value: AttendanceMode.manual,
                    title: Text('اختياري - تسجيل يدوي'),
                    subtitle: Text(
                      'يختار الموظف تاريخ الحضور والانصراف ويدخل الأوقات يدويًا.',
                    ),
                  ),
                  const RadioListTile<AttendanceMode>(
                    contentPadding: EdgeInsets.zero,
                    value: AttendanceMode.required,
                    title: Text('إجباري - تسجيل تلقائي'),
                    subtitle: Text(
                      'يسجل الموظف حضور وانصراف اليوم فقط، ويحدد الخادم الوقت تلقائيًا.',
                    ),
                  ),
                  const Text(
                    'تغيير النظام لا يحذف أو يعدل أي بيانات حضور سابقة.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: _saving || _selected == null ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('حفظ النظام'),
          ),
        ],
      );
}

class _EmployeesPageState extends State<EmployeesPage> {
  late final EmployeeStore _employeeStore;
  late Future<List<EmployeeRecord>> _employeesFuture;

  @override
  void initState() {
    super.initState();
    _employeeStore = widget.store ?? EmployeeStore();
    _employeesFuture = _employeeStore.loadEmployees();
  }

  Future<void> _addEmployee() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _EmployeeNameDialog(),
    );
    if (name == null || !mounted) return;

    try {
      await _employeeStore.createEmployee(name);
      if (!mounted) return;
      setState(() {
        _employeesFuture = _employeeStore.loadEmployees();
      });
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر إضافة الموظف: ${error.message}');
    } on Exception catch (error) {
      if (mounted) _showMessage('تعذر إضافة الموظف: $error');
    }
  }

  Future<void> _deleteEmployee() async {
    late final List<EmployeeRecord> employees;
    try {
      employees = await _employeeStore.loadEmployees();
    } on Exception catch (error) {
      if (mounted) _showMessage('تعذر تحميل الموظفين: $error');
      return;
    }
    if (!mounted) return;
    if (employees.isEmpty) {
      _showMessage('لا توجد موظفين لحذفهم');
      return;
    }

    final employee = await showDialog<EmployeeRecord>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('حذف موظف'),
        content: SizedBox(
          width: 360,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: employees.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final employee = employees[index];
              return ListTile(
                title: Text(employee.name),
                onTap: () => Navigator.of(context).pop(employee),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
    if (employee == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: Text(
          'هل تريد حذف الموظف "${employee.name}" نهائيًا؟ سيتم حذف سجلات حضوره ورواتبه.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _employeeStore.deleteEmployee(employee);
      if (!mounted) return;
      setState(() {
        _employeesFuture = _employeeStore.loadEmployees();
      });
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر حذف الموظف: ${error.message}');
    } on Exception catch (error) {
      if (mounted) _showMessage('تعذر حذف الموظف: $error');
    }
  }

  Future<void> _openEmployee(EmployeeRecord employee) async {
    try {
      final directory = _employeeStore.cloudSession == null
          ? await _employeeStore.monthsDirectory(employee)
          : null;
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MonthsPage(
            store: directory != null
                ? MonthStore(directory: directory)
                : MonthStore(
                    cloudSession: _employeeStore.cloudSession,
                    employeeId: employee.id,
                  ),
            userName: widget.userName,
            appTitle: widget.appTitle,
            onLogout: widget.onLogout,
          ),
        ),
      );
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر فتح سجل الموظف: ${error.message}');
    } on Exception catch (error) {
      if (mounted) _showMessage('تعذر فتح سجل الموظف: $error');
    }
  }

  Future<void> _configureAttendanceMode() async {
    final session = _employeeStore.cloudSession;
    if (session == null || session.role != 'manager') return;
    final selected = await showDialog<AttendanceMode>(
      context: context,
      builder: (_) => _AttendanceModeDialog(session: session),
    );
    if (selected != null && mounted) {
      _showMessage(
        selected == AttendanceMode.required
            ? 'تم تفعيل نظام الحضور الإجباري. البيانات السابقة محفوظة.'
            : 'تم تفعيل التسجيل اليدوي. البيانات السابقة محفوظة.',
      );
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _homeAppBarTitle(widget.userName, appTitle: widget.appTitle),
        actions: [
          if (widget.onLogout != null)
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      bottomNavigationBar: _employeeStore.cloudSession?.role == 'manager'
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  16,
                  8,
                  16,
                  12,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  heightFactor: 1,
                  child: OutlinedButton.icon(
                    onPressed: _configureAttendanceMode,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('نظام الحضور'),
                  ),
                ),
              ),
            )
          : null,
      floatingActionButton: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          FloatingActionButton.extended(
            heroTag: 'add-employee',
            onPressed: _addEmployee,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('إضافة موظف'),
          ),
          FloatingActionButton.small(
            heroTag: 'delete-employee',
            tooltip: 'حذف موظف',
            onPressed: _deleteEmployee,
            child: const Icon(Icons.delete_outline),
          ),
          FloatingActionButton.small(
            heroTag: 'manager-info',
            tooltip: 'الإنفو',
            onPressed: () => _showInfoDialog(context),
            child: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: FutureBuilder<List<EmployeeRecord>>(
        future: _employeesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('حصلت مشكلة أثناء تحميل الموظفين'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final employees = snapshot.data!;
          if (employees.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.people_outline, size: 64),
                    SizedBox(height: 16),
                    Text(
                      'مفيش موظفين مضافين لسه\nاضغط «إضافة موظف» للبدء',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: employees.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final employee = employees[index];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person_outline),
                  ),
                  title: Text(employee.name),
                  subtitle: const Text('فتح سجل الرواتب'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => _openEmployee(employee),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

Future<void> _showInfoDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (context) => DefaultTabController(
      length: 2,
      child: Dialog(
        child: SizedBox(
          height: 360,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'الإنفو',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'إغلاق',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'عن التطبيق'),
                  Tab(text: 'عن المطور'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(_appDescription),
                          const Spacer(),
                          Text(
                            'تاريخ الإصدار: ${DateFormat('d MMMM yyyy', 'ar').format(DateTime(2026, 10, 1))}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircleAvatar(
                            radius: 30,
                            child: Icon(Icons.person_outline, size: 32),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Mohamed Hamed',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text('01141973426'),
                          const SizedBox(height: 8),
                          const Text('mohamed.hamed306247@gmail.com'),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () => _openWhatsApp(context),
                            icon: const Icon(Icons.chat),
                            label: const Text('ابدأ محادثة على واتساب'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _openWhatsApp(BuildContext context) async {
  final opened = await launchUrl(
    Uri.parse('https://wa.me/201141973426'),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تعذر فتح واتساب')),
    );
  }
}

class MonthRecord {
  MonthRecord({
    required this.year,
    required this.month,
    this.hourlyRate,
    this.vacationDays = 0,
    this.workDays = 30,
    this.defaultArrival,
    this.defaultDeparture,
    Map<int, DayRecord>? days,
  }) : days = days ?? {};

  final int year;
  final int month;
  double? hourlyRate;
  int vacationDays;
  int workDays;
  String? defaultArrival;
  String? defaultDeparture;
  final Map<int, DayRecord> days;

  String get id => '$year-${month.toString().padLeft(2, '0')}';

  DayRecord dayRecord(int dayNumber) {
    final record = days[dayNumber] ?? const DayRecord();
    return DayRecord(
      arrival: record.arrival ?? defaultArrival,
      departure: record.departure ?? defaultDeparture,
      isWorking: record.isWorking,
    );
  }

  int get leaveDays {
    final daysInMonth = DateTime(year, month + 1, 0).day;
    return List.generate(daysInMonth, (index) => index + 1)
        .where((dayNumber) => !dayRecord(dayNumber).isWorking)
        .length;
  }

  double get totalHours {
    final daysInMonth = DateTime(year, month + 1, 0).day;
    return List.generate(daysInMonth, (index) => index + 1)
        .fold(0, (sum, dayNumber) => sum + dayRecord(dayNumber).hours);
  }

  factory MonthRecord.fromJson(Map<String, dynamic> json) {
    final daysJson = json['days'] as Map<String, dynamic>? ?? {};
    return MonthRecord(
      year: json['year'] as int,
      month: json['month'] as int,
      hourlyRate: (json['hourlyRate'] as num?)?.toDouble(),
      vacationDays: (json['vacationDays'] as num?)?.toInt() ?? 0,
      workDays: (json['workDays'] as num?)?.toInt() ?? 30,
      defaultArrival: json['defaultArrival'] as String?,
      defaultDeparture: json['defaultDeparture'] as String?,
      days: {
        for (final entry in daysJson.entries)
          int.parse(entry.key): DayRecord.fromJson(
            entry.value as Map<String, dynamic>,
          ),
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'year': year,
        'month': month,
        'hourlyRate': hourlyRate,
        'vacationDays': vacationDays,
        'workDays': workDays,
        'defaultArrival': defaultArrival,
        'defaultDeparture': defaultDeparture,
        'days': {
          for (final entry in days.entries)
            entry.key.toString(): entry.value.toJson(),
        },
      };
}

class DayRecord {
  const DayRecord({
    this.arrival,
    this.departure,
    this.isWorking = true,
  });

  final String? arrival;
  final String? departure;
  final bool isWorking;

  DayRecord copyWith({
    String? arrival,
    String? departure,
    bool? isWorking,
  }) =>
      DayRecord(
        arrival: arrival ?? this.arrival,
        departure: departure ?? this.departure,
        isWorking: isWorking ?? this.isWorking,
      );

  factory DayRecord.fromJson(Map<String, dynamic> json) => DayRecord(
        arrival: json['arrival'] as String?,
        departure: json['departure'] as String?,
        isWorking: json['isWorking'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'arrival': arrival,
        'departure': departure,
        'isWorking': isWorking,
      };

  double get hours {
    if (!isWorking || arrival == null || departure == null) return 0;
    final start = _minutesFromTime(arrival!);
    var end = _minutesFromTime(departure!);
    if (end < start) end += 24 * 60;
    return (end - start) / 60;
  }
}

int _minutesFromTime(String value) {
  final parts = value.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

class MonthStore {
  MonthStore({
    this.directory,
    this.cloudSession,
    this.employeeId,
    this.readOnlyMonths,
  });

  final Directory? directory;
  final CloudAppSession? cloudSession;
  final String? employeeId;
  final List<MonthRecord>? readOnlyMonths;
  Future<void> _saveQueue = Future<void>.value();

  String get _cloudEmployeeId {
    final id = employeeId;
    if (id == null) {
      throw StateError('Cloud month storage needs an employee ID');
    }
    return id;
  }

  Future<Directory> _monthsDirectory() async {
    final customDirectory = directory;
    if (customDirectory != null) {
      await customDirectory.create(recursive: true);
      return customDirectory;
    }
    final documents = await getApplicationDocumentsDirectory();
    final monthsDirectory = Directory('${documents.path}/employee_months');
    await monthsDirectory.create(recursive: true);
    return monthsDirectory;
  }

  Future<List<MonthRecord>> loadMonths() async {
    final cachedMonths = readOnlyMonths;
    if (cachedMonths != null) return List.of(cachedMonths);
    final cloud = cloudSession;
    if (cloud != null) {
      final records = await CloudDataStore(cloud).loadMonths(_cloudEmployeeId);
      return records.map(MonthRecord.fromJson).toList();
    }
    final directory = await _monthsDirectory();
    final entities = await directory.list(followLinks: false).toList();
    final records = <MonthRecord>[];
    for (final entity in entities.whereType<Directory>()) {
      final file = File('${entity.path}/data.json');
      if (!await file.exists()) continue;
      final decoded = jsonDecode(await file.readAsString());
      records.add(MonthRecord.fromJson(decoded as Map<String, dynamic>));
    }
    records.sort((a, b) => b.id.compareTo(a.id));
    return records;
  }

  Future<void> save(MonthRecord record) {
    if (readOnlyMonths != null) {
      throw StateError('This month store is read-only');
    }
    final write = _saveQueue.then((_) async {
      final cloud = cloudSession;
      if (cloud != null) {
        await CloudDataStore(cloud).saveMonth(
          _cloudEmployeeId,
          record.toJson(),
        );
        return;
      }
      final root = await _monthsDirectory();
      final directory = Directory('${root.path}/${record.id}');
      await directory.create(recursive: true);
      await File('${directory.path}/data.json').writeAsString(
        jsonEncode(record.toJson()),
        flush: true,
      );
    });
    _saveQueue = write.catchError((Object _) {});
    return write;
  }

  Future<void> delete(MonthRecord record) {
    if (readOnlyMonths != null) {
      throw StateError('This month store is read-only');
    }
    final operation = _saveQueue.then((_) async {
      if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(record.id)) {
        throw ArgumentError.value(record.id, 'record.id', 'Invalid month ID');
      }
      final cloud = cloudSession;
      if (cloud != null) {
        await CloudDataStore(cloud).deleteMonth(
          _cloudEmployeeId,
          record.year,
          record.month,
        );
        return;
      }
      final root = await _monthsDirectory();
      final directory = Directory('${root.path}/${record.id}');
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    _saveQueue = operation.catchError((Object _) {});
    return operation;
  }
}

class MonthsPage extends StatefulWidget {
  const MonthsPage({
    this.store,
    this.userName,
    this.appTitle = 'salary',
    this.employeeMode = false,
    this.readOnly = false,
    this.onLogout,
    super.key,
  });

  final MonthStore? store;
  final String? userName;
  final String appTitle;
  final bool employeeMode;
  final bool readOnly;
  final Future<void> Function()? onLogout;

  @override
  State<MonthsPage> createState() => _MonthsPageState();
}

class _MonthsPageState extends State<MonthsPage> {
  late final MonthStore _store;
  late Future<List<MonthRecord>> _monthsFuture;
  Future<String>? _attendanceMode;
  Timer? _attendanceModeTimer;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? MonthStore();
    _monthsFuture = _store.loadMonths();
    final cloud = _store.cloudSession;
    if (widget.employeeMode && cloud != null) {
      _attendanceMode = CloudDataStore(cloud).getAttendanceMode();
      _attendanceModeTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _refreshAttendanceMode(),
      );
    }
  }

  void _refreshAttendanceMode() {
    final cloud = _store.cloudSession;
    if (cloud == null || !mounted) return;
    setState(() {
      _attendanceMode = CloudDataStore(cloud).getAttendanceMode();
    });
  }

  @override
  void dispose() {
    _attendanceModeTimer?.cancel();
    super.dispose();
  }

  Future<void> _addMonth() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'اختار أي يوم من الشهر المطلوب',
    );
    if (selected == null || !mounted) return;

    final record = MonthRecord(year: selected.year, month: selected.month);
    final existing = await _monthsFuture;
    if (existing.any((month) => month.id == record.id)) {
      if (mounted) _showMessage('الشهر ده مضاف بالفعل');
      return;
    }

    try {
      await _store.save(record);
      if (!mounted) return;
      setState(() {
        _monthsFuture = _store.loadMonths();
      });
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر حفظ الشهر: ${error.message}');
    } on Exception catch (error) {
      if (mounted) _showMessage('تعذر حفظ الشهر: $error');
    }
  }

  Future<void> _deleteMonth() async {
    final months = await _monthsFuture;
    if (!mounted) return;
    if (months.isEmpty) {
      _showMessage('مفيش شهور لحذفها');
      return;
    }

    final selected = await showModalBottomSheet<MonthRecord>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'اختار الشهر المراد حذفه',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            for (final month in months)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  DateFormat('MMMM yyyy', 'ar')
                      .format(DateTime(month.year, month.month)),
                ),
                onTap: () => Navigator.of(context).pop(month),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف الشهر؟'),
        content: Text(
          'هيتم حذف بيانات ${DateFormat('MMMM yyyy', 'ar').format(DateTime(selected.year, selected.month))} نهائيًا.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _store.delete(selected);
      if (!mounted) return;
      setState(() {
        _monthsFuture = _store.loadMonths();
      });
      _showMessage('تم حذف الشهر');
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر حذف الشهر: ${error.message}');
    } on Exception catch (error) {
      if (mounted) _showMessage('تعذر حذف الشهر: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _showEmployeePassword() async {
    final cloud = _store.cloudSession;
    final employeeId = _store.employeeId;
    if (cloud == null || cloud.role != 'manager' || employeeId == null) return;
    try {
      final result =
          await CloudDataStore(cloud).getEmployeePasswordForManager(employeeId);
      if (!mounted) return;
      final password = result['password'] as String?;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('كلمة مرور الموظف'),
          content: password == null || password.isEmpty
              ? const Text('لا يوجد كلمة مرور معينة لهذا الموظف.')
              : SelectableText('كلمة المرور: $password'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
    } on Exception catch (error) {
      if (mounted) _showMessage('تعذر عرض كلمة مرور الموظف: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cloud = _store.cloudSession;
    if (widget.employeeMode && cloud != null) {
      return FutureBuilder<String>(
        future: _attendanceMode,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              appBar: AppBar(
                title: _homeAppBarTitle(
                  widget.userName,
                  appTitle: widget.appTitle,
                ),
              ),
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('تعذر تحميل نظام الحضور'),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _refreshAttendanceMode,
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.data == 'required') {
            final employeeId = _store.employeeId;
            if (employeeId == null) {
              return const Scaffold(
                body: Center(child: Text('تعذر تحديد حساب الموظف')),
              );
            }
            return _RequiredAttendancePage(
              session: cloud,
              employeeId: employeeId,
              userName: widget.userName,
              onLogout: widget.onLogout,
            );
          }
          return _buildMonthsPage(context);
        },
      );
    }
    return _buildMonthsPage(context);
  }

  Widget _buildMonthsPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _homeAppBarTitle(widget.userName, appTitle: widget.appTitle),
        actions: [
          if (widget.onLogout != null)
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      floatingActionButton: widget.readOnly
          ? null
          : Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'add-month',
                  onPressed: _addMonth,
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة شهر'),
                ),
                if (!widget.employeeMode &&
                    _store.cloudSession?.role == 'manager' &&
                    _store.employeeId != null) ...[
                  FloatingActionButton.small(
                    heroTag: 'show-employee-password',
                    tooltip: 'عرض كلمة المرور',
                    onPressed: _showEmployeePassword,
                    child: const Icon(Icons.password_outlined),
                  ),
                ],
                if (!widget.employeeMode) ...[
                  FloatingActionButton.extended(
                    heroTag: 'delete-month',
                    onPressed: _deleteMonth,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('حذف شهر'),
                  ),
                ],
                FloatingActionButton.small(
                  heroTag: 'app-info',
                  tooltip: 'الإنفو',
                  onPressed: () => _showInfoDialog(context),
                  child: const Icon(Icons.info_outline),
                ),
              ],
            ),
      body: FutureBuilder<List<MonthRecord>>(
        future: _monthsFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('حصلت مشكلة أثناء تحميل الشهور'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final months = snapshot.data!;
          if (months.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.calendar_month_outlined, size: 64),
                    SizedBox(height: 16),
                    Text(
                      widget.readOnly
                          ? 'لا توجد سجلات شهرية لهذا الموظف بعد.'
                          : 'مفيش شهور مضافة لسه\nاضغط «إضافة شهر» للبدء',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: months.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final month = months[index];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.folder_outlined),
                  ),
                  title: Text(
                    DateFormat('MMMM yyyy', 'ar').format(
                      DateTime(month.year, month.month),
                    ),
                  ),
                  subtitle: Text(
                    'إجمالي الساعات: ${_formatNumber(_monthHours(month))}',
                  ),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MonthPage(
                          month: month,
                          store: _store,
                          employeeMode: widget.employeeMode,
                          readOnly: widget.readOnly,
                        ),
                      ),
                    );
                    if (mounted) {
                      setState(() {
                        _monthsFuture = _store.loadMonths();
                      });
                    }
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _RequiredAttendancePage extends StatefulWidget {
  const _RequiredAttendancePage({
    required this.session,
    required this.employeeId,
    required this.userName,
    required this.onLogout,
  });

  final CloudAppSession session;
  final String employeeId;
  final String? userName;
  final Future<void> Function()? onLogout;

  @override
  State<_RequiredAttendancePage> createState() =>
      _RequiredAttendancePageState();
}

class _RequiredAttendancePageState extends State<_RequiredAttendancePage> {
  late Future<Map<String, dynamic>> _attendance;
  bool _submitting = false;

  CloudDataStore get _store => CloudDataStore(widget.session);

  @override
  void initState() {
    super.initState();
    _attendance = _store.loadTodayAttendance(widget.employeeId);
  }

  Future<void> _record(String action) async {
    setState(() => _submitting = true);
    try {
      final result = await _store.recordAttendanceAction(
        employeeId: widget.employeeId,
        action: action,
      );
      if (mounted) {
        setState(() => _attendance = Future.value(result));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              action == 'check_in'
                  ? 'تم تسجيل الحضور تلقائيًا'
                  : 'تم تسجيل الانصراف تلقائيًا',
            ),
          ),
        );
      }
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تسجيل الحضور والانصراف: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: _homeAppBarTitle(
            widget.userName,
            appTitle: 'تطبيق الموظفين',
          ),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              onPressed: () => setState(
                () => _attendance = _store.loadTodayAttendance(
                  widget.employeeId,
                ),
              ),
              icon: const Icon(Icons.refresh),
            ),
            if (widget.onLogout != null)
              IconButton(
                tooltip: 'تسجيل الخروج',
                onPressed: widget.onLogout,
                icon: const Icon(Icons.logout),
              ),
          ],
        ),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _attendance,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('تعذر تحميل حضور اليوم'),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => setState(
                        () => _attendance = _store.loadTodayAttendance(
                          widget.employeeId,
                        ),
                      ),
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final data = snapshot.data!;
            final date = DateTime.parse(data['date'] as String);
            final arrival = data['arrival'] as String?;
            final departure = data['departure'] as String?;
            final hours = arrival != null && departure != null
                ? DayRecord(arrival: arrival, departure: departure).hours
                : 0.0;
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        const Icon(Icons.today_outlined, size: 42),
                        const SizedBox(height: 8),
                        Text(
                          DateFormat('EEEE d MMMM yyyy', 'ar').format(date),
                          style: Theme.of(context).textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'نظام الحضور الإجباري: التسجيل لليوم الحالي فقط والوقت يحدده الخادم.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        _AttendanceTimeTile(
                          label: 'وقت الحضور',
                          value: arrival,
                        ),
                        const SizedBox(height: 8),
                        _AttendanceTimeTile(
                          label: 'وقت الانصراف',
                          value: departure,
                        ),
                        if (departure != null) ...[
                          const SizedBox(height: 12),
                          Text('إجمالي ساعات اليوم: ${_formatNumber(hours)}'),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _submitting || arrival != null
                      ? null
                      : () => _record('check_in'),
                  icon: const Icon(Icons.login),
                  label: Text(
                    arrival == null ? 'حضور الآن' : 'تم تسجيل الحضور',
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _submitting || arrival == null || departure != null
                      ? null
                      : () => _record('check_out'),
                  icon: const Icon(Icons.logout),
                  label: Text(
                    departure == null ? 'انصراف الآن' : 'تم تسجيل الانصراف',
                  ),
                ),
                if (_submitting) ...[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            );
          },
        ),
      );
}

class _AttendanceTimeTile extends StatelessWidget {
  const _AttendanceTimeTile({
    required this.label,
    required this.value,
  });

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(
          label == 'وقت الحضور' ? Icons.login : Icons.logout,
        ),
        title: Text(label),
        trailing: Text(
          value ?? '--:--',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
}

double _monthHours(MonthRecord month) => month.totalHours;

String _formatNumber(num value) =>
    value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

class MonthPage extends StatefulWidget {
  const MonthPage({
    required this.month,
    required this.store,
    this.employeeMode = false,
    this.readOnly = false,
    super.key,
  });

  final MonthRecord month;
  final MonthStore store;
  final bool employeeMode;
  final bool readOnly;

  @override
  State<MonthPage> createState() => _MonthPageState();
}

class _MonthPageState extends State<MonthPage> {
  late final TextEditingController _rateController;
  late final TextEditingController _vacationDaysController;
  late final TextEditingController _workDaysController;
  Timer? _attendanceModeTimer;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _rateController = TextEditingController(
      text: widget.month.hourlyRate?.toString() ?? '',
    );
    _vacationDaysController = TextEditingController(
      text: widget.month.vacationDays.toString(),
    );
    _workDaysController = TextEditingController(
      text: widget.month.workDays.toString(),
    );
    final cloud = widget.store.cloudSession;
    if (widget.employeeMode && cloud != null) {
      _attendanceModeTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _checkAttendanceMode(cloud),
      );
    }
  }

  Future<void> _checkAttendanceMode(CloudAppSession session) async {
    try {
      final mode = await CloudDataStore(session).getAttendanceMode();
      if (mode == 'required' &&
          mounted &&
          (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).pop();
      }
    } on Exception catch (error) {
      _attendanceModeTimer?.cancel();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحديث نظام الحضور: $error')),
        );
      }
    }
  }

  @override
  void dispose() {
    _attendanceModeTimer?.cancel();
    _rateController.dispose();
    _vacationDaysController.dispose();
    _workDaysController.dispose();
    super.dispose();
  }

  Future<void> _updateDay(
    int dayNumber, {
    String? arrival,
    String? departure,
    bool? isWorking,
  }) async {
    final previous = widget.month.days[dayNumber] ?? const DayRecord();
    setState(() {
      widget.month.days[dayNumber] = previous.copyWith(
        arrival: arrival,
        departure: departure,
        isWorking: isWorking,
      );
    });
    await _save();
  }

  Future<void> _saveDays({String? vacationDays, String? workDays}) async {
    final vacation = vacationDays == null
        ? widget.month.vacationDays
        : int.tryParse(_normalizeNumber(vacationDays)) ?? 0;
    final work = workDays == null
        ? widget.month.workDays
        : int.tryParse(_normalizeNumber(workDays)) ?? 0;
    setState(() {
      widget.month.vacationDays = vacation.clamp(0, 31).toInt();
      widget.month.workDays = work.clamp(0, 31).toInt();
    });
    await _save();
  }

  Future<void> _chooseTime(int dayNumber, bool isArrival) async {
    final record = widget.month.dayRecord(dayNumber);
    final current = isArrival ? record.arrival : record.departure;
    final initialTime = current == null
        ? TimeOfDay.now()
        : TimeOfDay(
            hour: _minutesFromTime(current) ~/ 60,
            minute: _minutesFromTime(current) % 60,
          );
    final selected = await showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: isArrival ? 'اختار وقت الحضور' : 'اختار وقت الانصراف',
    );
    if (selected == null || !mounted) return;
    final value =
        '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
    if (isArrival) {
      await _updateDay(dayNumber, arrival: value);
    } else {
      await _updateDay(dayNumber, departure: value);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.store.save(widget.month);
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ البيانات: ${error.message}')),
        );
      }
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ البيانات: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveRate(String value) async {
    final normalized = _normalizeNumber(value);
    setState(() {
      widget.month.hourlyRate =
          normalized.isEmpty ? null : double.tryParse(normalized);
    });
    await _save();
  }

  Future<void> _chooseMonthDefault(bool isArrival) async {
    final current =
        isArrival ? widget.month.defaultArrival : widget.month.defaultDeparture;
    final initialTime = current == null
        ? TimeOfDay.now()
        : TimeOfDay(
            hour: _minutesFromTime(current) ~/ 60,
            minute: _minutesFromTime(current) % 60,
          );
    final selected = await showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: isArrival
          ? 'اختار وقت الحضور الافتراضي'
          : 'اختار وقت الانصراف الافتراضي',
    );
    if (selected == null || !mounted) return;
    final value =
        '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (isArrival) {
        widget.month.defaultArrival = value;
      } else {
        widget.month.defaultDeparture = value;
      }
    });
    await _save();
  }

  Future<void> _clearMonthDefault(bool isArrival) async {
    setState(() {
      if (isArrival) {
        widget.month.defaultArrival = null;
      } else {
        widget.month.defaultDeparture = null;
      }
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final month = widget.month;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final hours = _monthHours(month);
    final netWorkDays = month.workDays - month.vacationDays;
    final salary =
        netWorkDays > 0 ? hours / netWorkDays * (month.hourlyRate ?? 0) : 0;
    final leaveDays = month.leaveDays;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          DateFormat('MMMM yyyy', 'ar')
              .format(DateTime(month.year, month.month)),
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsetsDirectional.only(end: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              itemCount: daysInMonth + 1,
              itemBuilder: (context, index) {
                if (index == 0 && !widget.employeeMode) {
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'مواعيد افتراضية للشهر',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _MonthDefaultTime(
                                  title: 'الحضور',
                                  value: month.defaultArrival,
                                  onTap: widget.readOnly
                                      ? null
                                      : () => _chooseMonthDefault(true),
                                  onClear: month.defaultArrival == null ||
                                          widget.readOnly
                                      ? null
                                      : () => _clearMonthDefault(true),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _MonthDefaultTime(
                                  title: 'الانصراف',
                                  value: month.defaultDeparture,
                                  onTap: widget.readOnly
                                      ? null
                                      : () => _chooseMonthDefault(false),
                                  onClear: month.defaultDeparture == null ||
                                          widget.readOnly
                                      ? null
                                      : () => _clearMonthDefault(false),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'تُستخدم للأيام غير المعدلة، ويمكن تغيير وقت أي يوم يدويًا.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final dayNumber = index;
                final date = DateTime(month.year, month.month, dayNumber);
                final record = month.dayRecord(dayNumber);
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    child: Column(
                      children: [
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            '${DateFormat('EEEE', 'ar').format(date)}  •  ${DateFormat('d/M/yyyy', 'ar').format(date)}',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: Checkbox(
                                value: record.isWorking,
                                onChanged: widget.readOnly
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          _updateDay(
                                            dayNumber,
                                            isWorking: value,
                                          );
                                        }
                                      },
                                semanticLabel: 'يوم عمل',
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: _TimeEntry(
                                title: 'الحضور',
                                value: record.arrival,
                                onTap: record.isWorking && !widget.readOnly
                                    ? () => _chooseTime(dayNumber, true)
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _TimeEntry(
                                title: 'الانصراف',
                                value: record.departure,
                                onTap: record.isWorking && !widget.readOnly
                                    ? () => _chooseTime(dayNumber, false)
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 58,
                              child: Column(
                                children: [
                                  const Text('الساعات'),
                                  Text(
                                    _formatNumber(record.hours),
                                    style:
                                        Theme.of(context).textTheme.titleMedium,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Text('إجمالي ساعات الشهر')),
                        Text(
                          '${_formatNumber(hours)} ساعة',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    if (widget.employeeMode) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Expanded(child: Text('أيام الإجازة')),
                          Text(
                            '$leaveDays يوم',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ] else if (widget.readOnly) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _ReadOnlyMonthValue(
                              label: 'سعر الساعة',
                              value:
                                  '${_formatNumber(month.hourlyRate ?? 0)} جنيه',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _ReadOnlyMonthValue(
                              label: 'أيام الإجازة',
                              value: '${month.vacationDays} يوم',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _ReadOnlyMonthValue(
                              label: 'أيام العمل',
                              value: '${month.workDays} يوم',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('إجمالي المرتب'),
                                Text(
                                  '${_formatNumber(salary)} جنيه',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text('أيام الإجازة من الجدول'),
                              Text(
                                '$leaveDays يوم',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (netWorkDays <= 0) ...[
                        const SizedBox(height: 8),
                        const Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            'أيام العمل يجب أن تكون أكبر من أيام الإجازة',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ] else ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _rateController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'سعر الساعة',
                                suffixText: 'جنيه',
                              ),
                              onChanged: _saveRate,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _vacationDaysController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'أيام الإجازة',
                                suffixText: 'يوم',
                              ),
                              onChanged: (value) =>
                                  _saveDays(vacationDays: value),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _workDaysController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'أيام العمل',
                                suffixText: 'يوم',
                              ),
                              onChanged: (value) => _saveDays(workDays: value),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('إجمالي المرتب'),
                                Text(
                                  '${_formatNumber(salary)} جنيه',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text('أيام الإجازة من الجدول'),
                              Text(
                                '$leaveDays يوم',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (netWorkDays <= 0) ...[
                        const SizedBox(height: 8),
                        const Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            'أيام العمل يجب أن تكون أكبر من أيام الإجازة',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeEntry extends StatelessWidget {
  const _TimeEntry({
    required this.title,
    required this.value,
    required this.onTap,
  });

  final String title;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: title,
          enabled: onTap != null,
          suffixIcon: const Icon(Icons.access_time, size: 18),
        ),
        child: Text(
          value ?? '--:--',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12),
        ),
      ),
    );
  }
}

class _ReadOnlyMonthValue extends StatelessWidget {
  const _ReadOnlyMonthValue({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      );
}

class _MonthDefaultTime extends StatelessWidget {
  const _MonthDefaultTime({
    required this.title,
    required this.value,
    required this.onTap,
    required this.onClear,
  });

  final String title;
  final String? value;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: title,
          suffixIcon: value == null
              ? const Icon(Icons.access_time, size: 18)
              : IconButton(
                  tooltip: 'مسح وقت $title الافتراضي',
                  onPressed: onClear,
                  icon: const Icon(Icons.close, size: 18),
                ),
        ),
        child: Text(value ?? 'غير محدد', textAlign: TextAlign.center),
      ),
    );
  }
}

String _normalizeNumber(String value) {
  const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  var normalized = value.trim().replaceAll('٫', '.').replaceAll(',', '.');
  for (var i = 0; i < 10; i++) {
    normalized = normalized
        .replaceAll(arabicIndic[i], '$i')
        .replaceAll(persian[i], '$i');
  }
  return normalized;
}
