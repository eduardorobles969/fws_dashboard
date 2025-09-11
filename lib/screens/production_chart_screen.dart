// lib/screens/production_chart_screen.dart (rebuild with bar tap details)
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class ProductionChartScreen extends StatefulWidget {
  const ProductionChartScreen({super.key});

  @override
  State<ProductionChartScreen> createState() => _ProductionChartScreenState();
}

class _ProductionChartScreenState extends State<ProductionChartScreen> {
  // Filtros
  String _modoVista = 'semanal'; // 'semanal' | 'mensual'
  String? _projectName; // nombre del proyecto (campo 'proyecto')
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
  Color _getColorForProject(String p) => _projectColors.putIfAbsent(
    p,
    () => _palette[_projectColors.length % _palette.length],
  );

  // Helpers
  int _isoWeekNumber(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    final thursday = d.add(Duration(days: 3 - ((d.weekday + 6) % 7)));
    final firstThursday = DateTime(thursday.year, 1, 4);
    return 1 + ((thursday.difference(firstThursday).inDays) / 7).floor();
  }

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

  Stream<QuerySnapshot<Map<String, dynamic>>> _baseStream() {
    return FirebaseFirestore.instance
        .collection('production_daily')
        .orderBy('fecha', descending: false)
        .snapshots();
  }

  // ---------- Detalle por barra ----------
  Future<void> _showBarDetails(_Point p) async {
    final periodField = _modoVista == 'semanal' ? 'anioSemana' : 'anioMes';
    final periodValue = int.tryParse(p.periodoKey) ?? 0;
    if (periodValue == 0) return;

    try {
      final qs = await FirebaseFirestore.instance
          .collection('production_daily')
          .where(periodField, isEqualTo: periodValue)
          .get();

      final Map<String, _DetailRow> acc = {};
      for (final d in qs.docs) {
        final m = d.data();
        if ((m['proyecto'] ?? '').toString().trim() != p.proyecto) continue;

        final status = (m['status'] ?? '').toString().toLowerCase();
        if (_chartStatus != 'todos' && status != _chartStatus) continue;

        final pn = (m['numeroParte'] ?? '').toString().trim();
        final op = (m['operacionNombre'] ?? m['operacion'] ?? '')
            .toString()
            .trim();
        final maquina = (m['maquinaNombre'] ?? '').toString().trim();

        final cantidad =
            (m['cantidad'] as num?)?.toInt() ??
            int.tryParse('${m['cantidad'] ?? ''}') ??
            0;
        final pass =
            (m['pass'] as num?)?.toInt() ??
            int.tryParse('${m['pass'] ?? ''}') ??
            0;
        final fail =
            (m['fail'] as num?)?.toInt() ??
            int.tryParse('${m['fail'] ?? ''}') ??
            0;
        final scrap =
            (m['scrap'] as num?)?.toInt() ??
            int.tryParse('${m['scrap'] ?? ''}') ??
            0;

        // Filtrar por métrica si aplica
        if (_metric == 'scrap' && scrap <= 0) continue;
        if (_metric == 'fail' && fail <= 0) continue;
        if (_metric == 'pass' && pass <= 0) continue;
        if (_metric == 'cantidad' && cantidad <= 0) continue;

        final key = '$pn|$op';
        final prev = acc[key];
        if (prev == null) {
          acc[key] = _DetailRow(
            pn: pn.isEmpty ? '—' : pn,
            operacion: op.isEmpty ? '—' : op,
            maquina: maquina,
            cantidad: cantidad,
            pass: pass,
            fail: fail,
            scrap: scrap,
          );
        } else {
          prev.cantidad += cantidad;
          prev.pass += pass;
          prev.fail += fail;
          prev.scrap += scrap;
          if (prev.maquina.isEmpty && maquina.isNotEmpty)
            prev.maquina = maquina;
        }
      }

      var rows = acc.values.toList();
      num val(_DetailRow r) {
        switch (_metric) {
          case 'pass':
            return r.pass;
          case 'fail':
            return r.fail;
          case 'scrap':
            return r.scrap;
          case 'yield':
            final t = r.pass + r.fail + r.scrap;
            return t == 0 ? 0 : (r.pass / t);
          case 'cantidad':
          default:
            return r.cantidad;
        }
      }

      rows.sort((a, b) => val(b).compareTo(val(a)));

      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_modoVista == 'semanal' ? 'Semana' : 'Mes'} ${p.periodoLabel} · ${p.proyecto}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _pill('Métrica: ${_metric.toUpperCase()}'),
                    if (_chartStatus != 'todos') ...[
                      const SizedBox(width: 8),
                      _pill('Status: ${_chartStatus}'),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Sin resultados con los filtros actuales.'),
                  )
                else
                  Flexible(
                    child: Card(
                      elevation: 1,
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final r = rows[i];
                          final subt = [
                            if (r.operacion.isNotEmpty)
                              'Operación: ${r.operacion}',
                            if (r.maquina.isNotEmpty) 'Máquina: ${r.maquina}',
                          ].join('  ·  ');
                          final metrics = _metric == 'yield'
                              ? 'pass:${r.pass} fail:${r.fail} scrap:${r.scrap}'
                              : 'cant:${r.cantidad} pass:${r.pass} fail:${r.fail} scrap:${r.scrap}';
                          return ListTile(
                            dense: true,
                            title: Text(r.pn),
                            subtitle: Text(subt),
                            trailing: Text(metrics),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No se pudo cargar detalle: $e')));
    }
  }

  Widget _pill(String t) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(t, style: const TextStyle(fontSize: 12)),
  );

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

            // Filtros en cliente
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
                if (dt == null) return false;
                final d = DateTime(dt.year, dt.month, dt.day);
                if (d.isBefore(_chartRange!.start) ||
                    d.isAfter(_chartRange!.end)) {
                  return false;
                }
              }
              return true;
            }).toList();

            // Agrupar por periodo(proyecto)
            final Map<String, _Point> grouped = {};
            for (final e in docs) {
              final d = e.data();
              final ts = d['fecha'] as Timestamp?;
              final dt = ts?.toDate();
              if (dt == null) continue;
              final anio = dt.year;
              final mes = dt.month;
              final semana = _isoWeekNumber(dt);
              final anioSemana = anio * 100 + semana;
              final anioMes = anio * 100 + mes;

              final proyecto = (d['proyecto'] ?? 'Sin proyecto').toString();
              final cantidad =
                  int.tryParse(d['cantidad']?.toString() ?? '') ?? 0;
              final pass = int.tryParse(d['pass']?.toString() ?? '') ?? 0;
              final fail = int.tryParse(d['fail']?.toString() ?? '') ?? 0;
              final scrap = int.tryParse(d['scrap']?.toString() ?? '') ?? 0;

              late final String key;
              late final int etiqueta;
              if (_modoVista == 'semanal') {
                key = '$anioSemana|$proyecto';
                etiqueta = semana;
              } else {
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

            final data = grouped.values.toList()
              ..sort((a, b) {
                final c = a.periodoKey.compareTo(b.periodoKey);
                if (c != 0) return c;
                return a.proyecto.compareTo(b.proyecto);
              });

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
                  return t == 0 ? 0 : (p.pass / t) * 100.0;
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

            String xLabelOf(_Point p) => _modoVista == 'semanal'
                ? 'S${p.periodoLabel}'
                : 'M${p.periodoLabel}';

            final legendProjects = <String>{
              for (final p in data) p.proyecto,
            }.toList()..sort();

            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
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
                                : '${DateFormat('yyyy-MM-dd').format(_chartRange!.start)} – ${DateFormat('yyyy-MM-dd').format(_chartRange!.end)}',
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
                            if (picked != null)
                              setState(() => _chartRange = picked);
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
                  const SizedBox(height: 8),
                  // Métrica
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          const SizedBox(width: 2),
                          _metricChip('Cantidad'),
                          const SizedBox(width: 8),
                          _metricChip('Pass', keyVal: 'pass'),
                          const SizedBox(width: 8),
                          _metricChip('Fail', keyVal: 'fail'),
                          const SizedBox(width: 8),
                          _metricChip('Scrap', keyVal: 'scrap'),
                          const SizedBox(width: 8),
                          _metricChip('Yield %', keyVal: 'yield'),
                          const SizedBox(width: 2),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Leyenda
                  if (legendProjects.isNotEmpty)
                    Container(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        children: legendProjects
                            .map(
                              (p) => _legendItem(
                                color: _getColorForProject(p),
                                text: p,
                              ),
                            )
                            .toList(),
                      ),
                    ),

                  // Chart
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
                            handleBuiltInTouches: true,
                            touchCallback: (event, response) {
                              if (!event.isInterestedForInteractions) return;
                              final spot = response?.spot;
                              if (spot == null) return;
                              final i = spot.touchedBarGroupIndex;
                              if (i >= 0 && i < data.length)
                                _showBarDetails(data[i]);
                            },
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
                                  '$periodo · ${p.proyecto}\n$metricLabel',
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
                                    show: _metric != 'yield',
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

  Widget _metricChip(String label, {String? keyVal}) => ChoiceChip(
    label: Text(label),
    selected: _metric == (keyVal ?? 'cantidad'),
    onSelected: (_) => setState(() => _metric = keyVal ?? 'cantidad'),
  );

  Widget _legendItem({required Color color, required String text}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(fontSize: 12)),
    ],
  );
}

// Modelos locales
class _Point {
  final String
  periodoKey; // '202536' (anio*100+semana) o '202512' (anio*100+mes)
  final int periodoLabel; // número semana/mes
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

class _DetailRow {
  final String pn;
  final String operacion;
  String maquina;
  int cantidad;
  int pass;
  int fail;
  int scrap;

  _DetailRow({
    required this.pn,
    required this.operacion,
    required this.maquina,
    required this.cantidad,
    required this.pass,
    required this.fail,
    required this.scrap,
  });
}
