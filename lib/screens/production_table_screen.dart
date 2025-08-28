import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'dart:async'; // <-- para Timer y debounce

class FilterableProductionList extends StatefulWidget {
  const FilterableProductionList({super.key});
  @override
  State<FilterableProductionList> createState() =>
      _FilterableProductionListState();
}

class _FilterableProductionListState extends State<FilterableProductionList> {
  // ---- Filtros
  String _proyecto = '';
  String _statusLabel = '';
  DateTimeRange? _rango;
  String _parteSearch = '';

  // Catálogos cacheados (no parpadean)
  late final Future<List<List<String>>> _catalogsFuture;

  // ---- Control de stream y cache para evitar “flash”
  late Query<Map<String, dynamic>> _query; // query actual
  List<QueryDocumentSnapshot<Map<String, dynamic>>>? _lastDocs; // cache UI
  Timer? _searchDebounce; // para el TextField

  @override
  void initState() {
    super.initState();
    _catalogsFuture = Future.wait([_loadProyectos(), _loadStatusLabels()]);
    _query = _buildQuery(); // inicial
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  // ===== Helpers =====
  T _as<T>(dynamic v, T fb) {
    if (v == null) return fb;
    if (T == int) {
      if (v is int) return v as T;
      if (v is num) return v.toInt() as T;
      if (v is String) return (int.tryParse(v.trim()) ?? fb) as T;
      return fb;
    }
    if (T == double) {
      if (v is double) return v as T;
      if (v is num) return v.toDouble() as T;
      if (v is String) {
        final d = double.tryParse(v.trim().replaceAll(',', '.'));
        return (d ?? fb) as T;
      }
      return fb;
    }
    if (T == bool) {
      if (v is bool) return v as T;
      if (v is num) return (v != 0) as T;
      if (v is String) {
        final s = v.toLowerCase().trim();
        if (s == 'true' || s == '1' || s == 'sí' || s == 'si') return true as T;
        if (s == 'false' || s == '0' || s == 'no') return false as T;
      }
      return fb;
    }
    if (T == String) return v.toString() as T;
    if (v is T) return v;
    return fb;
  }

  String _fmtDate(Timestamp? ts) =>
      ts == null ? '-' : DateFormat('dd/MM/yyyy hh:mm a').format(ts.toDate());
  String _fmtDateShort(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  int _weekFrom(Timestamp? ts) {
    if (ts == null) return 0;
    final s = DateFormat('w').format(ts.toDate());
    return int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  double _yieldPct(int pass, int fail, int scrap) {
    final t = pass + fail + scrap;
    return t == 0 ? 0 : pass / t;
  }

  Color _yieldColor(double y) {
    if (y < 0.70) return Colors.red;
    if (y < 0.90) return Colors.amber[700]!;
    return Colors.green[600]!;
  }

  Color _statusColorByName(String s, BuildContext ctx) {
    final c = Theme.of(ctx).colorScheme;
    final n = s.toLowerCase();
    if (n.contains('hecho') || n.contains('finaliz')) {
      return Colors.green.withOpacity(.25);
    }
    if (n.contains('proceso')) return Colors.amber.withOpacity(.25);
    if (n.contains('paus')) return Colors.orange.withOpacity(.25);
    if (n.contains('program')) return c.primary.withOpacity(.15);
    return c.surfaceContainerHighest;
  }

  Color _statusTextColorByName(String s) {
    final n = s.toLowerCase();
    if (n.contains('hecho') || n.contains('finaliz')) {
      return Colors.green.shade900;
    }
    if (n.contains('proceso')) return Colors.orange.shade900;
    if (n.contains('paus')) return Colors.deepOrange.shade700;
    if (n.contains('program')) return Colors.blue.shade800;
    return Colors.black87;
  }

  String? _norm(String s) => s.trim().isEmpty ? null : s.trim();

  // ========== Catálogos ==========
  Future<List<String>> _loadProyectos() async {
    final set = <String>{};
    final qs = await FirebaseFirestore.instance.collection('projects').get();
    for (final d in qs.docs) {
      final p = d.data()['proyecto']?.toString().trim();
      if (p != null && p.isNotEmpty) set.add(p);
    }
    if (set.isEmpty) {
      final qs2 = await FirebaseFirestore.instance
          .collection('production_daily')
          .orderBy('fecha', descending: true)
          .limit(200)
          .get();
      for (final d in qs2.docs) {
        final p = d.data()['proyecto']?.toString().trim();
        if (p != null && p.isNotEmpty) set.add(p);
      }
    }
    final list = set.toList()..sort();
    return list;
  }

  Future<List<String>> _loadStatusLabels() async {
    final res = await FirebaseFirestore.instance
        .collection('status')
        .orderBy('order')
        .get();
    final out = <String>[];
    for (final d in res.docs) {
      final nombre = d.data()['nombre']?.toString().trim();
      if (nombre != null && nombre.isNotEmpty) out.add(nombre);
    }
    return out;
  }

  // ========== Query & actualización ==========
  Query<Map<String, dynamic>> _buildQuery() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'production_daily',
    );

    if (_rango != null) {
      final start = Timestamp.fromDate(
        DateTime(_rango!.start.year, _rango!.start.month, _rango!.start.day),
      );
      final end = Timestamp.fromDate(
        DateTime(
          _rango!.end.year,
          _rango!.end.month,
          _rango!.end.day,
          23,
          59,
          59,
          999,
        ),
      );
      q = q
          .where('fecha', isGreaterThanOrEqualTo: start)
          .where('fecha', isLessThanOrEqualTo: end);
    }

    final proyectoDb = _norm(_proyecto);
    if (proyectoDb != null) q = q.where('proyecto', isEqualTo: proyectoDb);

    final statusDb = _norm(_statusLabel);
    if (statusDb != null) q = q.where('status', isEqualTo: statusDb);

    return q.orderBy('fecha', descending: false).limit(200);
  }

  void _applyFilters(void Function() change) {
    setState(() {
      change();
      _query = _buildQuery(); // actualiza SIN perder la data en pantalla
      // no tocamos _lastDocs aquí; se actualiza cuando llegue la nueva tanda
    });
  }

  // ===================== UI =====================
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<List<String>>>(
      future: _catalogsFuture,
      builder: (ctx, catSnap) {
        final proyectos = (catSnap.data?[0] ?? const <String>[]);
        final statuses = (catSnap.data?[1] ?? const <String>[]);

        return Column(
          children: [
            // ---------- Filtros ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 220,
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: _proyecto,
                      decoration: const InputDecoration(
                        labelText: 'Proyecto',
                        border: OutlineInputBorder(),
                      ),
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem(value: '', child: Text('Todos')),
                        ...proyectos.map(
                          (p) => DropdownMenuItem(value: p, child: Text(p)),
                        ),
                      ],
                      onChanged: (v) =>
                          _applyFilters(() => _proyecto = v ?? ''),
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: _statusLabel,
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        border: OutlineInputBorder(),
                      ),
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem(value: '', child: Text('Todos')),
                        ...statuses.map(
                          (s) => DropdownMenuItem(value: s, child: Text(s)),
                        ),
                      ],
                      onChanged: (v) =>
                          _applyFilters(() => _statusLabel = v ?? ''),
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      _rango == null
                          ? 'Rango de fechas'
                          : '${_fmtDateShort(_rango!.start)} → ${_fmtDateShort(_rango!.end)}',
                    ),
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(now.year - 2),
                        lastDate: DateTime(now.year + 2),
                        initialDateRange:
                            _rango ??
                            DateTimeRange(
                              start: DateTime(now.year, now.month, 1),
                              end: now,
                            ),
                      );
                      if (picked != null) _applyFilters(() => _rango = picked);
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.filter_alt_off),
                    label: const Text('Limpiar'),
                    onPressed: () => _applyFilters(() {
                      _proyecto = '';
                      _statusLabel = '';
                      _rango = null;
                      _parteSearch = '';
                    }),
                  ),
                  SizedBox(
                    width: 220,
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: 'Buscar Nº de parte',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) {
                        _searchDebounce?.cancel();
                        _searchDebounce = Timer(
                          const Duration(milliseconds: 250),
                          () {
                            setState(
                              () => _parteSearch = v.trim().toLowerCase(),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // ---------- Lista ----------
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _query.snapshots(),
                builder: (context, snap) {
                  // Si llega data nueva, actualizamos cache
                  if (snap.hasData) _lastDocs = snap.data!.docs;

                  // Mientras llega la nueva (waiting), seguimos mostrando la anterior
                  final docs = (() {
                    if (_parteSearch.isEmpty) {
                      if (snap.hasData) return snap.data!.docs;
                      if (snap.connectionState == ConnectionState.waiting &&
                          _lastDocs != null) {
                        return _lastDocs!;
                      }
                    }
                    // Con búsqueda local, aplicamos sobre la fuente que tengamos
                    final base = snap.hasData
                        ? snap.data!.docs
                        : (_lastDocs ??
                              const <
                                QueryDocumentSnapshot<Map<String, dynamic>>
                              >[]);
                    if (_parteSearch.isEmpty) return base;
                    return base.where((e) {
                      final parte =
                          e.data()['numeroParte']?.toString().toLowerCase() ??
                          '';
                      return parte.contains(_parteSearch);
                    }).toList();
                  })();

                  if (snap.hasError &&
                      (_lastDocs == null || _lastDocs!.isEmpty)) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Text(
                          'Error: ${snap.error}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }

                  if (docs.isEmpty) {
                    // si no hay docs ni en cache ni en stream
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24.0),
                        child: Text(
                          'Sin resultados con los filtros aplicados.',
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    cacheExtent: 1000,
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final d = docs[i].data();

                      final fecha = d['fecha'] as Timestamp?;
                      final semana = _as<int>(d['semana'], _weekFrom(fecha));
                      final proyecto = _as<String>(d['proyecto'], '—');
                      final desc = _as<String>(d['descripcionProyecto'], '');
                      final parte = _as<String>(d['numeroParte'], '—');
                      final operacion = _as<String>(d['operacionNombre'], '');
                      final operador = _as<String>(d['operadorNombre'], '');
                      final maquina = _as<String>(d['maquinaNombre'], '');
                      final bodega = _as<String>(d['bodega'], '');
                      final compromiso = d['fechaCompromiso'] as Timestamp?;
                      final inicio = d['inicio'] as Timestamp?;
                      final fin = d['fin'] as Timestamp?;
                      final statusName = _as<String>(d['status'], '');

                      final cantidad = _as<int>(d['cantidad'], 0);
                      final pass = _as<int>(d['pass'], 0);
                      final fail = _as<int>(d['fail'], 0);
                      final scrap = _as<int>(d['scrap'], 0);
                      final y = _yieldPct(
                        pass,
                        fail,
                        scrap,
                      ).clamp(0, 1).toDouble();

                      return Card(
                        elevation: .5,
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ExpansionTile(
                          tilePadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          childrenPadding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            12,
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  proyecto,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _fmtDate(fecha),
                                style: const TextStyle(color: Colors.black54),
                              ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (desc.isNotEmpty)
                                Text(
                                  desc,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              const SizedBox(height: 2),
                              Text(
                                [
                                      parte,
                                      operacion,
                                      operador,
                                      if (maquina.isNotEmpty)
                                        '$maquina ($bodega)',
                                    ]
                                    .where(
                                      (e) => e.toString().trim().isNotEmpty,
                                    )
                                    .join(' • '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.black54),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  Chip(
                                    label: Text('S$semana'),
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withOpacity(.6),
                                  ),
                                  Chip(
                                    label: Text(
                                      statusName.isEmpty ? '—' : statusName,
                                    ),
                                    labelStyle: TextStyle(
                                      color: _statusTextColorByName(statusName),
                                      fontWeight: FontWeight.w600,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: _statusColorByName(
                                      statusName,
                                      context,
                                    ),
                                  ),
                                  if (compromiso != null)
                                    Chip(
                                      label: Text(
                                        'Comp: ${_fmtDate(compromiso)}',
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest
                                          .withOpacity(.6),
                                    ),
                                ],
                              ),
                            ],
                          ),
                          children: [
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                _miniStat('Cant.', '$cantidad'),
                                _miniStat('Pass', '$pass'),
                                _miniStat('Fail', '$fail'),
                                _miniStat('Scrap', '$scrap'),
                                Chip(
                                  label: Text(
                                    'Yield ${(y * 100).toStringAsFixed(1)}%',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  backgroundColor: _yieldColor(y),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            LinearProgressIndicator(
                              value: y,
                              minHeight: 8,
                              backgroundColor: Colors.grey.shade200,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                _yieldColor(y),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 16,
                              runSpacing: 4,
                              children: [
                                if (inicio != null)
                                  Text(
                                    'Inicio: ${_fmtDate(inicio)}',
                                    style: const TextStyle(
                                      color: Colors.black54,
                                    ),
                                  ),
                                if (fin != null)
                                  Text(
                                    'Fin: ${_fmtDate(fin)}',
                                    style: const TextStyle(
                                      color: Colors.black54,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // Mini tarjeta métrica
  Widget _miniStat(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey.shade100,
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ', style: const TextStyle(color: Colors.black54)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
