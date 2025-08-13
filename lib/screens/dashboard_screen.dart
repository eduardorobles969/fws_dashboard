import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'profile_screen.dart'; // 👈 Importamos la pantalla de perfil

/// Modelo que representa un punto en la gráfica
class ProductionPoint {
  final String label; // Ej: "13/08" (fecha corta)
  final int good; // Producción buena
  final int scrap; // Producción defectuosa

  ProductionPoint({
    required this.label,
    required this.good,
    required this.scrap,
  });
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  // 📌 Consulta de datos de Firestore
  final _coll = FirebaseFirestore.instance
      .collection('production_daily')
      .orderBy('date', descending: true)
      .limit(30);

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
                MaterialPageRoute(builder: (context) => const ProfileScreen()),
              );
            },
          ),
        ],
      ),

      drawer: Drawer(
        child: ListView(
          children: [
            // Header con info del usuario
            UserAccountsDrawerHeader(
              accountName: Text(
                FirebaseAuth.instance.currentUser?.email ?? "Usuario",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              accountEmail: const Text("Fusion Welding Solution"),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.person, size: 36),
              ),
            ),
            // Botón de cerrar sesión
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

  /// =======================
  /// 📌 Pestaña 1: TABLA
  /// =======================
  Widget _buildTableTab() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _coll.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return _centerMsg('Error: ${snapshot.error}');
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data!.docs;
        if (docs.isEmpty) return _centerMsg('Sin datos en la colección.');

        final rows = docs.map((doc) {
          final d = doc.data();
          final ts = d['date'] as Timestamp?;
          final dateStr = ts != null ? _fmtDate(ts.toDate()) : '—';
          final line = (d['line'] ?? '—').toString();
          final produced = (d['produced'] ?? 0) as int;
          final good = (d['good'] ?? 0) as int;
          final scrap = (d['scrap'] ?? 0) as int;
          final yieldPct = produced > 0 ? (good / produced * 100) : 0.0;

          return DataRow(
            cells: [
              DataCell(Text(dateStr)),
              DataCell(Text(line)),
              DataCell(Text('$produced')),
              DataCell(Text('$good')),
              DataCell(Text('$scrap')),
              DataCell(Text('${yieldPct.toStringAsFixed(1)}%')),
            ],
          );
        }).toList();

        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Fecha')),
              DataColumn(label: Text('Línea')),
              DataColumn(label: Text('Producido')),
              DataColumn(label: Text('Bueno')),
              DataColumn(label: Text('Scrap')),
              DataColumn(label: Text('Yield')),
            ],
            rows: rows,
          ),
        );
      },
    );
  }

  /// =======================
  /// 📌 Pestaña 2: GRÁFICA
  /// =======================
  Widget _buildChartTab() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _coll.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return _centerMsg('Error: ${snapshot.error}');
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data!.docs;
        if (docs.isEmpty) return _centerMsg('Sin datos para graficar.');

        final points = docs.reversed.map((doc) {
          final d = doc.data();
          final ts = d['date'] as Timestamp?;
          final label = ts != null ? _fmtShort(ts.toDate()) : '—';
          final good = (d['good'] ?? 0) as int;
          final scrap = (d['scrap'] ?? 0) as int;
          return ProductionPoint(label: label, good: good, scrap: scrap);
        }).toList();

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const Text(
                'Producción (Buenas vs Scrap)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: BarChart(
                  BarChartData(
                    barGroups: points.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final p = entry.value;
                      return BarChartGroupData(
                        x: idx,
                        barRods: [
                          BarChartRodData(
                            toY: p.good.toDouble(),
                            color: Colors.green,
                          ),
                          BarChartRodData(
                            toY: p.scrap.toDouble(),
                            color: Colors.red,
                          ),
                        ],
                      );
                    }).toList(),
                    titlesData: FlTitlesData(
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (value, meta) {
                            if (value.toInt() >= 0 &&
                                value.toInt() < points.length) {
                              return Text(points[value.toInt()].label);
                            }
                            return const Text('');
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// =======================
  /// 📌 Pestaña 3: INFO
  /// =======================
  Widget _buildInfoTab() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Aquí puedes colocar KPIs, notas del turno o links a reportes.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
      ),
    );
  }

  /// =======================
  /// 🔹 Helpers
  /// =======================
  Widget _centerMsg(String msg) => Center(child: Text(msg));
  String _fmtDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
  String _fmtShort(DateTime d) => '${_two(d.day)}/${_two(d.month)}';
  String _two(int n) => n.toString().padLeft(2, '0');
}
