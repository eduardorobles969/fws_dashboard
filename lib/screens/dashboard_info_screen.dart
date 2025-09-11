// lib/screens/dashboard_info_screen.dart
// Panel de información con KPIs y resúmenes, usando datos existentes

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DashboardInfoScreen extends StatefulWidget {
  const DashboardInfoScreen({super.key});
  @override
  State<DashboardInfoScreen> createState() => _DashboardInfoScreenState();
}

class _DashboardInfoScreenState extends State<DashboardInfoScreen> {
  String? _projectName; // filtro por nombre de proyecto
  DateTimeRange? _range; // filtro por fechas

  late final Future<List<String>> _projectsFuture = _loadProjectNames();

  Future<List<String>> _loadProjectNames() async {
    final out = <String>{};
    final qs = await FirebaseFirestore.instance
        .collection('projects')
        .where('activo', isEqualTo: true)
        .get();
    for (final d in qs.docs) {
      final n = (d.data()['proyecto'] ?? '').toString().trim();
      if (n.isNotEmpty) out.add(n);
    }
    if (out.isEmpty) {
      final qs2 = await FirebaseFirestore.instance
          .collection('production_daily')
          .limit(200)
          .get();
      for (final d in qs2.docs) {
        final n = (d.data()['proyecto'] ?? '').toString().trim();
        if (n.isNotEmpty) out.add(n);
      }
    }
    final list = out.toList()..sort();
    return list;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _prodStream() {
    // Orden por fecha; filtramos en cliente para evitar índices compuestos
    return FirebaseFirestore.instance
        .collection('production_daily')
        .orderBy('fecha', descending: true)
        .limit(1000)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _projectsFuture,
      builder: (context, proSnap) {
        final proyectos = proSnap.data ?? const <String>[];
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _prodStream(),
          builder: (context, prodSnap) {
            final docs = prodSnap.data?.docs ?? const [];

            // Filtrado
            final filtered = docs.where((e) {
              final m = e.data();
              if (_projectName != null && _projectName!.isNotEmpty) {
                if ((m['proyecto'] ?? '').toString().trim() != _projectName)
                  return false;
              }
              if (_range != null) {
                final ts = m['fecha'];
                DateTime? d;
                if (ts is Timestamp) d = ts.toDate();
                if (d == null) return false;
                final only = DateTime(d.year, d.month, d.day);
                if (only.isBefore(_range!.start) || only.isAfter(_range!.end))
                  return false;
              }
              return true;
            }).toList();

            int sumInt(String k) {
              int s = 0;
              for (final e in filtered) {
                final v = e.data()[k];
                if (v is int)
                  s += v;
                else if (v is num)
                  s += v.toInt();
                else
                  s += int.tryParse('${v ?? 0}') ?? 0;
              }
              return s;
            }

            final total = sumInt('cantidad');
            final pass = sumInt('pass');
            final fail = sumInt('fail');
            final scrap = sumInt('scrap');
            final tForYield = pass + fail + scrap;
            final yieldPct = tForYield == 0 ? 0.0 : (pass / tForYield) * 100.0;

            // Top 5 scrap por operación
            final Map<String, int> scrapByOp = {};
            for (final e in filtered) {
              final m = e.data();
              final op = (m['operacionNombre'] ?? m['operacion'] ?? '')
                  .toString()
                  .trim();
              final s = (m['scrap'] is num)
                  ? (m['scrap'] as num).toInt()
                  : int.tryParse('${m['scrap'] ?? 0}') ?? 0;
              if (s > 0) scrapByOp[op] = (scrapByOp[op] ?? 0) + s;
            }
            final topOps = scrapByOp.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Filtros
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _projectName,
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('Todos los proyectos'),
                            ),
                            ...proyectos
                                .map(
                                  (p) => DropdownMenuItem<String>(
                                    value: p,
                                    child: Text(p),
                                  ),
                                )
                                .toList(),
                          ],
                          onChanged: (v) => setState(() => _projectName = v),
                          decoration: const InputDecoration(
                            labelText: 'Proyecto',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.date_range),
                        label: Text(
                          _range == null
                              ? 'Rango de fechas'
                              : '${DateFormat('yyyy-MM-dd').format(_range!.start)} – ${DateFormat('yyyy-MM-dd').format(_range!.end)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: () async {
                          final now = DateTime.now();
                          final picked = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(now.year - 2),
                            lastDate: DateTime(now.year + 2),
                            initialDateRange:
                                _range ??
                                DateTimeRange(
                                  start: DateTime(now.year, now.month, 1),
                                  end: now,
                                ),
                          );
                          if (picked != null) setState(() => _range = picked);
                        },
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () => setState(() {
                          _projectName = null;
                          _range = null;
                        }),
                        icon: const Icon(Icons.filter_alt_off),
                        label: const Text('Limpiar'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // KPIs Producción
                  const Text(
                    'KPIs de Producción',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _kpi('Cantidad', total.toString()),
                      _kpi('Pass', pass.toString()),
                      _kpi('Fail', fail.toString()),
                      _kpi('Scrap', scrap.toString()),
                      _kpi('Yield %', '${yieldPct.toStringAsFixed(1)}%'),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Mini tendencia de producción (últimos 6 periodos por día)
                  const Text(
                    'Tendencia de producción (últimos días)',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _miniTrend(filtered),

                  const SizedBox(height: 16),

                  // Top Scrap por operación
                  const Text(
                    'Top scrap por operación',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (topOps.isEmpty)
                    const Text('Sin scrap en el periodo')
                  else
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            ...topOps
                                .take(5)
                                .map(
                                  (e) => ListTile(
                                    dense: true,
                                    leading: CircleAvatar(
                                      backgroundColor: Colors.red.withOpacity(
                                        .12,
                                      ),
                                      child: const Icon(
                                        Icons.warning,
                                        color: Colors.red,
                                      ),
                                    ),
                                    title: Text(
                                      e.key.isEmpty ? '(sin operación)' : e.key,
                                    ),
                                    trailing: Text('Scrap: ${e.value}'),
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 16),

                  // Últimas actividades
                  const Text(
                    'Últimas actividades',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: filtered.take(10).map((e) {
                        final m = e.data();
                        final fecha = (m['fecha'] as Timestamp?)?.toDate();
                        final proyecto = (m['proyecto'] ?? '').toString();
                        final pn = (m['numeroParte'] ?? '').toString();
                        final op =
                            (m['operacionNombre'] ?? m['operacion'] ?? '')
                                .toString();
                        final st = (m['status'] ?? '').toString();
                        return ListTile(
                          dense: true,
                          title: Text('$proyecto · $pn'),
                          subtitle: Text('Op: $op · St: $st'),
                          trailing: Text(
                            fecha == null
                                ? ''
                                : DateFormat('yyyy-MM-dd').format(fecha),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _kpi(String label, String value) => SizedBox(
    width: 160,
    child: Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    ),
  );

  // Mini chart (línea) con FL Chart — últimos 6 días
  Widget _miniTrend(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    // Agrupar por día (yyyy-MM-dd)
    final Map<String, int> perDay = {};
    for (final e in docs) {
      final ts = e.data()['fecha'];
      if (ts is! Timestamp) continue;
      final d = ts.toDate();
      final key = DateFormat('yyyy-MM-dd').format(d);
      final val =
          (e.data()['cantidad'] as num?)?.toInt() ??
          int.tryParse('${e.data()['cantidad'] ?? 0}') ??
          0;
      perDay[key] = (perDay[key] ?? 0) + val;
    }
    final sorted = perDay.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final last = sorted.length > 6 ? sorted.sublist(sorted.length - 6) : sorted;

    final spots = <FlSpot>[];
    for (int i = 0; i < last.length; i++) {
      spots.add(FlSpot(i.toDouble(), last[i].value.toDouble()));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: SizedBox(
          height: 140,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (spots.isEmpty ? 5 : spots.length - 1).toDouble(),
              minY: 0,
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  color: Colors.indigo,
                  barWidth: 3,
                  dotData: const FlDotData(show: false),
                ),
              ],
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      if (i >= 0 && i < last.length) {
                        final lbl = last[i].key.substring(5); // MM-dd
                        return Text(lbl, style: const TextStyle(fontSize: 10));
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),
              gridData: FlGridData(show: true, drawVerticalLine: false),
              borderData: FlBorderData(show: false),
            ),
          ),
        ),
      ),
    );
  }
}
