// lib/screens/dashboard_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';

import 'production_table_screen.dart';
import 'profile_screen.dart';
import 'add_production_entry_screen.dart';
import 'documentation_screen.dart';
import 'package:fws_dashboard/models/weekly_production.dart';
import 'new_project_part_screen.dart';
import 'operator_tasks_screen.dart';
import 'package:fws_dashboard/screens/warehouse_screen.dart';
import 'package:fws_dashboard/screens/gantt_screen.dart';
import 'admin_users_screen.dart';
import 'package:fws_dashboard/screens/industry40_screen.dart';
import 'bom_screen.dart';

/// Punto para series pequeñas (no crítico aquí, pero lo dejamos)
class ProductionPoint {
  final String fecha;
  final int pass;
  final int scrap;
  ProductionPoint({
    required this.fecha,
    required this.pass,
    required this.scrap,
  });
}

/// ============================
///   DASHBOARD PRINCIPAL
/// ============================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;
  String _modoVista = 'semanal'; // 'semanal' | 'mensual'

  /// Rol actual (normalizado a minúsculas)
  String? _role;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _roleSub;

  // Paleta de colores por proyecto para la gráfica
  final List<Color> palette = [
    Colors.indigo,
    Colors.teal,
    Colors.deepOrange,
    Colors.purple,
    Colors.green,
    Colors.blueGrey,
    Colors.pinkAccent,
    Colors.amber,
    Colors.cyan,
    Colors.redAccent,
  ];
  final Map<String, Color> proyectoColors = {};
  Color getColorForProyecto(String p) {
    if (!proyectoColors.containsKey(p)) {
      final i = proyectoColors.length % palette.length;
      proyectoColors[p] = palette[i];
    }
    return proyectoColors[p]!;
  }

  @override
  void initState() {
    super.initState();
    _listenRole();
  }

  @override
  void dispose() {
    _roleSub?.cancel();
    super.dispose();
  }

  // ============================
  //   ROLES & PERMISOS
  // ============================
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

  bool get canCreateProd => isSupervisor || isAdmin; // Supervisor + Admin
  bool get canDesign => isDisenador || isAdmin; // Diseñador + Admin
  bool get canOperate => isOperador || isAdmin; // Operador + Admin

  void _listenRole() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _roleSub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((snap) {
          final r = (snap.data()?['role'] ?? 'operador') as String;
          if (mounted) setState(() => _role = _normRole(r));
        });
  }

  // ============================
  //   SEMANA ISO (ayuda clave)
  // ============================
  /// Devuelve la semana ISO 8601 (1..53).
  /// Esto evita "S0" aunque el doc no traiga 'semana'.
  int isoWeekNumber(DateTime dt) {
    // Normaliza a fecha (sin hora)
    final d = DateTime(dt.year, dt.month, dt.day);
    // jueves de la semana ISO (algoritmo estándar)
    final thursday = d.add(Duration(days: 3 - ((d.weekday + 6) % 7)));
    final firstThursday = DateTime(thursday.year, 1, 4);
    final week = 1 + ((thursday.difference(firstThursday).inDays) / 7).floor();
    return week;
  }

  // ============================
  //   UI
  // ============================
  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[_buildTableTab(), _buildChartTab(), _buildInfoTab()];

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

      /// FAB: acciones rápidas por rol (pestaña Tabla)
      floatingActionButton: (_selectedIndex == 0 && _hasQuickActions)
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

  bool get _hasQuickActions => canCreateProd || canDesign || canOperate;

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

  // ============================
  //   TAB 1: TABLA
  // ============================
  Widget _buildTableTab() {
    // Tu lista filtrable optimizada
    return const FilterableProductionList();
    // Alternativa:
    // return const ProductionTableScreen();
  }

  // ============================
  //   TAB 2: GRÁFICA
  // ============================
  Widget _buildChartTab() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('production_daily')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return _centerMsg('Error: ${snapshot.error}');
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data!.docs;
        if (docs.isEmpty) return _centerMsg('Sin datos para graficar.');

        /// Agrupamos por semana/mes y proyecto.
        /// Usamos claves ORDENABLES:
        ///  - semanal:  anioSemana = anio*100 + semana
        ///  - mensual:  anioMes    = anio*100 + mes
        final Map<String, WeeklyProduction> grouped = {};

        for (final doc in docs) {
          final d = doc.data();

          // Fecha base
          final ts = d['fecha'] as Timestamp?;
          final date = ts?.toDate();

          // ========= Campos de periodo (preferimos los guardados; si faltan, calculamos) =========
          final semana = (d['semana'] is int)
              ? (d['semana'] as int)
              : (date != null ? isoWeekNumber(date) : 0);

          final mes = (d['mes'] is int)
              ? (d['mes'] as int)
              : (date?.month ?? 0);

          final anio = (d['anio'] is int)
              ? (d['anio'] as int)
              : (date?.year ?? 0);

          final anioSemana = (d['anioSemana'] is int)
              ? (d['anioSemana'] as int)
              : ((anio != 0 && semana != 0) ? anio * 100 + semana : 0);

          final anioMes = (anio != 0 && mes != 0) ? anio * 100 + mes : 0;

          // ========= Datos de negocio =========
          final proyecto = (d['proyecto'] ?? 'Sin proyecto') as String;
          final cantidad = int.tryParse(d['cantidad']?.toString() ?? '') ?? 0;

          // ========= Clave de agrupamiento ordenable por tiempo =========
          late final String key;
          late final int etiquetaPeriodo; // para mostrar Sxx o Mxx en barras

          if (_modoVista == 'semanal') {
            key = '$anioSemana-$proyecto'; // ordena cronológico por semana
            etiquetaPeriodo = semana; // usamos semana para la etiqueta
          } else {
            key = '$anioMes-$proyecto'; // ordena cronológico por mes
            etiquetaPeriodo = mes; // usamos mes para la etiqueta
          }

          // Acumula
          final prev = grouped[key];
          grouped[key] = WeeklyProduction(
            semana:
                etiquetaPeriodo, // 'semana' campo genérico de etiqueta (semana o mes)
            proyecto: proyecto,
            cantidad: (prev?.cantidad ?? 0) + cantidad,
          );
        }

        // Pasamos a lista y ORDENAMOS por la clave (cronológico)
        final dataEntries = grouped.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        final data = dataEntries.map((e) => e.value).toList();

        // Escalas de Y
        final int maxVal = data.isNotEmpty
            ? data.map((e) => e.cantidad).reduce((a, b) => a > b ? a : b)
            : 10;
        final double maxY = (maxVal * 1.1).clamp(5, 1e9).toDouble();
        final double tick = (maxY / 5).ceilToDouble().clamp(1, 1e9);

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
          child: Column(
            children: [
              // Selector semana/mensual
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('Semanal'),
                    selected: _modoVista == 'semanal',
                    onSelected: (_) => setState(() => _modoVista = 'semanal'),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Mensual'),
                    selected: _modoVista == 'mensual',
                    onSelected: (_) => setState(() => _modoVista = 'mensual'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                '📊 Producción por proyecto',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),

              // Gráfica
              Expanded(
                child: BarChart(
                  BarChartData(
                    maxY: maxY,
                    barTouchData: BarTouchData(
                      enabled: true,
                      touchTooltipData: BarTouchTooltipData(
                        tooltipPadding: const EdgeInsets.all(8),
                        tooltipMargin: 12,
                        tooltipRoundedRadius: 8,
                        getTooltipItem: (group, _, __, ___) {
                          final p = data[group.x.toInt()];
                          final periodo = _modoVista == 'semanal'
                              ? 'S${p.semana}'
                              : 'M${p.semana}';
                          return BarTooltipItem(
                            '$periodo • ${p.proyecto}\n${p.cantidad} unidades',
                            const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          );
                        },
                      ),
                    ),
                    barGroups: data.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final p = entry.value;
                      return BarChartGroupData(
                        x: idx,
                        barRods: [
                          BarChartRodData(
                            toY: p.cantidad.toDouble(),
                            color: getColorForProyecto(p.proyecto),
                            width: 20,
                            borderRadius: BorderRadius.circular(6),
                            backDrawRodData: BackgroundBarChartRodData(
                              show: true,
                              toY: 0,
                              color: Colors.grey.shade200,
                            ),
                          ),
                        ],
                        showingTooltipIndicators: const [0],
                      );
                    }).toList(),
                    titlesData: FlTitlesData(
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 42,
                          getTitlesWidget: (value, meta) {
                            if (value.toInt() >= 0 &&
                                value.toInt() < data.length) {
                              final p = data[value.toInt()];
                              final periodo = _modoVista == 'semanal'
                                  ? 'S${p.semana}'
                                  : 'M${p.semana}';
                              return Column(
                                children: [
                                  Text(
                                    periodo,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  Text(
                                    p.proyecto,
                                    style: const TextStyle(fontSize: 10),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              );
                            }
                            return const Text('');
                          },
                        ),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: tick,
                          getTitlesWidget: (value, meta) => Text(
                            value.toInt().toString(),
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                    ),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: tick,
                      getDrawingHorizontalLine: (value) =>
                          FlLine(color: Colors.grey.shade300, strokeWidth: 1),
                    ),
                    borderData: FlBorderData(show: false),
                  ),
                  swapAnimationDuration: const Duration(milliseconds: 800),
                  swapAnimationCurve: Curves.easeOutExpo,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ============================
  //   TAB 3: INFO
  // ============================
  Widget _buildInfoTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "📊 Indicadores Clave (KPIs)",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          "✅ Producción",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Text(
                          "5 pzas",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          "⚠️ Scrap",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Text(
                          "2.3%",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            "📝 Notas del Turno",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("• Cierre de proyecto BS-0086-EV"),
                  Text("• Verificar niveles de aceite en M002 - Bodega 12"),
                  Text("• Reportar scrap generado de ensamble válvula"),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            "🔗 Links a Reportes",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.analytics),
                label: const Text("Dashboard Producción"),
              ),
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.assignment),
                label: const Text("Reporte Scrap"),
              ),
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.check_circle),
                label: const Text("Auditorías 5S"),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Helpers
  Widget _centerMsg(String msg) => Center(child: Text(msg));
}
