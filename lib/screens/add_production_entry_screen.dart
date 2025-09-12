import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class _OpMeta {
  final String id;
  final String nombre;
  final int order;
  _OpMeta({required this.id, required this.nombre, required this.order});
}

class _OpAssign {
  String? operadorUid;
  String? operadorNombre;
  int qty;
  _OpAssign({this.operadorUid, this.operadorNombre, this.qty = 0});
}

class AddProductionEntryScreen extends StatefulWidget {
  const AddProductionEntryScreen({super.key});
  @override
  State<AddProductionEntryScreen> createState() =>
      _AddProductionEntryScreenState();
}

class _AddProductionEntryScreenState extends State<AddProductionEntryScreen> {
  final _formKey = GlobalKey<FormState>();

  final _descripcionProyectoCtrl = TextEditingController();
  final _descripcionParteCtrl = TextEditingController();
  final _cantidadSugeridaCtrl = TextEditingController();

  String? _projectId, _projectName;
  String? _partId, _partNumber;

  List<_OpMeta> _ops = [];
  List<Map<String, String>> _machines = [];
  List<Map<String, String>> _operadores = [];

  final List<_OpMeta> _selectedOps = [];
  final Map<String, String?> _perOpMachineId = {};
  final Map<String, String?> _perOpMachineName = {};
  final Map<String, String?> _perOpBodegaName = {};
  final Map<String, List<_OpAssign>> _perOpAssignments = {};

  DateTime? _fecha;
  DateTime? _fechaCompromiso;
  bool _saving = false;
  bool _multiMode = true;

  int _maxQty = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _descripcionProyectoCtrl.dispose();
    _descripcionParteCtrl.dispose();
    _cantidadSugeridaCtrl.dispose();
    super.dispose();
  }

  int _isoWeekNumber(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    final thursday = d.add(Duration(days: 3 - ((d.weekday + 6) % 7)));
    final firstThursday = DateTime(thursday.year, 1, 4);
    return 1 + ((thursday.difference(firstThursday).inDays) / 7).floor();
  }

  Future<void> _bootstrap() async {
    final db = FirebaseFirestore.instance;
    final opsF = db.collection('operations').get();
    final machF = db.collection('machines').get();
    final opsUsersF = db
        .collection('users')
        .where('role', isEqualTo: 'operador')
        .orderBy('displayName')
        .get();

    final results = await Future.wait([opsF, machF, opsUsersF]);

    final opsSnap = results[0];
    _ops =
        opsSnap.docs
            .map(
              (d) => _OpMeta(
                id: d.id,
                nombre: (d['nombre'] ?? '').toString(),
                order: (d['order'] ?? 9999) is int
                    ? (d['order'] as int)
                    : int.tryParse('${d['order']}') ?? 9999,
              ),
            )
            .where((o) {
              final n = o.nombre.trim().toUpperCase();
              // Oculta operaciones no asignables manualmente
              if (n == 'DIBUJO') return false;
              if (n == 'STOCK' || n == 'ALMACEN' || n == 'ALMACÉN')
                return false;
              if (n == 'RETRABAJO') return false;
              return true;
            })
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));

    final machSnap = results[1];
    _machines = [];
    for (final m in machSnap.docs) {
      final data = m.data();
      String bodegaNombre = (data['bodega'] ?? '')?.toString() ?? '';
      final bodegaRef = data['bodegaId'];
      if (bodegaRef is DocumentReference) {
        try {
          final b = await bodegaRef.get();
          if (b.exists) {
            bodegaNombre =
                ((b.data() as Map?)?['nombre'] ?? '')?.toString() ?? '';
          }
        } catch (_) {}
      }
      _machines.add({
        'id': m.id,
        'nombre': (data['nombre'] ?? '').toString(),
        'bodega': bodegaNombre,
      });
    }

    final opUsersSnap = results[2];
    _operadores = opUsersSnap.docs
        .map(
          (d) => {'uid': d.id, 'nombre': (d['displayName'] ?? '').toString()},
        )
        .where((m) => (m['nombre'] ?? '').toString().trim().isNotEmpty)
        .toList();

    if (mounted) setState(() {});
  }

  Stream<List<Map<String, dynamic>>> _projectsStream() {
    return FirebaseFirestore.instance
        .collection('projects')
        .where('activo', isEqualTo: true)
        .orderBy('proyecto')
        .snapshots()
        .map(
          (qs) => qs.docs
              .map(
                (d) => {
                  'id': d.id,
                  'proyecto': (d['proyecto'] ?? '').toString(),
                  'descripcionProyecto': (d['descripcionProyecto'] ?? '')
                      .toString(),
                },
              )
              .toList(),
        );
  }

  Stream<List<Map<String, dynamic>>> _partsStream(String projectId) {
    return FirebaseFirestore.instance
        .collection('projects')
        .doc(projectId)
        .collection('parts')
        .where('activo', isEqualTo: true)
        .snapshots()
        .map((qs) {
          final list = qs.docs
              .map(
                (d) => {
                  'id': d.id,
                  'numeroParte': (d['numeroParte'] ?? '').toString(),
                  'descripcionParte': (d['descripcionParte'] ?? '').toString(),
                },
              )
              .toList();
          list.sort(
            (a, b) => (a['numeroParte'] as String).compareTo(
              b['numeroParte'] as String,
            ),
          );
          return list;
        });
  }

  // ====== BOM faltante (plan - producido) ======

  Future<int> _producedForPart({
    required String projectId,
    required String partId,
  }) async {
    final partRef = FirebaseFirestore.instance
        .collection('projects')
        .doc(projectId)
        .collection('parts')
        .doc(partId);

    final qs = await FirebaseFirestore.instance
        .collection('production_daily')
        .where('parteRef', isEqualTo: partRef)
        // Si quisieras solo órdenes terminadas, habilita este filtro:
        // .where('status', isEqualTo: 'hecho')
        .get();

    int sum = 0;
    for (final d in qs.docs) {
      sum += (d.data()['cantidad'] ?? 0) as int;
    }
    return sum;
  }

  Future<void> _loadSuggestedQty() async {
    if (_projectId == null || _partId == null) return;

    // Lee cantidadPlan (BOM)
    final partSnap = await FirebaseFirestore.instance
        .collection('projects')
        .doc(_projectId)
        .collection('parts')
        .doc(_partId)
        .get();

    final partMap = partSnap.data();
    final plan =
        ((partMap == null ? 0 : (partMap['cantidadPlan'] ?? 0)) as int);

    // Suma producido del P/N
    final produced = await _producedForPart(
      projectId: _projectId!,
      partId: _partId!,
    );

    final faltante = max(0, plan - produced);

    if (!mounted) return;
    setState(() {
      _cantidadSugeridaCtrl.text = faltante.toString();
      _maxQty = faltante;
    });
  }

  // ====== Guardado ======
  Future<void> _submit() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;

    if (_projectId == null || _partId == null) {
      _snack('Selecciona proyecto y número de parte');
      return;
    }
    if (_fecha == null || _fechaCompromiso == null) {
      _snack('Selecciona fecha de actividad y fecha compromiso');
      return;
    }
    if (_selectedOps.isEmpty) {
      _snack('Selecciona al menos una operación');
      return;
    }
    for (final op in _selectedOps) {
      final mid = _perOpMachineId[op.id];
      if (mid == null) {
        _snack('La operación "[${op.order}] ${op.nombre}" requiere máquina.');
        return;
      }
      final assigns = _perOpAssignments[op.id] ?? [];
      final anyValid = assigns.any(
        (a) => (a.operadorUid != null) && (a.qty > 0),
      );
      if (!anyValid) {
        _snack(
          'La operación "[${op.order}] ${op.nombre}" requiere al menos una asignación válida.',
        );
        return;
      }

      final totalQty = assigns.fold<int>(0, (p, a) => p + a.qty);
      if (totalQty > _maxQty) {
        _snack(
          'La cantidad para "[${op.order}] ${op.nombre}" excede el máximo ($_maxQty).',
        );
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final db = FirebaseFirestore.instance;

      final d = _fecha!;
      final anio = d.year;
      final mes = d.month;
      final semana = _isoWeekNumber(d);
      final anioSemana = anio * 100 + semana;
      final anioMes = anio * 100 + mes;

      final proyectoRef = db.collection('projects').doc(_projectId);
      final parteRef = proyectoRef.collection('parts').doc(_partId);

      for (final op in _selectedOps) {
        final operacionRef = db.collection('operations').doc(op.id);

        final mid = _perOpMachineId[op.id]!;
        final mname = _perOpMachineName[op.id] ?? '';
        final bname = _perOpBodegaName[op.id] ?? '';
        final maquinaRef = db.collection('machines').doc(mid);

        final assigns = _perOpAssignments[op.id] ?? [];
        for (final a in assigns) {
          if (a.operadorUid == null || a.qty <= 0) continue;

          final operadorRef = db.collection('users').doc(a.operadorUid);
          final operadorNombre = a.operadorNombre ?? '';

          await db.collection('production_daily').add({
            'proyectoRef': proyectoRef,
            'parteRef': parteRef,
            'operacionRef': operacionRef,
            'maquinaRef': maquinaRef,
            'operadorRef': operadorRef,

            'operadorUid': a.operadorUid,

            'proyecto': _projectName,
            'descripcionProyecto': _descripcionProyectoCtrl.text.trim(),
            'numeroParte': _partNumber,
            'descripcionParte': _descripcionParteCtrl.text.trim(),
            'operacion': op.nombre,
            'operacionNombre': op.nombre,
            'opSecuencia': op.order,
            'maquinaNombre': mname,
            'bodega': bname,
            'operadorNombre': operadorNombre,

            'fecha': Timestamp.fromDate(d),
            'fechaCompromiso': Timestamp.fromDate(_fechaCompromiso!),
            'anio': anio,
            'mes': mes,
            'semana': semana,
            'anioSemana': anioSemana,
            'anioMes': anioMes,

            'cantidad': a.qty,

            'status': 'programado',
            'inicio': null,
            'fin': null,
            'pass': 0,
            'fail': 0,
            'scrap': 0,
            'yield': 0.0,
            'scrapPendiente': false,
            'scrapAprobado': false,

            'createdAt': FieldValue.serverTimestamp(),
          });
        }
      }

      if (!mounted) return;
      _snack('Actividad(es) guardada(s)');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) _snack('Error al guardar: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alta de Producción')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _projectsStream(),
        builder: (context, proSnap) {
          final projects = proSnap.data ?? const [];
          return AbsorbPointer(
            absorbing: _saving,
            child: Opacity(
              opacity: _saving ? 0.6 : 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    children: [
                      const Text(
                        'Datos generales',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Proyecto
                      DropdownButtonFormField<String>(
                        value: _projectId,
                        decoration: const InputDecoration(
                          labelText: 'Proyecto',
                          border: OutlineInputBorder(),
                        ),
                        items: projects
                            .map(
                              (p) => DropdownMenuItem<String>(
                                value: p['id'] as String,
                                child: Text(
                                  p['proyecto'] as String,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          final sel = projects.firstWhere((p) => p['id'] == v);
                          setState(() {
                            _projectId = sel['id'] as String;
                            _projectName = sel['proyecto'] as String;
                            _descripcionProyectoCtrl.text =
                                (sel['descripcionProyecto'] as String?) ?? '';
                            _partId = null;
                            _partNumber = null;
                            _descripcionParteCtrl.clear();
                            _cantidadSugeridaCtrl.clear();
                          });
                        },
                        validator: (v) =>
                            v == null ? 'Selecciona un proyecto' : null,
                      ),

                      // Nº de parte
                      const SizedBox(height: 12),
                      StreamBuilder<List<Map<String, dynamic>>>(
                        stream: _projectId == null
                            ? const Stream.empty()
                            : _partsStream(_projectId!),
                        builder: (_, ps) {
                          final parts = ps.data ?? const [];
                          return DropdownButtonFormField<String>(
                            value: _partId,
                            decoration: const InputDecoration(
                              labelText: 'Número de parte',
                              border: OutlineInputBorder(),
                            ),
                            items: parts
                                .map(
                                  (p) => DropdownMenuItem<String>(
                                    value: p['id'] as String,
                                    child: Text(p['numeroParte'] as String),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) async {
                              if (v == null) return;
                              final sel = parts.firstWhere((p) => p['id'] == v);
                              setState(() {
                                _partId = sel['id'] as String;
                                _partNumber = sel['numeroParte'] as String;
                                _descripcionParteCtrl.text =
                                    (sel['descripcionParte'] as String?) ?? '';
                              });
                              // Sugerir cantidad (BOM faltante)
                              await _loadSuggestedQty();
                            },
                            validator: (v) => _projectId == null
                                ? 'Elige primero un proyecto'
                                : (v == null
                                      ? 'Selecciona un número de parte'
                                      : null),
                          );
                        },
                      ),

                      // Descripciones
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _descripcionProyectoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Descripción del proyecto',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _descripcionParteCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Descripción de la parte',
                          border: OutlineInputBorder(),
                        ),
                      ),

                      // Operaciones y cantidades
                      const SizedBox(height: 16),
                      const Text(
                        'Operación y Cantidad',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Alta por flujo (varias operaciones)',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Switch(
                            value: _multiMode,
                            onChanged: (v) => setState(() => _multiMode = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),

                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: _ops
                            .map(
                              (o) => FilterChip(
                                label: Text('[${o.order}] ${o.nombre}'),
                                selected: _selectedOps.any((s) => s.id == o.id),
                                onSelected: (sel) {
                                  setState(() {
                                    if (sel) {
                                      _selectedOps.add(o);
                                      _perOpMachineId.putIfAbsent(
                                        o.id,
                                        () => null,
                                      );
                                      _perOpMachineName.putIfAbsent(
                                        o.id,
                                        () => null,
                                      );
                                      _perOpBodegaName.putIfAbsent(
                                        o.id,
                                        () => null,
                                      );
                                      _perOpAssignments.putIfAbsent(
                                        o.id,
                                        () => [_OpAssign()],
                                      );
                                    } else {
                                      _selectedOps.removeWhere(
                                        (s) => s.id == o.id,
                                      );
                                      _perOpMachineId.remove(o.id);
                                      _perOpMachineName.remove(o.id);
                                      _perOpBodegaName.remove(o.id);
                                      _perOpAssignments.remove(o.id);
                                    }
                                  });
                                },
                              ),
                            )
                            .toList(),
                      ),

                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _selectedOps
                                  ..clear()
                                  ..addAll(_ops);
                                for (final o in _ops) {
                                  _perOpMachineId.putIfAbsent(o.id, () => null);
                                  _perOpMachineName.putIfAbsent(
                                    o.id,
                                    () => null,
                                  );
                                  _perOpBodegaName.putIfAbsent(
                                    o.id,
                                    () => null,
                                  );
                                  _perOpAssignments.putIfAbsent(
                                    o.id,
                                    () => [_OpAssign()],
                                  );
                                }
                              });
                            },
                            icon: const Icon(Icons.done_all),
                            label: const Text('Seleccionar todos'),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _selectedOps.clear();
                                _perOpMachineId.clear();
                                _perOpMachineName.clear();
                                _perOpBodegaName.clear();
                                _perOpAssignments.clear();
                              });
                            },
                            icon: const Icon(Icons.filter_alt_off),
                            label: const Text('Limpiar'),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),
                      if (_selectedOps.isNotEmpty)
                        const Text(
                          'Asignaciones por operación',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      const SizedBox(height: 8),

                      ..._selectedOps.map(
                        (o) => _opCard(
                          op: o,
                          machines: _machines,
                          operadores: _operadores,
                        ),
                      ),

                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _cantidadSugeridaCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Cantidad sugerida (opcional)',
                          helperText:
                              'Tip: usa este valor como guía y reparte cantidades por operador dentro de cada operación.',
                          border: OutlineInputBorder(),
                        ),
                      ),

                      // Fechas
                      const SizedBox(height: 18),
                      const Text(
                        'Fechas',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ListTile(
                        title: Text(
                          _fecha == null
                              ? 'Selecciona fecha de actividad (obligatoria)'
                              : DateFormat('yyyy-MM-dd').format(_fecha!),
                        ),
                        trailing: const Icon(Icons.calendar_today),
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2023),
                            lastDate: DateTime(2035),
                          );
                          if (picked != null) setState(() => _fecha = picked);
                        },
                      ),
                      ListTile(
                        title: Text(
                          _fechaCompromiso == null
                              ? 'Selecciona fecha compromiso (obligatoria)'
                              : DateFormat(
                                  'yyyy-MM-dd',
                                ).format(_fechaCompromiso!),
                        ),
                        trailing: const Icon(Icons.event_available),
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2023),
                            lastDate: DateTime(2035),
                          );
                          if (picked != null) {
                            setState(() => _fechaCompromiso = picked);
                          }
                        },
                      ),

                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save),
                        label: Text(_saving ? 'Guardando...' : 'Guardar'),
                        onPressed: _saving ? null : _submit,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _opCard({
    required _OpMeta op,
    required List<Map<String, String>> machines,
    required List<Map<String, String>> operadores,
  }) {
    // asegura al menos 1 fila editable
    final assigns = _perOpAssignments[op.id] ??= [_OpAssign()];
    final sug = int.tryParse(_cantidadSugeridaCtrl.text.trim());

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '[${op.order}] ${op.nombre}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),

            DropdownButtonFormField<String>(
              value: _perOpMachineId[op.id],
              decoration: const InputDecoration(
                labelText: 'Máquina',
                border: OutlineInputBorder(),
              ),
              items: machines
                  .map(
                    (m) => DropdownMenuItem<String>(
                      value: m['id'],
                      child: Text('${m['nombre']} • ${m['bodega']}'),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                final sel = machines.firstWhere((m) => m['id'] == v);
                setState(() {
                  _perOpMachineId[op.id] = sel['id'];
                  _perOpMachineName[op.id] = sel['nombre'];
                  _perOpBodegaName[op.id] = sel['bodega'];
                });
              },
              validator: (_) =>
                  _perOpMachineId[op.id] == null ? 'Requerido' : null,
            ),
            const SizedBox(height: 12),

            const Text(
              'Reparto por operador',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),

            // Filas reales (todas editables)
            ...assigns.asMap().entries.map((e) {
              final idx = e.key;
              final a = e.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        value: a.operadorUid,
                        decoration: const InputDecoration(
                          labelText: 'Operador',
                          border: OutlineInputBorder(),
                        ),
                        items: operadores
                            .map(
                              (o) => DropdownMenuItem<String>(
                                value: o['uid'],
                                child: Text(o['nombre'] ?? ''),
                              ),
                            )
                            .toList(),
                        onChanged: (uid) {
                          if (uid == null) return;
                          final o = operadores.firstWhere(
                            (x) => x['uid'] == uid,
                          );
                          setState(() {
                            a.operadorUid = uid;
                            a.operadorNombre = o['nombre'];
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        initialValue: a.qty == 0 ? '' : a.qty.toString(),
                        onChanged: (v) =>
                            setState(() => a.qty = int.tryParse(v) ?? 0),
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Cant.',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Quitar',
                      onPressed: () {
                        setState(() {
                          _perOpAssignments[op.id]!.removeAt(idx);
                          if (_perOpAssignments[op.id]!.isEmpty) {
                            _perOpAssignments[op.id] = [_OpAssign()];
                          }
                        });
                      },
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
              );
            }),

            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      (_perOpAssignments[op.id] ??= []).add(_OpAssign());
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Agregar asignación'),
                ),
                OutlinedButton.icon(
                  onPressed: (sug == null || sug <= 0 || assigns.isEmpty)
                      ? null
                      : () {
                          final vivos = assigns
                              .where((a) => a.operadorUid != null)
                              .toList();
                          if (vivos.isEmpty) return;
                          final base = sug ~/ vivos.length;
                          int resto = sug % vivos.length;
                          setState(() {
                            for (final a in vivos) {
                              a.qty = base + (resto > 0 ? 1 : 0);
                              resto = max(0, resto - 1);
                            }
                          });
                        },
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Repartir sugerido'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
