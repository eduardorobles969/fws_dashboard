import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

/// Alta de producción (rol: supervisor)
/// - Catálogos:
///   - projects (raíz)            -> dropdown de proyecto (solo activos)
///   - projects/{id}/parts        -> dropdown dependiente con números de parte (solo activos)
///   - operations (raíz)          -> dropdown de operación
///   - machines (raíz)            -> dropdown de máquina (muestra bodega si existe)
///   - users (role == operador)   -> dropdown de operador
///
/// Guardado en production_daily:
///   - Referencias: proyectoRef, parteRef, operacionRef, maquinaRef, operadorRef
///   - Denormalizados: proyecto, descripcionProyecto, numeroParte, descripcionParte,
///     operacion, maquinaNombre, bodega, operadorNombre, cantidad, semana/año/mes, etc.
class AddProductionEntryScreen extends StatefulWidget {
  const AddProductionEntryScreen({super.key});

  @override
  State<AddProductionEntryScreen> createState() =>
      _AddProductionEntryScreenState();
}

class _AddProductionEntryScreenState extends State<AddProductionEntryScreen> {
  final _formKey = GlobalKey<FormState>();

  // Texto
  final TextEditingController _descripcionProyectoCtrl =
      TextEditingController();
  final TextEditingController _descripcionParteCtrl = TextEditingController();
  final TextEditingController _cantidadCtrl = TextEditingController();

  // Selecciones
  String? _projectId;
  String? _projectName;

  String? _partId;
  String? _partNumber;

  String? _operationId;
  String? _operationName;

  String? _machineId;
  String? _machineName;
  String? _bodegaName;

  String? _operadorUid;
  String? _operadorNombre;

  DateTime? _fecha; // fecha de actividad
  DateTime? _fechaCompromiso; // fecha compromiso opcional

  bool _saving = false;

  // ===================== UTIL: Semana ISO =====================
  /// Semana ISO 8601 (1..53) – evita S0 y normaliza semanas entre años.
  int _isoWeekNumber(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    final thursday = d.add(Duration(days: 3 - ((d.weekday + 6) % 7)));
    final firstThursday = DateTime(thursday.year, 1, 4);
    return 1 + ((thursday.difference(firstThursday).inDays) / 7).floor();
  }

  // ===================== CARGA DE CATÁLOGOS =====================

  Future<List<Map<String, dynamic>>> _getProjects() async {
    final snap = await FirebaseFirestore.instance
        .collection('projects')
        .where('activo', isEqualTo: true)
        .orderBy('proyecto')
        .get();

    return snap.docs
        .map(
          (d) => {
            'id': d.id,
            'proyecto': (d.data()['proyecto'] ?? '') as String,
            'descripcionProyecto':
                (d.data()['descripcionProyecto'] ?? '') as String,
          },
        )
        .toList();
  }

  Future<List<Map<String, dynamic>>> _getOperations() async {
    final snap = await FirebaseFirestore.instance
        .collection('operations')
        .get();
    return snap.docs
        .map(
          (d) => {'id': d.id, 'nombre': (d.data()['nombre'] ?? '') as String},
        )
        .toList();
  }

  Future<List<Map<String, dynamic>>> _getMachines() async {
    final snap = await FirebaseFirestore.instance.collection('machines').get();

    final List<Map<String, dynamic>> out = [];
    for (final doc in snap.docs) {
      final data = doc.data();
      String bodegaNombre = (data['bodega'] ?? '') as String;

      // Si tienes referencia a bodega, la resolvemos
      final bodegaRef = data['bodegaId'];
      if (bodegaRef is DocumentReference) {
        try {
          final b = await bodegaRef.get();
          if (b.exists) {
            bodegaNombre = ((b.data() as Map?)?['nombre'] ?? '') as String;
          }
        } catch (_) {}
      }

      out.add({
        'id': doc.id,
        'nombre': (data['nombre'] ?? '') as String,
        'bodega': bodegaNombre,
      });
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _getOperadores() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('role', isEqualTo: 'operador')
        .orderBy('displayName')
        .get();

    return snap.docs
        .map(
          (d) => {
            'uid': d.id,
            'nombre': (d.data()['displayName'] ?? '') as String,
          },
        )
        .toList();
  }

  // Partes activas del proyecto seleccionado (sin orderBy para no pedir índices)
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
                  'numeroParte': (d.data()['numeroParte'] ?? '') as String,
                  'descripcionParte':
                      (d.data()['descripcionParte'] ?? '') as String,
                },
              )
              .toList();
          // Ordenar en memoria por numeroParte (evitamos índice compuesto)
          list.sort(
            (a, b) => (a['numeroParte'] as String).compareTo(
              b['numeroParte'] as String,
            ),
          );
          return list;
        });
  }

  // ===================== GUARDADO =====================

  Future<void> _submit() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;

    if (_projectId == null ||
        _partId == null ||
        _operationId == null ||
        _machineId == null ||
        _operadorUid == null ||
        _fecha == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Completa todos los campos obligatorios')),
      );
      return;
    }

    // Validación rápida de cantidad (>= 0)
    final cantidad = int.tryParse(_cantidadCtrl.text.trim());
    if (cantidad == null || cantidad < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ingresa una cantidad válida')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      // ========= Períodos normalizados (para filtros y gráficas) =========
      final d = _fecha!;
      final anio = d.year;
      final mes = d.month;
      final semana = _isoWeekNumber(d); // ISO 8601
      final anioSemana = anio * 100 + semana; // clave ordenable
      final anioMes = anio * 100 + mes; // clave ordenable

      // ========= Referencias =========
      final proyectoRef = FirebaseFirestore.instance
          .collection('projects')
          .doc(_projectId);
      final parteRef = proyectoRef.collection('parts').doc(_partId);
      final operacionRef = FirebaseFirestore.instance
          .collection('operations')
          .doc(_operationId);
      final maquinaRef = FirebaseFirestore.instance
          .collection('machines')
          .doc(_machineId);
      final operadorRef = FirebaseFirestore.instance
          .collection('users')
          .doc(_operadorUid);

      // ========= Escritura =========
      await FirebaseFirestore.instance.collection('production_daily').add({
        // Referencias
        'proyectoRef': proyectoRef,
        'parteRef': parteRef,
        'operacionRef': operacionRef,
        'maquinaRef': maquinaRef,
        'operadorRef': operadorRef,

        // Identificador del operador (lo usan tus reglas)
        'operadorUid': _operadorUid,

        // Denormalizados para UI
        'proyecto': _projectName,
        'descripcionProyecto': _descripcionProyectoCtrl.text.trim(),
        'numeroParte': _partNumber,
        'descripcionParte': _descripcionParteCtrl.text.trim(),
        // Guarda el nombre también en 'operacion' (además de operacionNombre por compatibilidad)
        'operacion': _operationName,
        'operacionNombre': _operationName,
        'maquinaNombre': _machineName,
        'bodega': _bodegaName,
        'operadorNombre': _operadorNombre,

        // Fechas / periodos
        'fecha': Timestamp.fromDate(d),
        'anio': anio,
        'mes': mes,
        'semana': semana,
        'anioSemana': anioSemana,
        'anioMes': anioMes,
        'fechaCompromiso': _fechaCompromiso != null
            ? Timestamp.fromDate(_fechaCompromiso!)
            : null,

        // Datos
        'cantidad': cantidad,

        // Estado inicial (match EXACTO con tus reglas)
        'status': 'programado',

        // Métricas iniciales
        'inicio': null,
        'fin': null,
        'pass': 0,
        'fail': 0,
        'scrap': 0,
        'yield': 0.0, // 'yield' es palabra reservada en Dart, pero no como key
        'scrapPendiente': false,
        'scrapAprobado': false,

        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Registro guardado')));
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error al guardar: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ===================== UI =====================

  @override
  void dispose() {
    _descripcionProyectoCtrl.dispose();
    _descripcionParteCtrl.dispose();
    _cantidadCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Cargamos catálogos base en paralelo
    final future = Future.wait([
      _getProjects(), // 0
      _getOperations(), // 1
      _getMachines(), // 2
      _getOperadores(), // 3
    ]);

    return Scaffold(
      appBar: AppBar(title: const Text('Alta de Producción')),
      body: FutureBuilder<List<dynamic>>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }

          final projects = (snap.data![0] as List<Map<String, dynamic>>);
          final operations = (snap.data![1] as List<Map<String, dynamic>>);
          final machines = (snap.data![2] as List<Map<String, dynamic>>);
          final operadores = (snap.data![3] as List<Map<String, dynamic>>);

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
                        onChanged: (value) {
                          final sel = projects.firstWhere(
                            (p) => p['id'] == value,
                          );
                          setState(() {
                            _projectId = sel['id'] as String;
                            _projectName = sel['proyecto'] as String;

                            // Pre-cargar descripción proyecto editable
                            _descripcionProyectoCtrl.text =
                                (sel['descripcionProyecto'] as String?) ?? '';

                            // Reset parte
                            _partId = null;
                            _partNumber = null;
                            _descripcionParteCtrl.clear();
                          });
                        },
                        validator: (v) =>
                            v == null ? 'Selecciona un proyecto' : null,
                      ),

                      // Número de parte (depende del proyecto)
                      const SizedBox(height: 12),
                      StreamBuilder<List<Map<String, dynamic>>>(
                        stream: _projectId == null
                            ? const Stream.empty()
                            : _partsStream(_projectId!),
                        builder: (context, ss) {
                          final parts =
                              ss.data ?? const <Map<String, dynamic>>[];

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
                            onChanged: (value) {
                              if (value == null) return;
                              final sel = parts.firstWhere(
                                (p) => p['id'] == value,
                              );
                              setState(() {
                                _partId = sel['id'] as String;
                                _partNumber = sel['numeroParte'] as String;
                                _descripcionParteCtrl.text =
                                    (sel['descripcionParte'] as String?) ?? '';
                              });
                            },
                            validator: (v) => _projectId == null
                                ? 'Elige primero un proyecto'
                                : (v == null
                                      ? 'Selecciona un número de parte'
                                      : null),
                          );
                        },
                      ),

                      // Descripciones (editables)
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

                      // Operación y cantidad
                      const SizedBox(height: 16),
                      const Text(
                        'Operación y Cantidad',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _operationId,
                        decoration: const InputDecoration(
                          labelText: 'Operación',
                          border: OutlineInputBorder(),
                        ),
                        items: operations
                            .map(
                              (o) => DropdownMenuItem<String>(
                                value: o['id'] as String,
                                child: Text(o['nombre'] as String),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          final sel = operations.firstWhere(
                            (o) => o['id'] == value,
                          );
                          setState(() {
                            _operationId = sel['id'] as String;
                            _operationName = sel['nombre'] as String;
                          });
                        },
                        validator: (v) =>
                            v == null ? 'Selecciona la operación' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _cantidadCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Cantidad',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Requerido'
                            : null,
                      ),

                      // Máquina y operador
                      const SizedBox(height: 16),
                      const Text(
                        'Máquina y Operador',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _machineId,
                        decoration: const InputDecoration(
                          labelText: 'Máquina',
                          border: OutlineInputBorder(),
                        ),
                        items: machines
                            .map(
                              (m) => DropdownMenuItem<String>(
                                value: m['id'] as String,
                                child: Text(
                                  '${m['nombre']}  •  ${m['bodega']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          final sel = machines.firstWhere(
                            (m) => m['id'] == value,
                          );
                          setState(() {
                            _machineId = sel['id'] as String;
                            _machineName = sel['nombre'] as String;
                            _bodegaName = sel['bodega'] as String;
                          });
                        },
                        validator: (v) =>
                            v == null ? 'Selecciona una máquina' : null,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _operadorUid,
                        decoration: const InputDecoration(
                          labelText: 'Operador',
                          border: OutlineInputBorder(),
                        ),
                        items: operadores
                            .map(
                              (o) => DropdownMenuItem<String>(
                                value: o['uid'] as String,
                                child: Text(o['nombre'] as String),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          final sel = operadores.firstWhere(
                            (o) => o['uid'] == value,
                          );
                          setState(() {
                            _operadorUid = sel['uid'] as String;
                            _operadorNombre = sel['nombre'] as String;
                          });
                        },
                        validator: (v) =>
                            v == null ? 'Selecciona un operador' : null,
                      ),

                      // Fechas
                      const SizedBox(height: 16),
                      const Text(
                        'Fechas',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        title: Text(
                          _fecha == null
                              ? 'Selecciona fecha de actividad'
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
                              ? 'Selecciona fecha compromiso (opcional)'
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
}
