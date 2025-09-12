// lib/screens/gantt_screen.dart
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class GanttScreen extends StatefulWidget {
  const GanttScreen({super.key});
  @override
  State<GanttScreen> createState() => _GanttScreenState();
}

class _GanttScreenState extends State<GanttScreen> {
  // Zoom (ancho de un día) y ancho del panel izquierdo
  double _dayW = 28;
  double _labelsW = 260;

  String? _selectedProject;

  // Scrolls sincronizados
  final _hHeader = ScrollController();
  final _hBody = ScrollController();
  final _vLabels = ScrollController();
  final _vBody = ScrollController();

  bool _syncHFromHeader = false, _syncHFromBody = false;
  bool _syncVFromLabels = false, _syncVFromBody = false;

  // Para “Ir a hoy”
  DateTime? _lastMinD;
  double _lastCanvasW = 0;

  // Catálogo de operaciones: nombre -> order
  late final Future<Map<String, int>> _opsOrderFuture;

  @override
  void initState() {
    super.initState();

    _opsOrderFuture = _loadOpsOrder();

    // --- Horizontal: BIDIRECCIONAL ---
    _hBody.addListener(() {
      if (_syncHFromHeader) return;
      _syncHFromBody = true;
      if (_hHeader.hasClients && _hHeader.offset != _hBody.offset) {
        _hHeader.jumpTo(_hBody.offset);
      }
      _syncHFromBody = false;
    });

    _hHeader.addListener(() {
      if (_syncHFromBody) return;
      _syncHFromHeader = true;
      if (_hBody.hasClients && _hBody.offset != _hHeader.offset) {
        _hBody.jumpTo(_hHeader.offset);
      }
      _syncHFromHeader = false;
    });

    // --- Vertical: BIDIRECCIONAL ---
    _vLabels.addListener(() {
      if (_syncVFromBody) return;
      _syncVFromLabels = true;
      if (_vBody.hasClients && _vBody.offset != _vLabels.offset) {
        _vBody.jumpTo(_vLabels.offset);
      }
      _syncVFromLabels = false;
    });

    _vBody.addListener(() {
      if (_syncVFromLabels) return;
      _syncVFromBody = true;
      if (_vLabels.hasClients && _vLabels.offset != _vBody.offset) {
        _vLabels.jumpTo(_vBody.offset);
      }
      _syncVFromBody = false;
    });
  }

  @override
  void dispose() {
    _hHeader.dispose();
    _hBody.dispose();
    _vLabels.dispose();
    _vBody.dispose();
    super.dispose();
  }

  // ===== Cargar orden de operaciones (normalizado en MAYÚSCULAS) =====
  Future<Map<String, int>> _loadOpsOrder() async {
    final map = <String, int>{};
    final res = await FirebaseFirestore.instance
        .collection('operations')
        .orderBy('orden')
        .get();
    for (final d in res.docs) {
      final nombre = (d.data()['nombre'] ?? '').toString().trim().toUpperCase();
      final orden = (d.data()['orden'] is int)
          ? d.data()['orden'] as int
          : int.tryParse('${d.data()['orden']}') ?? 9999;
      if (nombre.isNotEmpty && nombre != 'RETRABAJO') {
        map[nombre] = orden;
      }
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    // Query base
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'production_daily',
    );

    if (_selectedProject != null && _selectedProject!.isNotEmpty) {
      q = q.where('proyecto', isEqualTo: _selectedProject);
    }
    q = q.orderBy('proyecto').orderBy('numeroParte');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gantt de producción'),
        actions: [
          IconButton(
            tooltip: _labelsW > 80 ? 'Colapsar panel' : 'Expandir panel',
            icon: Icon(
              _labelsW > 80 ? Icons.chevron_left : Icons.chevron_right,
            ),
            onPressed: () =>
                setState(() => _labelsW = _labelsW > 80 ? 56 : 260),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                // Filtro por proyecto
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('projects')
                        .where('activo', isEqualTo: true)
                        .orderBy('proyecto')
                        .snapshots(),
                    builder: (context, snap) {
                      final items = snap.data?.docs ?? const [];
                      return DropdownButtonFormField<String>(
                        value: _selectedProject,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Filtrar por proyecto',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('Todos'),
                          ),
                          ...items.map((d) {
                            final name = (d['proyecto'] ?? '') as String;
                            return DropdownMenuItem(
                              value: name,
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }),
                        ],
                        onChanged: (v) => setState(() => _selectedProject = v),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                // Zoom
                SizedBox(
                  width: 170,
                  child: Row(
                    children: [
                      const Icon(Icons.zoom_out, size: 18),
                      Expanded(
                        child: Slider(
                          min: 16,
                          max: 48,
                          divisions: 16,
                          value: _dayW,
                          onChanged: (v) => setState(() => _dayW = v),
                        ),
                      ),
                      const Icon(Icons.zoom_in, size: 18),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),

      body: FutureBuilder<Map<String, int>>(
        future: _opsOrderFuture,
        builder: (ctx, opsSnap) {
          if (opsSnap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (opsSnap.hasError) {
            return Center(child: Text('Error ops: ${opsSnap.error}'));
          }
          final opsOrder = opsSnap.data ?? const <String, int>{};

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: q.snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text('Error: ${snap.error}'));
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Center(child: Text('Sin datos.'));
              }

              // ===== 1) Agrupar Proyecto → Parte → Operaciones
              final grouped =
                  <String, Map<String, List<Map<String, dynamic>>>>{};
              DateTime? minD, maxD;

              for (final d in docs) {
                final m = d.data();
                final proyecto = (m['proyecto'] ?? '—') as String;
                final parte = (m['numeroParte'] ?? '—') as String;

                final opName = (m['operacionNombre'] ?? m['operacion'] ?? '—')
                    .toString();
                if (opName.trim().toUpperCase() == 'RETRABAJO') continue;
                final sec = (m['opSecuencia'] ?? 9999) as int;

                // Plan
                final DateTime? planStart = (m['fecha'] as Timestamp?)
                    ?.toDate();
                final DateTime? planEnd =
                    (m['fechaCompromiso'] as Timestamp?)?.toDate() ??
                    (planStart?.add(const Duration(days: 1)));

                // Real
                final DateTime? realStart = (m['inicio'] as Timestamp?)
                    ?.toDate();
                DateTime? realEnd = (m['fin'] as Timestamp?)?.toDate();
                if (realStart != null && realEnd == null) {
                  final now = DateTime.now();
                  realEnd = now.isBefore(realStart) ? realStart : now;
                }

                for (final dt in [planStart, planEnd, realStart, realEnd]) {
                  if (dt == null) continue;
                  minD = (minD == null || dt.isBefore(minD)) ? dt : minD;
                  maxD = (maxD == null || dt.isAfter(maxD)) ? dt : maxD;
                }

                grouped.putIfAbsent(proyecto, () => {});
                grouped[proyecto]!.putIfAbsent(parte, () => []);
                grouped[proyecto]![parte]!.add({
                  'op': opName,
                  'opSecuencia': sec,
                  'planStart': planStart,
                  'planEnd': planEnd,
                  'realStart': realStart,
                  'realEnd': realEnd,
                });
              }

              // Rango visible
              minD ??= DateTime.now();
              maxD ??= DateTime.now().add(const Duration(days: 7));
              minD = DateTime(minD.year, minD.month, minD.day);
              maxD = DateTime(maxD.year, maxD.month, maxD.day);

              final totalDays = max(1, maxD.difference(minD).inDays + 1);
              final canvasWidth = totalDays * _dayW;

              // Guardar para “Ir a hoy”
              _lastMinD = minD;
              _lastCanvasW = canvasWidth;

              // ===== 2) Orden “escalera”
              DateTime? firstOfOps(List<Map<String, dynamic>> ops) {
                DateTime? out;
                for (final o in ops) {
                  final p = o['planStart'] as DateTime?;
                  final r = o['realStart'] as DateTime?;
                  final c = p ?? r;
                  if (c == null) continue;
                  if (out == null || c.isBefore(out)) out = c;
                }
                return out;
              }

              final projectEntries = grouped.entries.toList()
                ..sort((a, b) {
                  DateTime? aMin, bMin;
                  for (final ops in a.value.values) {
                    final f = firstOfOps(ops);
                    if (f != null) {
                      aMin = (aMin == null || f.isBefore(aMin)) ? f : aMin;
                    }
                  }
                  for (final ops in b.value.values) {
                    final f = firstOfOps(ops);
                    if (f != null) {
                      bMin = (bMin == null || f.isBefore(bMin)) ? f : bMin;
                    }
                  }
                  return (aMin ?? DateTime(2100)).compareTo(
                    bMin ?? DateTime(2100),
                  );
                });

              final rows = <_Row>[];
              for (final projEntry in projectEntries) {
                final project = projEntry.key;
                final parts = projEntry.value;

                rows.add(_Row.project(project));

                final partEntries = parts.entries.toList()
                  ..sort((a, b) {
                    final af = firstOfOps(a.value) ?? DateTime(2100);
                    final bf = firstOfOps(b.value) ?? DateTime(2100);
                    return af.compareTo(bf);
                  });

                for (final partEntry in partEntries) {
                  final pn = partEntry.key;

                  // === ORDEN POR CATÁLOGO OPERATIONS ===
                  final ops = List<Map<String, dynamic>>.from(partEntry.value)
                    ..sort((a, b) {
                      final an = (a['op'] ?? '')
                          .toString()
                          .trim()
                          .toUpperCase();
                      final bn = (b['op'] ?? '')
                          .toString()
                          .trim()
                          .toUpperCase();

                      final ao = opsOrder[an] ?? 9999;
                      final bo = opsOrder[bn] ?? 9999;

                      final byCatalog = ao.compareTo(bo);
                      if (byCatalog != 0) return byCatalog;

                      // Empate: caemos en opSecuencia y luego en alfabético
                      final sa = (a['opSecuencia'] is int)
                          ? a['opSecuencia'] as int
                          : int.tryParse('${a['opSecuencia']}') ?? 9999;
                      final sb = (b['opSecuencia'] is int)
                          ? b['opSecuencia'] as int
                          : int.tryParse('${b['opSecuencia']}') ?? 9999;

                      final bySeq = sa.compareTo(sb);
                      if (bySeq != 0) return bySeq;

                      return an.compareTo(bn);
                    });

                  rows.add(_Row.part(project, pn));
                  for (final op in ops) {
                    rows.add(
                      _Row.operation(
                        project: project,
                        part: pn,
                        label: '[${op['opSecuencia']}] ${op['op']}',
                        planStart: op['planStart'] as DateTime?,
                        planEnd: op['planEnd'] as DateTime?,
                        realStart: op['realStart'] as DateTime?,
                        realEnd: op['realEnd'] as DateTime?,
                      ),
                    );
                  }
                }
              }

              // ===== 3) UI
              return Column(
                children: [
                  // Header: título panel izquierdo + días
                  Row(
                    children: [
                      SizedBox(
                        width: _labelsW,
                        child: Container(
                          height: 40,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          color: Colors.grey.shade100,
                          child: const Text(
                            'Proyecto / Parte / Operación',
                            style: TextStyle(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: Stack(
                            children: [
                              // Header sigue el offset del cuerpo
                              ListView.builder(
                                controller: _hHeader,
                                scrollDirection: Axis.horizontal,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: totalDays,
                                itemBuilder: (_, i) {
                                  final d = minD!.add(Duration(days: i));
                                  return Container(
                                    width: _dayW,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      border: Border(
                                        right: BorderSide(
                                          color: Colors.grey.shade300,
                                          width: 1,
                                        ),
                                      ),
                                    ),
                                    child: Text(
                                      '${d.month}/${d.day}',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  );
                                },
                              ),
                              // Línea de hoy (restando offset del body)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: AnimatedBuilder(
                                    animation: _hBody,
                                    builder: (_, __) {
                                      final idx = DateTime.now()
                                          .difference(minD!)
                                          .inDays;
                                      final left =
                                          idx * _dayW -
                                          (_hBody.hasClients
                                              ? _hBody.offset
                                              : 0.0);
                                      return Align(
                                        alignment: Alignment.centerLeft,
                                        child: Transform.translate(
                                          offset: Offset(left, 0),
                                          child: Container(
                                            width: 2,
                                            color: Colors.deepOrange,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 1),

                  // Cuerpo: etiquetas + canvas
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Etiquetas
                        SizedBox(
                          width: _labelsW,
                          child: ListView.builder(
                            controller: _vLabels,
                            itemCount: rows.length,
                            itemBuilder: (_, i) {
                              final r = rows[i];
                              switch (r.type) {
                                case _RowType.project:
                                  return _labelProject(r.project!);
                                case _RowType.part:
                                  return _labelPart(r.part!);
                                case _RowType.operation:
                                  return _labelOp(r.label!);
                              }
                            },
                          ),
                        ),
                        // Canvas + línea de Hoy continua
                        Expanded(
                          child: Scrollbar(
                            child: SingleChildScrollView(
                              controller: _hBody,
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: canvasWidth,
                                child: Stack(
                                  children: [
                                    ListView.builder(
                                      controller: _vBody,
                                      itemCount: rows.length,
                                      itemBuilder: (_, i) {
                                        final r = rows[i];
                                        if (r.type != _RowType.operation) {
                                          return _rowSeparator(r.type);
                                        }
                                        return _barsRow(
                                          minStart: minD!,
                                          totalDays: totalDays,
                                          dayW: _dayW,
                                          planStart: r.planStart,
                                          planEnd: r.planEnd,
                                          realStart: r.realStart,
                                          realEnd: r.realEnd,
                                        );
                                      },
                                    ),
                                    // Línea de hoy en el cuerpo (sin restar offset)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: AnimatedBuilder(
                                          animation: _hBody,
                                          builder: (_, __) {
                                            final idx = DateTime.now()
                                                .difference(minD!)
                                                .inDays;
                                            final left = idx * _dayW;
                                            return Align(
                                              alignment: Alignment.topLeft,
                                              child: Transform.translate(
                                                offset: Offset(left, 0),
                                                child: Container(
                                                  width: 2,
                                                  color: Colors.deepOrange,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Divider(height: 1),
                  _legend(),
                  const SizedBox(height: 8),
                ],
              );
            },
          );
        },
      ),

      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.today),
        label: const Text('Ir a hoy'),
        onPressed: _scrollToToday,
      ),
    );
  }

  // ===== Etiquetas y separadores =====
  Widget _labelProject(String project) => Container(
    height: 32,
    color: Colors.grey.shade100,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Text(project, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  Widget _labelPart(String pn) => Container(
    height: 26,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Text('• $pn', overflow: TextOverflow.ellipsis),
  );

  Widget _labelOp(String label) => Container(
    height: 28,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.only(left: 28, right: 8),
    child: Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12),
    ),
  );

  Widget _rowSeparator(_RowType t) {
    final h = switch (t) {
      _RowType.project => 32.0,
      _RowType.part => 26.0,
      _RowType.operation => 28.0,
    };
    return Container(
      height: h,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
    );
  }

  // ===== Barras =====
  Widget _barsRow({
    required DateTime minStart,
    required int totalDays,
    required double dayW,
    DateTime? planStart,
    DateTime? planEnd,
    DateTime? realStart,
    DateTime? realEnd,
  }) {
    double leftOf(DateTime d) => d.difference(minStart).inDays * dayW;
    double widthOf(DateTime a, DateTime b) =>
        max(dayW * 0.8, (b.difference(a).inDays + 1) * dayW - 2);

    final children = <Widget>[];

    // Grid vertical sutil
    for (int i = 0; i < totalDays; i++) {
      children.add(
        Positioned(
          left: i * dayW,
          top: 0,
          bottom: 0,
          child: Container(width: 1, color: Colors.grey.withOpacity(0.12)),
        ),
      );
    }

    // Plan
    if (planStart != null && planEnd != null && !planEnd.isBefore(planStart)) {
      children.add(
        Positioned(
          left: leftOf(planStart),
          top: 8,
          child: Container(
            width: widthOf(planStart, planEnd),
            height: 8,
            decoration: BoxDecoration(
              color: Colors.blue.shade200,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      );
    }

    // Real
    if (realStart != null && realEnd != null && !realEnd.isBefore(realStart)) {
      children.add(
        Positioned(
          left: leftOf(realStart),
          top: 15,
          child: Container(
            width: widthOf(realStart, realEnd),
            height: 10,
            decoration: BoxDecoration(
              color: Colors.blue.shade700,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      );
    }

    return SizedBox(height: 28, child: Stack(children: children));
  }

  // ===== Leyenda =====
  Widget _legend() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        _box(Colors.blue.shade200),
        const SizedBox(width: 6),
        const Text('Plan'),
        const SizedBox(width: 16),
        _box(Colors.blue.shade700),
        const SizedBox(width: 6),
        const Text('Real'),
        const SizedBox(width: 16),
        Container(width: 12, height: 2, color: Colors.deepOrange),
        const SizedBox(width: 6),
        const Text('Hoy'),
      ],
    ),
  );

  Widget _box(Color c) => Container(
    width: 18,
    height: 10,
    decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
  );

  // ===== Scroll a “Hoy” (centra la vista horizontal)
  void _scrollToToday() {
    final minD = _lastMinD;
    if (minD == null) return;

    final now = DateTime.now();
    final base = DateTime(now.year, now.month, now.day);
    final int idx = base.difference(minD).inDays;

    final double viewW = MediaQuery.of(context).size.width - _labelsW;
    final double maxScroll = max(0.0, _lastCanvasW - viewW);

    final double target = (idx * _dayW - viewW / 2).clamp(0.0, maxScroll);

    if (_hBody.hasClients) {
      _hBody.animateTo(
        target,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    }
  }
}

// ===== Modelo interno de filas =====
enum _RowType { project, part, operation }

class _Row {
  final _RowType type;
  final String? project, part, label;
  final DateTime? planStart, planEnd, realStart, realEnd;

  _Row.project(this.project)
    : type = _RowType.project,
      part = null,
      label = null,
      planStart = null,
      planEnd = null,
      realStart = null,
      realEnd = null;

  _Row.part(this.project, this.part)
    : type = _RowType.part,
      label = null,
      planStart = null,
      planEnd = null,
      realStart = null,
      realEnd = null;

  _Row.operation({
    required this.project,
    required this.part,
    required this.label,
    this.planStart,
    this.planEnd,
    this.realStart,
    this.realEnd,
  }) : type = _RowType.operation;
}
