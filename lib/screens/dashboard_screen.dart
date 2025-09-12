// Flutter imports
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'admin_users_screen.dart';
import 'profile_screen.dart';

// Quick action screens
import 'new_project_part_screen.dart';
import 'add_production_entry_screen.dart';
import 'operator_tasks_screen.dart';

// Drawer screens
import 'documentation_screen.dart';
import 'package:fws_dashboard/screens/warehouse_screen.dart';
import 'package:fws_dashboard/screens/gantt_screen.dart';
import 'package:fws_dashboard/screens/industry40_screen.dart';
import 'bom_screen.dart';
import 'requisition_screen.dart';
import 'scrap_screen.dart';
import 'package:fws_dashboard/screens/requisitions_library_screen.dart';
import 'scrap_investigations_screen.dart';
import 'scrap_kpis_screen.dart';
import 'rework_screen.dart';

// Tabs // lib/screens/dashboard_screen.dart
import 'production_chart_screen.dart';
import 'dashboard_info_screen.dart';
import 'production_table_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  String? _role;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _roleSub;

  String _normRole(String? r) => (r ?? 'operador').trim().toLowerCase();
  bool get isAdmin {
    final r = _normRole(_role);
    return r == 'administrador' || r == 'admin';
  }

  bool get isSupervisor => _normRole(_role) == 'supervisor';
  bool get isOperador => _normRole(_role) == 'operador';
  bool get isDisenador {
    final r = _normRole(_role);
    return r == 'diseñador' || r == 'disenador';
  }

  bool get canCreateProd => isSupervisor || isAdmin;
  bool get canDesign => isDisenador || isAdmin;
  bool get canOperate => isOperador || isAdmin;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _roleSub = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots()
          .listen((snap) {
            final m = snap.data();
            final r = (m == null ? 'operador' : (m['role'] ?? 'operador'))
                .toString();
            if (mounted) setState(() => _role = _normRole(r));
          });
    }
  }

  @override
  void dispose() {
    _roleSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const FilterableProductionList(), // TABLA (tu lista)
      const ProductionChartScreen(), // GRÁFICA (nuevo archivo)
      const DashboardInfoScreen(), // INFO (nuevo archivo)
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text("FWS • Dashboard de Producción"),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Perfil',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
          ),
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              tooltip: 'Panel admin (placeholder)',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Acción de admin (demo)')),
                );
              },
            ),
        ],
      ),

      drawer: Drawer(
        child: ListView(
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(
                FirebaseAuth.instance.currentUser?.email ?? "Usuario",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              accountEmail: const Text("Fusion Welding Solutions"),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.person, size: 36),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.book),
              title: const Text("Documentación"),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DocumentationScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text("Almacén"),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const WarehouseScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.list_alt),
              title: const Text('BOM (proyecto)'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BomScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.precision_manufacturing_outlined),
              title: const Text("Industria 4.0"),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const Industry40Screen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.timeline_outlined),
              title: const Text("Gantt producción"),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const GanttScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.request_quote_outlined),
              title: const Text('Requisiciones'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RequisitionScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.build_outlined),
              title: const Text('Retrabajo'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ReworkScreen()),
                );
              },
            ),
            // ListTile
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Biblioteca de requisiciones'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const RequisitionsLibraryScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.report_problem_outlined),
              title: const Text('Reportar scrap'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ScrapScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('Investigaciones de scrap'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ScrapInvestigationsScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.dashboard_customize_outlined),
              title: const Text('KPIs de scrap'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ScrapKpisScreen()),
                );
              },
            ),
            if (isAdmin)
              ListTile(
                leading: const Icon(Icons.group_remove_outlined),
                title: const Text("Administrar usuarios"),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AdminUsersScreen()),
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text("Cerrar sesión"),
              onTap: () async {
                await FirebaseAuth.instance.signOut();
                if (mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),

      body: pages[_selectedIndex],

      floatingActionButton:
          (_selectedIndex == 0 && (canCreateProd || canDesign || canOperate))
          ? FloatingActionButton(
              tooltip: 'Acciones rápidas',
              onPressed: _showQuickActions,
              child: const Icon(Icons.add),
            )
          : null,

      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.table_chart),
            label: "Tabla",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart),
            label: "Gráfica",
          ),
          BottomNavigationBarItem(icon: Icon(Icons.info), label: "Info"),
        ],
      ),
    );
  }

  void _showQuickActions() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (canCreateProd)
                ListTile(
                  leading: const Icon(Icons.add_task_outlined),
                  title: const Text('Agregar producción'),
                  subtitle: const Text('Supervisor / Administrador'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AddProductionEntryScreen(),
                      ),
                    );
                  },
                ),
              if (canDesign)
                ListTile(
                  leading: const Icon(Icons.precision_manufacturing_outlined),
                  title: const Text('Alta proyecto / Nº de parte'),
                  subtitle: const Text('Diseñador / Administrador'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const NewProjectPartScreen(),
                      ),
                    );
                  },
                ),
              if (canOperate)
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: const Text('Registrar inicio/fin (operador)'),
                  subtitle: const Text('Operador / Administrador'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const OperatorTasksScreen(),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
