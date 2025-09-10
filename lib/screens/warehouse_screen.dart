import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// ===============================================================
/// ALMACÉN (Warehouse)
///
/// Colecciones esperadas:
/// - bodegas                   : {nombre, code?}
/// - projects/{proj}/parts     : {numeroParte, descripcionParte, activo}
/// - warehouse_movements       : {type, qty, bodegaId, bodegaNombre, parteId, numeroParte, ref, ts}
/// - warehouse_stock           : docId = "${bodegaId}_${parteId}"
///                               {bodegaId, bodegaNombre, parteId, numeroParte, qty}
///
/// Lógica de registro:
/// - Se crea un movimiento en `warehouse_movements`
/// - En una TRANSACCIÓN se incrementa/decrementa `warehouse_stock.qty`
///   (si no existe el doc, se crea con qty inicial = delta)
///
/// Tipos de movimiento:
/// - in     : suma
/// - out    : resta (valida no negativo)
/// - adjust : lleva a un valor exacto (qty final = qty capturada)
/// ===============================================================
class WarehouseScreen extends StatefulWidget {
  const WarehouseScreen({super.key});

  @override
  State<WarehouseScreen> createState() => _WarehouseScreenState();
}

class _WarehouseScreenState extends State<WarehouseScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  // --------- Filtros de UI (stock y movimientos) ----------
  String _stockSearch = '';
  String? _stockBodegaId;

  String _movSearch = '';
  String? _movBodegaId;
  String? _movType; // null/in/out/adjust
  DateTimeRange? _movRange;

  // --------- Cache catálogos ----------
  late Future<List<_Bodega>> _bodegasFuture;
  late Future<List<_ParteRef>> _partesFuture; // de todos los proyectos

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _bodegasFuture = _loadBodegas();
    _partesFuture = _loadAllParts();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  // ======================= Firestore: catálogos =======================
  Future<List<_Bodega>> _loadBodegas() async {
    final qs = await FirebaseFirestore.instance.collection('bodegas').get();
    return qs.docs
        .map((d) => _Bodega(id: d.id, nombre: (d['nombre'] ?? '').toString()))
        .toList()
      ..sort((a, b) => a.nombre.compareTo(b.nombre));
  }

  /// Carga TODAS las partes recorriendo proyectos. Si crece muchísimo,
  /// migra a colección de catálogo “planas” (ej. /parts raíz).
  Future<List<_ParteRef>> _loadAllParts() async {
    final projs = await FirebaseFirestore.instance.collection('projects').get();
    final List<_ParteRef> out = [];
    for (final p in projs.docs) {
      final parts = await p.reference.collection('parts').get();
      for (final part in parts.docs) {
        out.add(
          _ParteRef(
            parteId: part.id,
            numeroParte: (part['numeroParte'] ?? '').toString(),
            descripcionParte: (part['descripcionParte'] ?? '').toString(),
            proyectoId: p.id,
            proyectoNombre: (p['proyecto'] ?? '').toString(),
          ),
        );
      }
    }
    out.sort((a, b) => a.numeroParte.compareTo(b.numeroParte));
    return out;
  }

  // ======================= UI =======================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Almacén'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(icon: Icon(Icons.inventory_2_outlined), text: 'Stock'),
            Tab(icon: Icon(Icons.swap_vert), text: 'Movimientos'),
            Tab(icon: Icon(Icons.add_circle_outline), text: 'Nuevo'),
          ],
        ),
      ),
      body: FutureBuilder(
        future: Future.wait([_bodegasFuture, _partesFuture]),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final bodegas = snap.data![0] as List<_Bodega>;
          final partes = snap.data![1] as List<_ParteRef>;

          return TabBarView(
            controller: _tab,
            children: [
              _StockTab(
                bodegas: bodegas,
                searchText: _stockSearch,
                selectedBodegaId: _stockBodegaId,
                onSearch: (s) => setState(() => _stockSearch = s),
                onBodega: (b) => setState(() => _stockBodegaId = b),
              ),
              _MovsTab(
                bodegas: bodegas,
                searchText: _movSearch,
                selectedBodegaId: _movBodegaId,
                selectedType: _movType,
                range: _movRange,
                onSearch: (s) => setState(() => _movSearch = s),
                onBodega: (b) => setState(() => _movBodegaId = b),
                onType: (t) => setState(() => _movType = t),
                onRange: (r) => setState(() => _movRange = r),
              ),
              _NewMovementTab(
                bodegas: bodegas,
                partes: partes,
                onSaved: () {
                  // Al guardar, refrescamos pestañas:
                  // (streams se actualizan solos; sólo avisamos)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Movimiento registrado')),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

/// ===============================================================
/// TAB 1: STOCK (lee `warehouse_stock`)
/// ===============================================================
class _StockTab extends StatelessWidget {
  final List<_Bodega> bodegas;
  final String searchText;
  final String? selectedBodegaId;
  final ValueChanged<String> onSearch;
  final ValueChanged<String?> onBodega;

  const _StockTab({
    required this.bodegas,
    required this.searchText,
    required this.selectedBodegaId,
    required this.onSearch,
    required this.onBodega,
  });

  @override
  Widget build(BuildContext context) {
    final q = FirebaseFirestore.instance.collection('warehouse_stock');

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Bodega
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String?>(
                  value: selectedBodegaId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Bodega',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Todas'),
                    ),
                    ...bodegas.map(
                      (b) => DropdownMenuItem<String?>(
                        value: b.id,
                        child: Text(b.nombre),
                      ),
                    ),
                  ],
                  onChanged: onBodega,
                ),
              ),
              const SizedBox(width: 12),
              // Buscar
              Expanded(
                flex: 3,
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Buscar Nº de parte',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: onSearch,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: q.snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text('Error: ${snap.error}'));
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              var docs = snap.data!.docs;

              // Filtro por bodega
              if (selectedBodegaId != null) {
                docs = docs
                    .where((d) => (d['bodegaId'] ?? '') == selectedBodegaId)
                    .toList();
              }
              // Filtro por texto
              final s = searchText.trim().toLowerCase();
              if (s.isNotEmpty) {
                docs = docs
                    .where(
                      (d) => (d['numeroParte'] ?? '')
                          .toString()
                          .toLowerCase()
                          .contains(s),
                    )
                    .toList();
              }

              if (docs.isEmpty) {
                return const Center(child: Text('Sin existencias.'));
              }

              docs.sort((a, b) {
                final ab = (a['bodegaNombre'] ?? '').toString();
                final bb = (b['bodegaNombre'] ?? '').toString();
                final ap = (a['numeroParte'] ?? '').toString();
                final bp = (b['numeroParte'] ?? '').toString();
                final c1 = ab.compareTo(bb);
                if (c1 != 0) return c1;
                return ap.compareTo(bp);
              });

              return ListView.separated(
                itemCount: docs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final d = docs[i].data();
                  final qty = (d['qty'] ?? 0) as int;
                  return ListTile(
                    leading: CircleAvatar(child: Text(qty.toString())),
                    title: Text('${d['numeroParte'] ?? '—'}'),
                    subtitle: Text('Bodega: ${d['bodegaNombre'] ?? '—'}'),
                    trailing: Text('Stock: $qty'),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// ===============================================================
/// TAB 2: MOVIMIENTOS (lee `warehouse_movements`)
/// ===============================================================
class _MovsTab extends StatelessWidget {
  final List<_Bodega> bodegas;
  final String searchText;
  final String? selectedBodegaId;
  final String? selectedType; // null/in/out/adjust
  final DateTimeRange? range;

  final ValueChanged<String> onSearch;
  final ValueChanged<String?> onBodega;
  final ValueChanged<String?> onType;
  final ValueChanged<DateTimeRange?> onRange;

  const _MovsTab({
    required this.bodegas,
    required this.searchText,
    required this.selectedBodegaId,
    required this.selectedType,
    required this.range,
    required this.onSearch,
    required this.onBodega,
    required this.onType,
    required this.onRange,
  });

  @override
  Widget build(BuildContext context) {
    final q = FirebaseFirestore.instance
        .collection('warehouse_movements')
        .orderBy('ts', descending: true);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: selectedBodegaId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Bodega',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Todas'),
                        ),
                        ...bodegas.map(
                          (b) => DropdownMenuItem<String?>(
                            value: b.id,
                            child: Text(b.nombre),
                          ),
                        ),
                      ],
                      onChanged: onBodega,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: selectedType,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Tipo',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: null, child: Text('Todos')),
                        DropdownMenuItem(value: 'in', child: Text('Entrada')),
                        DropdownMenuItem(value: 'out', child: Text('Salida')),
                        DropdownMenuItem(
                          value: 'adjust',
                          child: Text('Ajuste'),
                        ),
                      ],
                      onChanged: onType,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: 'Buscar Nº de parte',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: onSearch,
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(now.year - 2),
                        lastDate: DateTime(now.year + 2),
                        initialDateRange: range,
                      );
                      onRange(picked);
                    },
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      range == null
                          ? 'Rango fechas'
                          : '${DateFormat('yyyy-MM-dd').format(range!.start)} → ${DateFormat('yyyy-MM-dd').format(range!.end)}',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: q.snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text('Error: ${snap.error}'));
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              var docs = snap.data!.docs;

              // Filtros en memoria (evitamos índices compuestos)
              if (selectedBodegaId != null) {
                docs = docs
                    .where((d) => (d['bodegaId'] ?? '') == selectedBodegaId)
                    .toList();
              }
              if (selectedType != null) {
                docs = docs.where((d) => d['type'] == selectedType).toList();
              }
              if (range != null) {
                docs = docs.where((d) {
                  final ts = d['ts'];
                  if (ts is Timestamp) {
                    final dt = ts.toDate();
                    return !dt.isBefore(range!.start) &&
                        !dt.isAfter(
                          DateTime(
                            range!.end.year,
                            range!.end.month,
                            range!.end.day,
                            23,
                            59,
                            59,
                            999,
                          ),
                        );
                  }
                  return false;
                }).toList();
              }
              final s = searchText.trim().toLowerCase();
              if (s.isNotEmpty) {
                docs = docs
                    .where(
                      (d) => (d['numeroParte'] ?? '')
                          .toString()
                          .toLowerCase()
                          .contains(s),
                    )
                    .toList();
              }

              if (docs.isEmpty) {
                return const Center(child: Text('Sin movimientos.'));
              }

              return ListView.separated(
                itemCount: docs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final d = docs[i].data();
                  final ts = (d['ts'] as Timestamp).toDate();
                  final qty = (d['qty'] ?? 0) as int;
                  final t = (d['type'] ?? '').toString();
                  final color = t == 'in'
                      ? Colors.green
                      : t == 'out'
                      ? Colors.red
                      : Colors.orange;

                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color.withOpacity(0.12),
                      child: Icon(
                        t == 'in'
                            ? Icons.call_received
                            : t == 'out'
                            ? Icons.call_made
                            : Icons.rule,
                        color: color,
                      ),
                    ),
                    title: Text(
                      '${d['numeroParte'] ?? '—'}   ·   ${d['bodegaNombre'] ?? '—'}',
                    ),
                    subtitle: Text(
                      '${DateFormat('yyyy-MM-dd HH:mm').format(ts)}\nRef: ${d['ref'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      t == 'adjust'
                          ? '→ $qty'
                          : (t == 'in' ? '+$qty' : '-$qty'),
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// ===============================================================
/// TAB 3: NUEVO MOVIMIENTO
/// ===============================================================
class _NewMovementTab extends StatefulWidget {
  final List<_Bodega> bodegas;
  final List<_ParteRef> partes;
  final VoidCallback onSaved;

  const _NewMovementTab({
    required this.bodegas,
    required this.partes,
    required this.onSaved,
  });

  @override
  State<_NewMovementTab> createState() => _NewMovementTabState();
}

class _NewMovementTabState extends State<_NewMovementTab> {
  final _form = GlobalKey<FormState>();
  String _type = 'in'; // in/out/adjust
  _Bodega? _bodega;
  _ParteRef? _parte;
  final _qtyCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_bodega == null || _parte == null) return;

    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    setState(() => _saving = true);

    try {
      await _registerMovementAndUpdateStock(
        type: _type,
        qty: qty,
        bodega: _bodega!,
        parte: _parte!,
        refText: _refCtrl.text.trim(),
      );

      if (!mounted) return;
      widget.onSaved();
      // limpiamos
      setState(() {
        _type = 'in';
        _bodega = null;
        _parte = null;
        _qtyCtrl.clear();
        _refCtrl.clear();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final partes = widget.partes;

    return AbsorbPointer(
      absorbing: _saving,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: ListView(
            children: [
              // Tipo
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'in', label: Text('Entrada')),
                  ButtonSegment(value: 'out', label: Text('Salida')),
                  ButtonSegment(value: 'adjust', label: Text('Ajuste')),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
              const SizedBox(height: 12),

              // Bodega
              DropdownButtonFormField<_Bodega>(
                value: _bodega,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Bodega',
                  border: OutlineInputBorder(),
                ),
                items: widget.bodegas
                    .map(
                      (b) => DropdownMenuItem(value: b, child: Text(b.nombre)),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _bodega = v),
                validator: (v) => v == null ? 'Selecciona bodega' : null,
              ),
              const SizedBox(height: 12),

              // Parte (con buscador simple)
              _PartePicker(
                partes: partes,
                value: _parte,
                onChanged: (p) => setState(() => _parte = p),
              ),
              const SizedBox(height: 12),

              // Cantidad
              TextFormField(
                controller: _qtyCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: _type == 'adjust' ? 'Cantidad FINAL' : 'Cantidad',
                  border: const OutlineInputBorder(),
                ),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  if (n == null || n <= 0) return 'Cantidad inválida';
                  return null;
                },
              ),
              const SizedBox(height: 12),

              // Referencia
              TextFormField(
                controller: _refCtrl,
                decoration: const InputDecoration(
                  labelText: 'Referencia / Comentario (opcional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 20),

              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(_saving ? 'Guardando…' : 'Registrar movimiento'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Crea el movimiento y actualiza stock con TRANSACCIÓN
  Future<void> _registerMovementAndUpdateStock({
    required String type, // in/out/adjust
    required int qty,
    required _Bodega bodega,
    required _ParteRef parte,
    required String refText,
  }) async {
    final fs = FirebaseFirestore.instance;

    final movRef = fs.collection('warehouse_movements').doc();
    final stockId = '${bodega.id}_${parte.parteId}';
    final stockRef = fs.collection('warehouse_stock').doc(stockId);

    await fs.runTransaction((tx) async {
      // 1) Leer stock actual (si no existe, qtyActual=0)
      final stockSnap = await tx.get(stockRef);
      final currentQty = stockSnap.exists
          ? (((() { final m = stockSnap.data(); return m == null ? 0 : (m['qty'] ?? 0); })()) as int)
          : 0;

      int newQty = currentQty;
      if (type == 'in') {
        newQty = currentQty + qty;
      } else if (type == 'out') {
        if (currentQty - qty < 0) {
          throw Exception(
            'Stock insuficiente ($currentQty) para salida de $qty',
          );
        }
        newQty = currentQty - qty;
      } else if (type == 'adjust') {
        newQty = qty; // qty es el valor FINAL
      }

      // 2) Upsert del stock
      if (stockSnap.exists) {
        tx.update(stockRef, {
          'qty': newQty,
          'bodegaNombre': bodega.nombre,
          'numeroParte': parte.numeroParte,
        });
      } else {
        tx.set(stockRef, {
          'bodegaId': bodega.id,
          'bodegaNombre': bodega.nombre,
          'parteId': parte.parteId,
          'numeroParte': parte.numeroParte,
          'qty': newQty,
        });
      }

      // 3) Registrar el movimiento
      tx.set(movRef, {
        'type': type,
        'qty': qty,
        'bodegaId': bodega.id,
        'bodegaNombre': bodega.nombre,
        'parteId': parte.parteId,
        'numeroParte': parte.numeroParte,
        'ref': refText,
        'ts': FieldValue.serverTimestamp(),
      });
    });
  }
}

/// ===================== Picker de Parte con filtro local =====================
class _PartePicker extends StatefulWidget {
  final List<_ParteRef> partes;
  final _ParteRef? value;
  final ValueChanged<_ParteRef?> onChanged;

  const _PartePicker({
    required this.partes,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_PartePicker> createState() => _PartePickerState();
}

class _PartePickerState extends State<_PartePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.partes.where((p) {
      if (_query.isEmpty) return true;
      final s = _query.toLowerCase();
      return p.numeroParte.toLowerCase().contains(s) ||
          p.descripcionParte.toLowerCase().contains(s) ||
          p.proyectoNombre.toLowerCase().contains(s);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Número de parte', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        TextField(
          decoration: const InputDecoration(
            hintText: 'Buscar parte / proyecto…',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _query = v.trim()),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<_ParteRef>(
          value: widget.value,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: filtered
              .map(
                (p) => DropdownMenuItem(
                  value: p,
                  child: Text(
                    '${p.numeroParte}   ·   ${p.proyectoNombre}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: widget.onChanged,
          validator: (v) => v == null ? 'Selecciona un Nº de parte' : null,
        ),
      ],
    );
  }
}

/// ===================== Modelitos simples =====================
class _Bodega {
  final String id;
  final String nombre;
  _Bodega({required this.id, required this.nombre});
}

class _ParteRef {
  final String parteId; // id del doc en /projects/{id}/parts/{parteId}
  final String numeroParte;
  final String descripcionParte;
  final String proyectoId;
  final String proyectoNombre;

  _ParteRef({
    required this.parteId,
    required this.numeroParte,
    required this.descripcionParte,
    required this.proyectoId,
    required this.proyectoNombre,
  });
}
