// lib/screens/production_table_screen.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class FilterableProductionList extends StatefulWidget {
  const FilterableProductionList({super.key});
  @override
  State<FilterableProductionList> createState() =>
      _FilterableProductionListState();
}

class _FilterableProductionListState extends State<FilterableProductionList> {
  // Filtros (cliente)
  String _proyecto = '';
  String _statusLabel = '';
  DateTimeRange? _rango;
  String _parteSearch = '';
  bool _onlyMine = false;

  // Identidad
  String? _uid;
  String? _displayName;
  String? _email;

  // Catálogos: proyectos, status, operaciones (orden)
  late final Future<List<List<String>>> _catalogsFuture;
  late final Future<Map<String, int>> _opsOrderFuture;

  // Stream + cache
  late Query<Map<String, dynamic>> _query;
  List<QueryDocumentSnapshot<Map<String, dynamic>>>? _lastDocs;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    _uid = user?.uid;
    _displayName = user?.displayName?.trim();
    _email = user?.email?.trim();

    _catalogsFuture = Future.wait([_loadProyectos(), _loadStatusLabels()]);
    _opsOrderFuture = _loadOpsOrder(); // orden de operations
    _query = _buildQuery();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  // ---------------- helpers ----------------
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
    if (T == String) return v.toString() as T;
    return v is T ? v : fb;
  }

  String? _norm(String s) => s.trim().isEmpty ? null : s.trim();

  String _fmtDate(Timestamp? ts) =>
      ts == null ? '-' : DateFormat('dd/MM/yyyy hh:mm a').format(ts.toDate());
  String _fmtCommit(Timestamp? ts) =>
      ts == null ? '-' : DateFormat('dd/MM/yyyy hh:mm a').format(ts.toDate());
  String _fmtDateShort(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  int _weekFrom(Timestamp? ts) {
    if (ts == null) return 0;
    final s = DateFormat('w').format(ts.toDate());
    return int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  Color _statusBg(String s, BuildContext ctx) {
    final c = Theme.of(ctx).colorScheme;
    final n = s.toLowerCase();
    if (n.contains('hecho') || n.contains('final')) {
      return Colors.green.withOpacity(.2);
    }
    if (n.contains('proceso')) return Colors.amber.withOpacity(.25);
    if (n.contains('paus')) return Colors.orange.withOpacity(.25);
    if (n.contains('program')) return c.primary.withOpacity(.15);
    return c.surfaceContainerHighest;
  }

  Color _statusFg(String s) {
    final n = s.toLowerCase();
    if (n.contains('hecho') || n.contains('final')) {
      return Colors.green.shade900;
    }
    if (n.contains('proceso')) return Colors.orange.shade900;
    if (n.contains('paus')) return Colors.deepOrange.shade700;
    if (n.contains('program')) return Colors.blue.shade800;
    return Colors.black87;
  }

  Color _yieldColor(double y) {
    if (y < 0.70) return Colors.red;
    if (y < 0.90) return Colors.amber[700]!;
    return Colors.green[600]!;
  }

  bool _isMine(Map<String, dynamic> m) {
    if (!_onlyMine) return true;
    final ouid = (m['operadorUid'] ?? '').toString().trim();
    final oname = (m['operadorNombre'] ?? '').toString().trim();
    if (_uid != null && _uid!.isNotEmpty && ouid.isNotEmpty) {
      return ouid == _uid;
    }
    // Fallback por nombre o email
    if (_displayName != null && _displayName!.isNotEmpty && oname.isNotEmpty) {
      if (oname.toLowerCase() == _displayName!.toLowerCase()) return true;
    }
    if (_email != null && _email!.isNotEmpty && oname.isNotEmpty) {
      final emailUser = _email!.split('@').first.toLowerCase();
      if (oname.toLowerCase().contains(emailUser)) return true;
    }
    return false;
  }

  // ---------------- catálogos ----------------
  Future<List<String>> _loadProyectos() async {
    final set = <String>{};
    final qs = await FirebaseFirestore.instance
        .collection('projects')
        .where('activo', isEqualTo: true)
        .get();
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

  Future<Map<String, int>> _loadOpsOrder() async {
    final map = <String, int>{};
    final res = await FirebaseFirestore.instance
        .collection('operations')
        .orderBy('order')
        .get();
    for (final d in res.docs) {
      final nombre = (d.data()['nombre'] ?? '').toString().trim();
      final order = _as<int>(d.data()['order'], 9999);
      if (nombre.isNotEmpty) map[nombre] = order;
    }
    return map;
  }

  // ---------------- query base (por fecha) ----------------
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
    return q.orderBy('fecha', descending: false).limit(1000);
  }

  void _applyFilters(void Function() change) {
    setState(() {
      change();
      _query = _buildQuery();
    });
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      // combino catálogos + orden de operaciones
      future: Future.wait([_catalogsFuture, _opsOrderFuture]),
      builder: (ctx, comboSnap) {
        if (!comboSnap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final proyectos = (comboSnap.data![0] as List<List<String>>)[0];
        final statuses = (comboSnap.data![0] as List<List<String>>)[1];
        final opsOrder = comboSnap.data![1] as Map<String, int>;

        return Column(
          children: [
            // Filtros
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
                      items: [
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
                      items: [
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
                  FilterChip(
                    selected: _onlyMine,
                    label: const Text('Sólo mis actividades'),
                    onSelected: (v) => _applyFilters(() => _onlyMine = v),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.filter_alt_off),
                    label: const Text('Limpiar'),
                    onPressed: () => _applyFilters(() {
                      _proyecto = '';
                      _statusLabel = '';
                      _rango = null;
                      _parteSearch = '';
                      _onlyMine = false;
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
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.account_tree_outlined),
                    label: const Text(
                      'Ver análisis Proyecto → P/N → Operación',
                    ),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ProjectTreeScreen(
                            proyecto: _proyecto,
                            statusLabel: _statusLabel,
                            rango: _rango,
                            parteSearch: _parteSearch,
                            onlyMine: _onlyMine,
                            uid: _uid,
                            displayName: _displayName,
                            email: _email,
                            opsOrder: opsOrder,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Lista compacta estilo "foto"
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _query.snapshots(),
                builder: (context, snap) {
                  if (snap.hasData) _lastDocs = snap.data!.docs;

                  final base = snap.hasData
                      ? snap.data!.docs
                      : (_lastDocs ??
                            const <
                              QueryDocumentSnapshot<Map<String, dynamic>>
                            >[]);

                  // Filtrado en cliente
                  final proyectoDb = _norm(_proyecto);
                  final statusDb = _norm(_statusLabel);

                  var filtered = base.where((e) {
                    final m = e.data();
                    final p = (m['proyecto'] ?? '').toString().trim();
                    final s = (m['status'] ?? '').toString().trim();
                    final okP = proyectoDb == null || p == proyectoDb;
                    final okS = statusDb == null || s == statusDb;
                    final okMine = _isMine(m);
                    return okP && okS && okMine;
                  }).toList();

                  if (_parteSearch.isNotEmpty) {
                    filtered = filtered.where((e) {
                      final pn =
                          e
                              .data()['numeroParte']
                              ?.toString()
                              .toLowerCase()
                              .trim() ??
                          '';
                      return pn.contains(_parteSearch);
                    }).toList();
                  }

                  if (snap.hasError && filtered.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Text('Error: ${snap.error}'),
                      ),
                    );
                  }
                  if (filtered.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24.0),
                        child: Text('Sin resultados con los filtros actuales.'),
                      ),
                    );
                  }

                  return ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) =>
                        _activityCard(filtered[i].data(), opsOrder),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // --------- Tarjeta compacta por actividad ---------
  Widget _activityCard(Map<String, dynamic> d, Map<String, int> opsOrder) {
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
    final statusName = _as<String>(d['status'], '');

    final cantidad = _as<int>(d['cantidad'], 0);
    final pass = _as<int>(d['pass'], 0);
    final fail = _as<int>(d['fail'], 0);
    final scrap = _as<int>(d['scrap'], 0);
    final y = () {
      final t = pass + fail + scrap;
      return t == 0 ? 0.0 : (pass / t).clamp(0, 1).toDouble();
    }();

    return Card(
      elevation: .5,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: proyecto + fecha
            Row(
              children: [
                Expanded(
                  child: Text(
                    proyecto,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
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
            if (desc.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(desc, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 2),
            Text(
              [
                parte,
                operacion,
                operador,
                if (maquina.isNotEmpty) '$maquina ($bodega)',
              ].where((e) => e.toString().trim().isNotEmpty).join(' • '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                Chip(
                  label: Text('S$semana'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withOpacity(.6),
                ),
                Chip(
                  label: Text(statusName.isEmpty ? '—' : statusName),
                  labelStyle: TextStyle(
                    color: _statusFg(statusName),
                    fontWeight: FontWeight.w600,
                  ),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: _statusBg(statusName, context),
                ),
                if (compromiso != null)
                  Chip(
                    label: Text('Comp: ${_fmtCommit(compromiso)}'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest.withOpacity(.6),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // mini métricas + yield pequeño
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _mini('Cant.', '$cantidad'),
                _mini('Pass', '$pass'),
                _mini('Fail', '$fail'),
                _mini('Scrap', '$scrap'),
                Chip(
                  label: Text('Yield ${(y * 100).toStringAsFixed(1)}%'),
                  visualDensity: VisualDensity.compact,
                  labelStyle: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                  backgroundColor: _yieldColor(y),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('Ver análisis'),
                onPressed: () async {
                  final opsOrderMap = await _opsOrderFuture;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ProjectTreeScreen(
                        proyecto: proyecto,
                        statusLabel: '', // libre al abrir desde tarjeta
                        rango: _rango,
                        parteSearch: parte, // centramos en ese P/N
                        onlyMine: _onlyMine,
                        uid: _uid,
                        displayName: _displayName,
                        email: _email,
                        opsOrder: opsOrderMap,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mini(String label, String value) => Container(
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

//////////////////////////////////////////////
///   PANTALLA DE ANÁLISIS (ÁRBOL DETALLADO)
//////////////////////////////////////////////
class ProjectTreeScreen extends StatelessWidget {
  final String proyecto;
  final String statusLabel;
  final DateTimeRange? rango;
  final String parteSearch;

  final bool onlyMine;
  final String? uid;
  final String? displayName;
  final String? email;

  final Map<String, int> opsOrder; // orden operations

  const ProjectTreeScreen({
    super.key,
    required this.proyecto,
    required this.statusLabel,
    required this.rango,
    required this.parteSearch,
    required this.onlyMine,
    required this.uid,
    required this.displayName,
    required this.email,
    required this.opsOrder,
  });

  // Helpers locales
  T _as<T>(dynamic v, T fb) {
    if (v == null) return fb;
    if (T == int) {
      if (v is int) return v as T;
      if (v is num) return v.toInt() as T;
      if (v is String) return (int.tryParse(v.trim()) ?? fb) as T;
      return fb;
    }
    if (T == String) return v.toString() as T;
    return v is T ? v : fb;
  }

  String? _norm(String s) => s.trim().isEmpty ? null : s.trim();
  String _fmtDate(Timestamp? ts) =>
      ts == null ? '-' : DateFormat('dd/MM/yyyy hh:mm a').format(ts.toDate());
  int _weekFrom(Timestamp? ts) {
    if (ts == null) return 0;
    final s = DateFormat('w').format(ts.toDate());
    return int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }

  Color _statusBg(String s, BuildContext ctx) {
    final c = Theme.of(ctx).colorScheme;
    final n = s.toLowerCase();
    if (n.contains('hecho') || n.contains('final')) {
      return Colors.green.withOpacity(.2);
    }
    if (n.contains('proceso')) return Colors.amber.withOpacity(.25);
    if (n.contains('paus')) return Colors.orange.withOpacity(.25);
    if (n.contains('program')) return c.primary.withOpacity(.15);
    return c.surfaceContainerHighest;
  }

  Color _statusFg(String s) {
    final n = s.toLowerCase();
    if (n.contains('hecho') || n.contains('final')) {
      return Colors.green.shade900;
    }
    if (n.contains('proceso')) return Colors.orange.shade900;
    if (n.contains('paus')) return Colors.deepOrange.shade700;
    if (n.contains('program')) return Colors.blue.shade800;
    return Colors.black87;
  }

  bool _isMine(Map<String, dynamic> m) {
    if (!onlyMine) return true;
    final ouid = (m['operadorUid'] ?? '').toString().trim();
    final oname = (m['operadorNombre'] ?? '').toString().trim();
    if (uid != null && uid!.isNotEmpty && ouid.isNotEmpty) {
      return ouid == uid;
    }
    if (displayName != null && displayName!.isNotEmpty && oname.isNotEmpty) {
      if (oname.toLowerCase() == displayName!.toLowerCase()) return true;
    }
    if (email != null && email!.isNotEmpty && oname.isNotEmpty) {
      final emailUser = email!.split('@').first.toLowerCase();
      if (oname.toLowerCase().contains(emailUser)) return true;
    }
    return false;
  }

  Query<Map<String, dynamic>> _buildQuery() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'production_daily',
    );
    if (rango != null) {
      final start = Timestamp.fromDate(
        DateTime(rango!.start.year, rango!.start.month, rango!.start.day),
      );
      final end = Timestamp.fromDate(
        DateTime(
          rango!.end.year,
          rango!.end.month,
          rango!.end.day,
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
    return q.orderBy('fecha', descending: false).limit(1000);
  }

  // ÍCONO por operación
  IconData _iconForOperation(String name) {
    final n = name.trim().toUpperCase();

    if (n.contains('DIBUJO')) return Icons.edit_note;
    if (n.contains('STOCK') || n.contains('ALMACEN') || n.contains('ALMACÉN')) {
      return Icons.inventory_2_outlined;
    }
    if (n.contains('CORTE') || n.contains('CUT')) return Icons.content_cut;
    if (n.contains('DOBLEZ') || n.contains('DOBLA') || n.contains('BEND')) {
      return Icons.straighten;
    }
    if (n.contains('SOLD') || n.contains('SOLDAD') || n.contains('WELD')) {
      return Icons.construction;
    }
    if (n.contains('MAQUINA') || n.contains('MÁQUINA') || n.contains('CNC')) {
      return Icons.precision_manufacturing_outlined;
    }
    if (n.contains('PINT') || n.contains('PAINT'))
      return Icons.format_color_fill;
    if (n.contains('REVISION') ||
        n.contains('REVISIÓN') ||
        n.contains('CALIDAD') ||
        n.contains('QUALITY')) {
      return Icons.verified_outlined;
    }
    if (n.contains('ENSAM') || n.contains('ARMADO'))
      return Icons.build_outlined;

    return Icons.handyman_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final proyectoDb = _norm(proyecto);
    final statusDb = _norm(statusLabel);
    final parteDb = parteSearch.trim().toLowerCase();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Análisis por Proyecto • P/N • Operación'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _buildQuery().snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          var docs = snap.data!.docs;

          // filtro en cliente
          docs = docs.where((e) {
            final m = e.data();
            final p = (m['proyecto'] ?? '').toString().trim();
            final s = (m['status'] ?? '').toString().trim();
            final pn = (m['numeroParte'] ?? '').toString().toLowerCase().trim();
            final okP = proyectoDb == null || p == proyectoDb;
            final okS = statusDb == null || s == statusDb;
            final okPN = parteDb.isEmpty || pn.contains(parteDb);
            final okMine = _isMine(m);
            return okP && okS && okPN && okMine;
          }).toList();

          if (docs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Sin resultados bajo los filtros actuales.'),
              ),
            );
          }

          // Construcción jerárquica (respetando orden de operations)
          final projects = <String, ProjectAgg>{};
          for (final doc in docs) {
            final d = doc.data();
            final pr = _as<String>(d['proyecto'], '—');
            final parte = _as<String>(d['numeroParte'], '—');
            final operacion = _as<String>(d['operacionNombre'], '');
            final descripcion = _as<String>(d['descripcionProyecto'], '');
            final operador = _as<String>(d['operadorNombre'], '');
            final status = _as<String>(d['status'], '');
            final ts = d['fecha'] as Timestamp?;

            final cantidad = _as<int>(d['cantidad'], 0);
            final pass = _as<int>(d['pass'], 0);
            final fail = _as<int>(d['fail'], 0);
            final scrap = _as<int>(d['scrap'], 0);

            final p = projects.putIfAbsent(pr, () => ProjectAgg(proyecto: pr));
            final part = p.parts.putIfAbsent(
              parte,
              () =>
                  PartAgg(proyecto: pr, parte: parte, descripcion: descripcion),
            );
            final op = part.ops.putIfAbsent(
              operacion,
              () => OpAgg(operacion: operacion),
            );

            p.cantidad += cantidad;
            part.cantidad += cantidad;
            op.cantidad += cantidad;

            p.pass += pass;
            part.pass += pass;
            op.pass += pass;

            p.fail += fail;
            part.fail += fail;
            op.fail += fail;

            p.scrap += scrap;
            part.scrap += scrap;
            op.scrap += scrap;

            op.docs.add(doc);
            if (operador.isNotEmpty) op.operadores.add(operador);

            if (op.lastTs == null ||
                (ts != null && ts.toDate().isAfter(op.lastTs!.toDate()))) {
              op.lastTs = ts;
              op.status = status;
            }
            if (part.lastTs == null ||
                (ts != null && ts.toDate().isAfter(part.lastTs!.toDate()))) {
              part.lastTs = ts;
              part.status = status;
            }
          }

          final projItems = projects.values.toList()
            ..sort((a, b) => a.proyecto.compareTo(b.proyecto));

          return ListView.separated(
            itemCount: projItems.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            itemBuilder: (_, i) =>
                _projectTile(context, projItems[i], opsOrder),
          );
        },
      ),
    );
  }

  Widget _projectTile(
    BuildContext context,
    ProjectAgg p,
    Map<String, int> opsOrder,
  ) {
    final partsList = p.parts.values.toList()
      ..sort((a, b) => a.parte.compareTo(b.parte));
    final partsCount = partsList.length;
    final opsCount = partsList.fold<int>(0, (a, b) => a + b.ops.length);

    return Card(
      elevation: .6,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        title: Text(
          p.proyecto,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        subtitle: Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _chipPlain(context, 'P/N: $partsCount'),
            _chipPlain(context, 'Ops: $opsCount'),
            _chipPlain(context, 'Cant.: ${p.cantidad}'),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        children: partsList
            .map((part) => _partTile(context, part, opsOrder))
            .toList(),
      ),
    );
  }

  Widget _partTile(
    BuildContext context,
    PartAgg part,
    Map<String, int> opsOrder,
  ) {
    // Semana confiable (evita 0)
    final semana = () {
      int w = _weekFrom(part.lastTs);
      if (w == 0) {
        for (final op in part.ops.values) {
          final ow = _weekFrom(op.lastTs);
          if (ow > 0) {
            w = ow;
            break;
          }
        }
      }
      return w;
    }();

    final opsList = part.ops.values.toList()
      ..sort((a, b) {
        final ao = opsOrder[a.operacion] ?? 9999;
        final bo = opsOrder[b.operacion] ?? 9999;
        final c = ao.compareTo(bo);
        return c != 0 ? c : a.operacion.compareTo(b.operacion);
      });

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        title: Text(
          part.parte,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (part.descripcion.trim().isNotEmpty)
              Text(
                part.descripcion,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _chipPlain(context, 'Semana: $semana'),
                _chipPlain(context, 'Operaciones: ${opsList.length}'),
                _chipPlain(context, 'Total: ${part.cantidad}'),
                if (part.status.isNotEmpty)
                  Chip(
                    label: Text(part.status),
                    labelStyle: TextStyle(
                      color: _statusFg(part.status),
                      fontWeight: FontWeight.w600,
                    ),
                    backgroundColor: _statusBg(part.status, context),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        children: opsList.map((op) => _opRow(context, op)).toList(),
      ),
    );
  }

  // ---- Operación con ícono y trailing anti-overflow
  Widget _opRow(BuildContext context, OpAgg op) {
    final operadores = op.operadores.join(', ');

    return ListTile(
      dense: true,
      minLeadingWidth: 28,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(_iconForOperation(op.operacion), size: 20),
      title: Text(
        op.operacion.isEmpty ? '—' : op.operacion,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (operadores.isNotEmpty)
            Text(
              'Operador: $operadores',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          Row(
            children: [
              if (op.status.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(right: 8, top: 4),
                  child: Chip(
                    label: Text(op.status),
                    labelStyle: TextStyle(
                      color: _statusFg(op.status),
                      fontWeight: FontWeight.w600,
                    ),
                    backgroundColor: _statusBg(op.status, context),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              Flexible(
                child: Text(
                  _fmtDate(op.lastTs),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.black54),
                ),
              ),
            ],
          ),
        ],
      ),
      // Evita overflow horizontal
      trailing: SizedBox(
        width: 140,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Cant.: ${op.cantidad}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Pass: ${op.pass} · Fail: ${op.fail} · Scrap: ${op.scrap}',
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 12,
                  height: 1.1,
                ),
                softWrap: false,
                overflow: TextOverflow.fade,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chipPlain(BuildContext context, String text) => Chip(
    label: Text(text),
    visualDensity: VisualDensity.compact,
    backgroundColor: Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest.withOpacity(.6),
  );
}

// ---------------- modelos de agregación ----------------
class ProjectAgg {
  final String proyecto;
  final Map<String, PartAgg> parts = {};
  int cantidad = 0, pass = 0, fail = 0, scrap = 0;
  ProjectAgg({required this.proyecto});
}

class PartAgg {
  final String proyecto;
  final String parte;
  final String descripcion;
  final Map<String, OpAgg> ops = {};
  int cantidad = 0, pass = 0, fail = 0, scrap = 0;
  Timestamp? lastTs;
  String status = '';
  PartAgg({
    required this.proyecto,
    required this.parte,
    required this.descripcion,
  });
}

class OpAgg {
  final String operacion;
  final Set<String> operadores = <String>{};
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = [];
  int cantidad = 0, pass = 0, fail = 0, scrap = 0;
  Timestamp? lastTs;
  String status = '';
  OpAgg({required this.operacion});
}
