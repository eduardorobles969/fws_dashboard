// lib/screens/production_chart_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class ProductionChartScreen extends StatefulWidget {
  const ProductionChartScreen({super.key});

  @override
  State<ProductionChartScreen> createState() => _ProductionChartScreenState();
}

class _ProductionChartScreenState extends State<ProductionChartScreen> {
  // Vista y filtros
  String _modoVista = 'semanal'; // 'semanal' | 'mensual'
  String? _projectName; // filtra por nombre del proyecto (campo 'proyecto')
  String _chartStatus = 'todos'; // 'todos'|'pendiente'|'en proceso'|'hecho'
  DateTimeRange? _chartRange;
  String _metric = 'cantidad'; // 'cantidad'|'pass'|'fail'|'scrap'|'yield'

  // Colores por proyecto
  final List<Color> _palette = const [
    Color(0xFF3F51B5), // indigo
    Color(0xFF009688), // teal
    Color(0xFFFF5722), // deepOrange
    Color(0xFF9C27B0), // purple
    Color(0xFF4CAF50), // green
    Color(0xFF607D8B), // blueGrey
    Color(0xFFFF4081), // pinkAccent
    Color(0xFFFFC107), // amber
    Color(0xFF00BCD4), // cyan
    Color(0xFFFF5252), // redAccent
  ];
  final Map<String, Color> _projectColors = {};
  Color _getColorForProject(String p) {
    return _projectColors.putIfAbsent(
      p,
      () => _palette[_projectColors.length % _palette.length],
    );
  }

  // ---- Helpers de tiempo
  // Semana ISO (1..53)
  int _isoWeekNumber(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    final thursday = d.add(Duration(days: 3 - ((d.weekday + 6) % 7)));
    final firstThursday = DateTime(thursday.year, 1, 4);
    return 1 + ((thursday.difference(firstThursday).inDays) / 7).floor();
  }

  // ---- Futuro para lista de proyectos activos (por nombre)
  Future<List<String>> _loadProjectNames() async {
    final qs = await FirebaseFirestore.instance
        .collection('projects')
        .where('activo', isEqualTo: true)
        .orderBy('proyecto')
        .get();
    final out = <String>[];
    for (final d in qs.docs) {
      final name = (d.data()['proyecto'] ?? '').toString().trim();
      if (name.isNotEmpty) out.add(name);
    }
    if (out.isEmpty) {
      // Fallback: lee de production_daily
      final qs2 = await FirebaseFirestore.instance
          .collection('production_daily')
          .limit(200)
          .get();
      for (final d in qs2.docs) {
        final name = (d.data()['proyecto'] ?? '').toString().trim();
        if (name.isNotEmpty && !out.contains(name)) out.add(name);
      }
      out.sort();
    }
    return out;
  }

  // ---- Stream base
  Stream<QuerySnapshot<Map<String, dynamic>>> _baseStream() {
    // No filtramos por proyecto aquí; filtramos en cliente por nombre 'proyecto'.
    return FirebaseFirestore.instance
        .collection('production_daily')
        .orderBy('fecha', descending: false)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _loadProjectNames(),
      builder: (context, projectsSnap) {
        final proyectos = projectsSnap.data ?? const <String>[];

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _baseStream(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(child: Text('Error cargando datos'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            // Filtros en cliente (status + rango + proyecto)
            final docs = snapshot.data!.docs.where((doc) {
              final m = doc.data();

              // Proyecto
              if (_projectName != null &&
                  _projectName!.isNotEmpty &&
                  (m['proyecto'] ?? '').toString().trim() != _projectName) {
                return false;
              }

              // Status
              final status = (m['status'] ?? 'pendiente')
                  .toString()
                  .toLowerCase();
              if (_chartStatus != 'todos' && status != _chartStatus) {
                return false;
              }

              // Rango de fechas
              if (_chartRange != null) {
                DateTime? dt;
                final v = m['fecha'];
                if (v is Timestamp) dt = v.toDate();
                dt ??= DateTime.tryParse(v?.toString() ?? '');
                if (dt == null) return false;
                if (dt.isBefore(_chartRange!.start) ||
                    dt.isAfter(_chartRange!.end)) {
                  return false;
                }
              }

              return true;
            }).toList();

            // ---- Agrupación por periodo + proyecto
            final Map<String, _Point> grouped = {};

            for (final doc in docs) {
              final d = doc.data();

              // Fecha / semana / mes / año robustos
              DateTime? date;
              final v = d['fecha'];
              if (v is Timestamp) {
                date = v.toDate();
              } else {
                date = DateTime.tryParse(v?.toString() ?? '');
              }

              final anio = (d['anio'] is int)
                  ? d['anio'] as int
                  : (date?.year ?? 0);
              final semana = (d['semana'] is int)
                  ? d['semana'] as int
                  : (date != null ? _isoWeekNumber(date) : 0);
              final mes = (d['mes'] is int)
                  ? d['mes'] as int
                  : (date?.month ?? 0);

              final anioSemana = (anio != 0 && semana != 0)
                  ? anio * 100 + semana
                  : 0;
              final anioMes = (anio != 0 && mes != 0) ? anio * 100 + mes : 0;

              final proyecto = (d['proyecto'] ?? 'Sin proyecto').toString();

              // valores
              final cantidad =
                  int.tryParse(d['cantidad']?.toString() ?? '') ?? 0;
              final pass = int.tryParse(d['pass']?.toString() ?? '') ?? 0;
              final fail = int.tryParse(d['fail']?.toString() ?? '') ?? 0;
              final scrap = int.tryParse(d['scrap']?.toString() ?? '') ?? 0;

              late final String key; // clave de agrupación
              late final int etiqueta; // número semana/mes

              if (_modoVista == 'semanal') {
                if (anioSemana == 0) continue;
                key = '$anioSemana|$proyecto';
                etiqueta = semana;
              } else {
                if (anioMes == 0) continue;
                key = '$anioMes|$proyecto';
                etiqueta = mes;
              }

              final prev = grouped[key];
              final acc = _Point(
                periodoKey: key.split('|').first,
                periodoLabel: etiqueta,
                proyecto: proyecto,
                cantidad: (prev?.cantidad ?? 0) + cantidad,
                pass: (prev?.pass ?? 0) + pass,
                fail: (prev?.fail ?? 0) + fail,
                scrap: (prev?.scrap ?? 0) + scrap,
              );
              grouped[key] = acc;
            }

            // Lista ordenada por periodoKey y luego proyecto
            final data = grouped.values.toList()
              ..sort((a, b) {
                final c = a.periodoKey.compareTo(b.periodoKey);
                if (c != 0) return c;
                return a.proyecto.compareTo(b.proyecto);
              });

            // Escala Y según métrica actual
            double valueOf(_Point p) {
              switch (_metric) {
                case 'pass':
                  return p.pass.toDouble();
                case 'fail':
                  return p.fail.toDouble();
                case 'scrap':
                  return p.scrap.toDouble();
                case 'yield':
                  final t = p.pass + p.fail + p.scrap;
                  return t == 0 ? 0 : (p.pass / t) * 100.0; // porcentaje
                case 'cantidad':
                default:
                  return p.cantidad.toDouble();
              }
            }

            final double maxY = data.isNotEmpty
                ? (data.map(valueOf).reduce((a, b) => a > b ? a : b) * 1.15)
                      .clamp(5, 1e9)
                : 10.0;
            final double interval = (maxY / 5).ceilToDouble().clamp(1.0, 1e9);

            // Eje X: labels compactos
            String xLabelOf(_Point p) => _modoVista == 'semanal'
                ? 'S${p.periodoLabel}'
                : 'M${p.periodoLabel}';

            // Leyenda (proyectos únicos en los datos)
            final legendProjects = <String>{
              for (final p in data) p.proyecto,
            }.toList()..sort();

            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                children: [
                  // ===== Filtros =====
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
                            ...proyectos.map(
                              (p) => DropdownMenuItem<String>(
                                value: p,
                                child: Text(p),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => _projectName = v),
                          decoration: const InputDecoration(
                            labelText: 'Proyecto',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _chartStatus,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                              value: 'todos',
                              child: Text('Todos'),
                            ),
                            DropdownMenuItem(
                              value: 'pendiente',
                              child: Text('Pendiente'),
                            ),
                            DropdownMenuItem(
                              value: 'en proceso',
                              child: Text('En proceso'),
                            ),
                            DropdownMenuItem(
                              value: 'hecho',
                              child: Text('Hecho'),
                            ),
                          ],
                          onChanged: (v) =>
                              setState(() => _chartStatus = v ?? 'todos'),
                          decoration: const InputDecoration(
                            labelText: 'Status',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.date_range),
                          label: Text(
                            _chartRange == null
                                ? 'Rango de fechas'
                                : '${DateFormat('yyyy-MM-dd').format(_chartRange!.start)} → ${DateFormat('yyyy-MM-dd').format(_chartRange!.end)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: () async {
                            final now = DateTime.now();
                            final picked = await showDateRangePicker(
                              context: context,
                              firstDate: DateTime(now.year - 3),
                              lastDate: DateTime(now.year + 3),
                              initialDateRange:
                                  _chartRange ??
                                  DateTimeRange(
                                    start: DateTime(now.year, now.month, 1),
                                    end: now,
                                  ),
                            );
                            if (picked != null) {
                              setState(() => _chartRange = picked);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'semanal',
                            label: Text('Semana'),
                          ),
                          ButtonSegment(value: 'mensual', label: Text('Mes')),
                        ],
                        selected: {_modoVista},
                        onSelectionChanged: (s) =>
                            setState(() => _modoVista = s.first),
                      ),
                    ],
                  ),

                  // ===== Selector de Métrica (ChoiceChip horizontal scrollable) =====
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          const SizedBox(width: 2),
                          ChoiceChip(
                            label: const Text('Cantidad'),
                            selected: _metric == 'cantidad',
                            onSelected: (_) =>
                                setState(() => _metric = 'cantidad'),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Pass'),
                            selected: _metric == 'pass',
                            onSelected: (_) => setState(() => _metric = 'pass'),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Fail'),
                            selected: _metric == 'fail',
                            onSelected: (_) => setState(() => _metric = 'fail'),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Scrap'),
                            selected: _metric == 'scrap',
                            onSelected: (_) =>
                                setState(() => _metric = 'scrap'),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Yield %'),
                            selected: _metric == 'yield',
                            onSelected: (_) =>
                                setState(() => _metric = 'yield'),
                          ),
                          const SizedBox(width: 2),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Leyenda de proyectos
                  if (legendProjects.isNotEmpty)
                    SizedBox(
                      height: 32,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemBuilder: (_, i) {
                          final p = legendProjects[i];
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: _getColorForProject(p),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(p, style: const TextStyle(fontSize: 12)),
                            ],
                          );
                        },
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemCount: legendProjects.length,
                      ),
                    ),
                  const SizedBox(height: 8),

                  // ===== Chart =====
                  if (data.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text('Sin datos con los filtros actuales.'),
                      ),
                    )
                  else
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
                                    ? 'S${p.periodoLabel}'
                                    : 'M${p.periodoLabel}';
                                final val = valueOf(p);
                                final metricLabel = _metric == 'yield'
                                    ? '${val.toStringAsFixed(1)} %'
                                    : val.toStringAsFixed(0);
                                return BarTooltipItem(
                                  '$periodo • ${p.proyecto}\n$metricLabel',
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
                                  toY: valueOf(p),
                                  color: _getColorForProject(p.proyecto),
                                  width: 18,
                                  borderRadius: BorderRadius.circular(6),
                                  backDrawRodData: BackgroundBarChartRodData(
                                    show: _metric != 'yield', // yield es %
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
                                reservedSize: 44,
                                getTitlesWidget: (value, meta) {
                                  final i = value.toInt();
                                  if (i >= 0 && i < data.length) {
                                    final p = data[i];
                                    return Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          xLabelOf(p),
                                          style: const TextStyle(fontSize: 10),
                                        ),
                                        SizedBox(
                                          width: 60,
                                          child: Text(
                                            p.proyecto,
                                            style: const TextStyle(
                                              fontSize: 10,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      ],
                                    );
                                  }
                                  return const SizedBox.shrink();
                                },
                              ),
                            ),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                interval: interval,
                                getTitlesWidget: (value, meta) => Text(
                                  _metric == 'yield'
                                      ? value.toStringAsFixed(0)
                                      : value.toInt().toString(),
                                  style: const TextStyle(fontSize: 10),
                                ),
                                reservedSize: 36,
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
                            horizontalInterval: interval,
                            getDrawingHorizontalLine: (v) => FlLine(
                              color: Colors.grey.shade300,
                              strokeWidth: 1,
                            ),
                          ),
                          borderData: FlBorderData(show: false),
                        ),
                        swapAnimationDuration: const Duration(
                          milliseconds: 800,
                        ),
                        swapAnimationCurve: Curves.easeOutExpo,
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
}

/// Punto agregado por periodo + proyecto
class _Point {
  final String
  periodoKey; // "202535" (anio*100+semana) o "202512" (anio*100+mes)
  final int periodoLabel; // número de semana o mes (1..53 / 1..12)
  final String proyecto;
  final int cantidad;
  final int pass;
  final int fail;
  final int scrap;

  _Point({
    required this.periodoKey,
    required this.periodoLabel,
    required this.proyecto,
    required this.cantidad,
    required this.pass,
    required this.fail,
    required this.scrap,
  });
}
