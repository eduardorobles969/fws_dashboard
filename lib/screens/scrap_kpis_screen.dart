import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class ScrapKpisScreen extends StatefulWidget {
  const ScrapKpisScreen({super.key});
  @override
  State<ScrapKpisScreen> createState() => _ScrapKpisScreenState();
}

class _ScrapKpisScreenState extends State<ScrapKpisScreen> {
  DateTimeRange? _range;
  String _projectFilter = '';

  Stream<List<Map<String, dynamic>>> _stream() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance
        .collection('scrap_events')
        .orderBy('createdAt', descending: true);

    if (_range != null) {
      q = q
          .where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(_range!.start),
          )
          .where(
            'createdAt',
            isLessThanOrEqualTo: Timestamp.fromDate(
              DateTime(
                _range!.end.year,
                _range!.end.month,
                _range!.end.day,
                23,
                59,
                59,
              ),
            ),
          );
    }
    return q.snapshots().map((s) => s.docs.map((d) => d.data()).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KPIs de scrap'),
        actions: [
          IconButton(
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDateRangePicker(
                context: context,
                firstDate: DateTime(now.year - 1),
                lastDate: DateTime(now.year + 1),
                initialDateRange:
                    _range ??
                    DateTimeRange(
                      start: DateTime(now.year, now.month, 1),
                      end: DateTime(now.year, now.month + 1, 0),
                    ),
              );
              if (picked != null) setState(() => _range = picked);
            },
            icon: const Icon(Icons.date_range),
            tooltip: 'Rango de fechas',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Filtro por proyecto (texto)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) =>
                  setState(() => _projectFilter = v.trim().toLowerCase()),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _stream(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text('Error: ${snap.error}'));
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                // filtra por proyecto (cliente-side)
                final rows = snap.data!.where((m) {
                  if (_projectFilter.isEmpty) return true;
                  return (m['proyecto'] ?? '')
                      .toString()
                      .toLowerCase()
                      .contains(_projectFilter);
                }).toList();

                // totales
                final total = rows.length;
                final abiertos = rows
                    .where((m) => (m['status'] ?? '') != 'cerrado')
                    .length;
                final cerrados = total - abiertos;
                final piezasTot = rows.fold<int>(
                  0,
                  (a, b) =>
                      a +
                      ((b['piezas'] is int)
                          ? b['piezas'] as int
                          : int.tryParse(b['piezas']?.toString() ?? '') ?? 0),
                );

                // por operación
                final porOp = <String, int>{};
                for (final m in rows) {
                  final op = (m['operacionNombre'] ?? '—').toString();
                  porOp[op] = (porOp[op] ?? 0) + 1;
                }

                // por proyecto
                final porProj = <String, int>{};
                for (final m in rows) {
                  final p = (m['proyecto'] ?? '—').toString();
                  porProj[p] = (porProj[p] ?? 0) + 1;
                }

                List<BarChartGroupData> _barData(Map<String, int> data) {
                  final entries = data.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value));
                  final top = entries.take(8).toList();
                  return List.generate(top.length, (i) {
                    return BarChartGroupData(
                      x: i,
                      barRods: [BarChartRodData(toY: top[i].value.toDouble())],
                      showingTooltipIndicators: const [0],
                    );
                  });
                }

                List<String> _barLabels(Map<String, int> data) {
                  final entries = data.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value));
                  return entries.take(8).map((e) => e.key).toList();
                }

                final opLabels = _barLabels(porOp);
                final projLabels = _barLabels(porProj);

                Widget stat(String label, String value, IconData icon) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 20),
                        const SizedBox(height: 6),
                        Text(
                          value,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          label,
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                );

                return ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Expanded(
                          child: stat(
                            'Eventos',
                            '$total',
                            Icons.analytics_outlined,
                          ),
                        ),
                        Expanded(
                          child: stat(
                            'Abiertos',
                            '$abiertos',
                            Icons.error_outline,
                          ),
                        ),
                        Expanded(
                          child: stat(
                            'Cerrados',
                            '$cerrados',
                            Icons.check_circle_outline,
                          ),
                        ),
                        Expanded(
                          child: stat(
                            'Pzas SCRAP',
                            '$piezasTot',
                            Icons.production_quantity_limits,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Eventos por operación (Top 8)',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 220,
                              child: BarChart(
                                BarChartData(
                                  barGroups: _barData(porOp),
                                  titlesData: FlTitlesData(
                                    leftTitles: const AxisTitles(
                                      sideTitles: SideTitles(
                                        showTitles: true,
                                        reservedSize: 28,
                                      ),
                                    ),
                                    rightTitles: const AxisTitles(
                                      sideTitles: SideTitles(showTitles: false),
                                    ),
                                    topTitles: const AxisTitles(
                                      sideTitles: SideTitles(showTitles: false),
                                    ),
                                    bottomTitles: AxisTitles(
                                      sideTitles: SideTitles(
                                        showTitles: true,
                                        getTitlesWidget: (v, meta) {
                                          final i = v.toInt();
                                          if (i < 0 || i >= opLabels.length)
                                            return const SizedBox.shrink();
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              top: 4,
                                            ),
                                            child: Text(
                                              opLabels[i],
                                              style: const TextStyle(
                                                fontSize: 10,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  gridData: const FlGridData(show: true),
                                  borderData: FlBorderData(show: false),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Eventos por proyecto (Top 8)',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 220,
                              child: BarChart(
                                BarChartData(
                                  barGroups: _barData(porProj),
                                  titlesData: FlTitlesData(
                                    leftTitles: const AxisTitles(
                                      sideTitles: SideTitles(
                                        showTitles: true,
                                        reservedSize: 28,
                                      ),
                                    ),
                                    rightTitles: const AxisTitles(
                                      sideTitles: SideTitles(showTitles: false),
                                    ),
                                    topTitles: const AxisTitles(
                                      sideTitles: SideTitles(showTitles: false),
                                    ),
                                    bottomTitles: AxisTitles(
                                      sideTitles: SideTitles(
                                        showTitles: true,
                                        getTitlesWidget: (v, meta) {
                                          final i = v.toInt();
                                          if (i < 0 || i >= projLabels.length)
                                            return const SizedBox.shrink();
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              top: 4,
                                            ),
                                            child: Text(
                                              projLabels[i],
                                              style: const TextStyle(
                                                fontSize: 10,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  gridData: const FlGridData(show: true),
                                  borderData: FlBorderData(show: false),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
