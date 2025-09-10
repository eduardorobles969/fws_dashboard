import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class BomScreen extends StatefulWidget {
  const BomScreen({super.key});
  @override
  State<BomScreen> createState() => _BomScreenState();
}

class _BomScreenState extends State<BomScreen> {
  String? _projectId;
  String _search = '';
  final _onlyMaterialPending = ValueNotifier<bool>(false);
  final _onlyPurchasePending = ValueNotifier<bool>(false);
  final Set<String> _selected = <String>{};

  // Catálogos
  late Future<List<_MaterialDoc>> _materialsFuture;
  late Future<List<_SupplierDoc>> _suppliersFuture;

  @override
  void initState() {
    super.initState();
    _materialsFuture = _loadMaterials();
    _suppliersFuture = _loadSuppliers();
  }

  // ----- CARGA CATÁLOGOS con fallback si faltan índices -----
  Future<List<_MaterialDoc>> _loadMaterials() async {
    final col = FirebaseFirestore.instance.collection('materials');
    try {
      final qs = await col
          .where('active', isEqualTo: true)
          .orderBy('sort')
          .get();
      return qs.docs.map(_matFromDoc).toList();
    } on FirebaseException catch (e) {
      if (e.code == 'failed-precondition') {
        final qs = await col.orderBy('sort').get();
        return qs.docs
            .where((d) => (d.data()['active'] ?? true) == true)
            .map(_matFromDoc)
            .toList();
      }
      rethrow;
    }
  }

  _MaterialDoc _matFromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    return _MaterialDoc(
      id: d.id,
      code: (m['code'] ?? '').toString(),
      desc: (m['desc'] ?? '').toString(),
      colorHex: (m['color'] ?? '').toString(),
      ref: d.reference,
    );
  }

  Future<List<_SupplierDoc>> _loadSuppliers() async {
    final col = FirebaseFirestore.instance.collection('suppliers');
    try {
      final qs = await col
          .where('active', isEqualTo: true)
          .orderBy('name')
          .get();
      return qs.docs.map(_supFromDoc).toList();
    } on FirebaseException catch (e) {
      if (e.code == 'failed-precondition') {
        final qs = await col.orderBy('name').get();
        return qs.docs
            .where((d) => (d.data()['active'] ?? true) == true)
            .map(_supFromDoc)
            .toList();
      }
      rethrow;
    }
  }

  _SupplierDoc _supFromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    return _SupplierDoc(
      id: d.id,
      name: (m['name'] ?? '').toString(),
      ref: d.reference,
    );
  }

  // ---------------- DATA ----------------
  Future<List<Map<String, dynamic>>> _projects() async {
    final qs = await FirebaseFirestore.instance
        .collection('projects')
        .where('activo', isEqualTo: true)
        .orderBy('proyecto')
        .get();
    return qs.docs
        .map((d) => {'id': d.id, 'proyecto': (d['proyecto'] ?? '').toString()})
        .toList();
  }

  Stream<List<_PartDoc>> _partsStream() {
    if (_projectId == null) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection('projects')
        .doc(_projectId)
        .collection('parts')
        .orderBy('numeroParte')
        .snapshots()
        .map((qs) {
          return qs.docs.map((d) {
            final m = d.data();
            return _PartDoc(
              id: d.id,
              numero: (m['numeroParte'] ?? '').toString(),
              descr: (m['descripcionParte'] ?? '').toString(),
              plan: (m['cantidadPlan'] ?? 0) is int
                  ? (m['cantidadPlan'] as int)
                  : int.tryParse('${m['cantidadPlan']}') ?? 0,
              nestDim: (m['nestDim'] ?? m['nesting'] ?? '')
                  .toString(), // compat
              materialComprado: (m['materialComprado'] ?? false) == true,
              materialCompradoFecha: m['materialCompradoFecha'] is Timestamp
                  ? (m['materialCompradoFecha'] as Timestamp)
                  : null,
              materialCode: (m['materialCode'] ?? '').toString(),
              materialRef: m['materialRef'] is DocumentReference
                  ? m['materialRef']
                  : null,
              proveedorTexto: (m['proveedor'] ?? '').toString(),
              supplierRef: m['supplierRef'] is DocumentReference
                  ? m['supplierRef']
                  : null,
              nestGroup: (m['nestGroup'] ?? '').toString(),
              docRef: d.reference,
            );
          }).toList();
        });
  }

  Stream<Map<String, int>> _assignedByPart() {
    if (_projectId == null) return const Stream.empty();
    final projRef = FirebaseFirestore.instance
        .collection('projects')
        .doc(_projectId);
    return FirebaseFirestore.instance
        .collection('production_daily')
        .where('proyectoRef', isEqualTo: projRef)
        .snapshots()
        .map((qs) {
          final map = <String, int>{};
          for (final d in qs.docs) {
            final data = d.data();
            final parteRef = data['parteRef'];
            if (parteRef is DocumentReference) {
              final key = parteRef.path;
              final cant = (data['cantidad'] ?? 0) is int
                  ? (data['cantidad'] as int)
                  : int.tryParse('${data['cantidad']}') ?? 0;
              map[key] = (map[key] ?? 0) + cant;
            }
          }
          return map;
        });
  }

  // ---------- CSV / PDF ----------
  Future<void> _copyCsv(List<_BomRow> rows) async {
    final header = [
      'numeroParte',
      'descripcionParte',
      'plan',
      'asignada',
      'faltan',
      'material',
      'dimension',
      'estatusCompra',
      'proveedor',
      'fechaCompra',
    ];
    final b = StringBuffer()..writeln(header.join(','));
    for (final r in rows) {
      b.writeln(
        [
          r.numero,
          r.descr.replaceAll(',', ' '),
          r.plan,
          r.asignada,
          (r.plan - r.asignada).clamp(0, 1 << 31),
          r.materialLabel.replaceAll(',', ' '),
          r.nestDim.replaceAll(',', ' '),
          r.materialComprado ? 'Comprado' : 'Pendiente',
          r.proveedorMostrar.replaceAll(',', ' '),
          r.materialCompradoFecha == null
              ? ''
              : DateFormat(
                  'yyyy-MM-dd',
                ).format(r.materialCompradoFecha!.toDate()),
        ].join(','),
      );
    }
    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('BOM copiado (CSV)')));
  }

  Future<Uint8List> _buildPdfBytes({
    required String projectName,
    required List<_BomRow> rows,
  }) async {
    final pdf = pw.Document();
    pw.MemoryImage? logo;
    try {
      final bytes = await rootBundle.load('assets/icon.png');
      logo = pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {}

    final h = pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold);
    final n = pw.TextStyle(fontSize: 10);

    pdf.addPage(
      pw.MultiPage(
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) => [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              if (logo != null) pw.Image(logo, width: 36, height: 36),
              pw.SizedBox(width: 12),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'BOM del Proyecto',
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(projectName, style: pw.TextStyle(fontSize: 12)),
                  pw.Text(
                    DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()),
                    style: pw.TextStyle(fontSize: 9),
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 12),

          // ====== PDF SIN "Plan/Asign/Faltan" y CON "Grupo" ======
          pw.TableHelper.fromTextArray(
            headerStyle: h,
            cellStyle: n,
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            columnWidths: const {
              0: pw.FixedColumnWidth(90), // P/N
              1: pw.FlexColumnWidth(2), // Descripción
              2: pw.FlexColumnWidth(2), // Material
              3: pw.FlexColumnWidth(2), // Dimensión
              4: pw.FixedColumnWidth(70), // Grupo (nuevo)
              5: pw.FixedColumnWidth(64), // Estatus
              6: pw.FixedColumnWidth(80), // Proveedor
              7: pw.FixedColumnWidth(64), // Fecha
            },
            headers: const [
              'P/N',
              'Descripción',
              'Material',
              'Dimensión',
              'Grupo',
              'Estatus',
              'Proveedor',
              'Fecha',
            ],
            data: rows.map((r) {
              return [
                r.numero,
                r.descr,
                r.materialLabel,
                r.nestDim,
                (r.nestGroup.trim().isEmpty ? '—' : r.nestGroup),
                r.materialComprado ? 'Comprado' : 'Pendiente',
                r.proveedorMostrar,
                r.materialCompradoFecha == null
                    ? ''
                    : DateFormat(
                        'yyyy-MM-dd',
                      ).format(r.materialCompradoFecha!.toDate()),
              ];
            }).toList(),
          ),
        ],
      ),
    );
    return pdf.save();
  }

  Future<void> _printPdf(List<_BomRow> rows) async {
    final projs = await _projects();
    Map<String, dynamic>? projMap;
    for (final p in projs) {
      if (p['id'] == _projectId) {
        projMap = p;
        break;
      }
    }
    final name = (projMap?['proyecto'] as String?) ?? '';
    final bytes = await _buildPdfBytes(projectName: name, rows: rows);
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  // ---------- Agrupar / desagrupar ----------
  Future<void> _bulkGroup(List<_BomRow> rows) async {
    if (_selected.isEmpty) return;
    final sel = rows.where((r) => _selected.contains(r.id)).toList();

    final dimCtrl = TextEditingController();
    final groupCtrl = TextEditingController(
      text: 'GRP-${DateFormat('yyMMdd-HHmm').format(DateTime.now())}',
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Agrupar seleccionadas'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: dimCtrl,
              decoration: const InputDecoration(
                labelText: 'Dimensión del grupo (opcional)',
                hintText: 'p.ej. bloque 4x4x4',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: groupCtrl,
              decoration: const InputDecoration(
                labelText: 'Nombre del grupo',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final dim = dimCtrl.text.trim();
    final group = groupCtrl.text.trim().isEmpty ? '-' : groupCtrl.text.trim();

    final batch = FirebaseFirestore.instance.batch();
    for (final r in sel) {
      batch.update(r.ref, {
        if (dim.isNotEmpty) 'nestDim': dim,
        'nestGroup': group,
      });
    }
    await batch.commit();

    if (!mounted) return;
    setState(() => _selected.clear());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Agrupadas ${sel.length} parte(s).')),
    );
  }

  Future<void> _bulkUngroup(List<_BomRow> rows) async {
    if (_selected.isEmpty) return;
    final sel = rows.where((r) => _selected.contains(r.id)).toList();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitar grupo'),
        content: Text('Quitar grupo a ${sel.length} parte(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final batch = FirebaseFirestore.instance.batch();
    for (final r in sel) {
      batch.update(r.ref, {'nestGroup': FieldValue.delete()});
    }
    await batch.commit();

    if (!mounted) return;
    setState(() => _selected.clear());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Grupo eliminado de ${sel.length} parte(s).')),
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BOM del proyecto')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _projects(),
            builder: (context, snap) {
              final projs = snap.data ?? const [];
              return Column(
                children: [
                  DropdownButtonFormField<String>(
                    value: _projectId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Proyecto',
                      border: OutlineInputBorder(),
                    ),
                    items: projs
                        .map(
                          (p) => DropdownMenuItem(
                            value: p['id'] as String,
                            child: Text(p['proyecto'] as String),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() {
                      _projectId = v;
                      _selected.clear();
                    }),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Buscar Nº de parte o descripción',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) =>
                        setState(() => _search = v.trim().toUpperCase()),
                  ),
                  const SizedBox(height: 10),

                  Expanded(
                    child: FutureBuilder<List<_MaterialDoc>>(
                      future: _materialsFuture,
                      builder: (context, matSnap) {
                        final mats = matSnap.data ?? const <_MaterialDoc>[];
                        return FutureBuilder<List<_SupplierDoc>>(
                          future: _suppliersFuture,
                          builder: (context, supSnap) {
                            final sups = supSnap.data ?? const <_SupplierDoc>[];

                            return StreamBuilder<List<_PartDoc>>(
                              stream: _partsStream(),
                              builder: (context, partsSnap) {
                                final parts =
                                    partsSnap.data ?? const <_PartDoc>[];
                                if (_projectId == null) {
                                  return const Center(
                                    child: Text('Elige un proyecto'),
                                  );
                                }
                                if (partsSnap.connectionState !=
                                    ConnectionState.active) {
                                  return const Center(
                                    child: CircularProgressIndicator(),
                                  );
                                }

                                return StreamBuilder<Map<String, int>>(
                                  stream: _assignedByPart(),
                                  builder: (context, assignSnap) {
                                    final assigned =
                                        assignSnap.data ??
                                        const <String, int>{};

                                    // Fusionar info + material/proveedor label
                                    List<_BomRow> rows = parts.map((p) {
                                      final asign =
                                          assigned[p.docRef.path] ?? 0;

                                      // Material label/color
                                      String matLabel = '';
                                      String? matColor;
                                      if (p.materialCode.isNotEmpty) {
                                        final m = mats.firstWhere(
                                          (x) => x.code == p.materialCode,
                                          orElse: () => _MaterialDoc.empty(),
                                        );
                                        if (m.isValid) {
                                          matLabel = '${m.code} · ${m.desc}';
                                          matColor = m.colorHex;
                                        } else {
                                          matLabel = p.materialCode;
                                        }
                                      } else if (p.materialRef != null) {
                                        final m = mats.firstWhere(
                                          (x) =>
                                              x.ref.path == p.materialRef!.path,
                                          orElse: () => _MaterialDoc.empty(),
                                        );
                                        if (m.isValid) {
                                          matLabel = '${m.code} · ${m.desc}';
                                          matColor = m.colorHex;
                                        }
                                      }

                                      // Proveedor a mostrar
                                      String prov = p.proveedorTexto.trim();
                                      final match = (p.supplierRef != null)
                                          ? sups.firstWhere(
                                              (s) =>
                                                  s.ref.path ==
                                                  p.supplierRef!.path,
                                              orElse: () =>
                                                  _SupplierDoc.empty(),
                                            )
                                          : _SupplierDoc.empty();
                                      if (match.isValid) prov = match.name;

                                      return _BomRow(
                                        id: p.id,
                                        numero: p.numero,
                                        descr: p.descr,
                                        plan: p.plan,
                                        asignada: asign,
                                        nestDim: p.nestDim,
                                        nestGroup: p.nestGroup,
                                        materialLabel: matLabel,
                                        materialColorHex: matColor,
                                        materialComprado: p.materialComprado,
                                        materialCompradoFecha:
                                            p.materialCompradoFecha,
                                        proveedorMostrar: prov,
                                        ref: p.docRef,
                                      );
                                    }).toList();

                                    if (_search.isNotEmpty) {
                                      rows = rows
                                          .where(
                                            (r) =>
                                                r.numero.toUpperCase().contains(
                                                  _search,
                                                ) ||
                                                r.descr.toUpperCase().contains(
                                                  _search,
                                                ),
                                          )
                                          .toList();
                                    }
                                    if (_onlyMaterialPending.value) {
                                      rows.removeWhere(
                                        (r) => r.materialComprado,
                                      );
                                    }
                                    if (_onlyPurchasePending.value) {
                                      rows.removeWhere(
                                        (r) => r.materialComprado == true,
                                      );
                                    }

                                    final totalPlan = rows.fold<int>(
                                      0,
                                      (a, b) => a + b.plan,
                                    );
                                    final totalAsign = rows.fold<int>(
                                      0,
                                      (a, b) => a + b.asignada,
                                    );

                                    final hasSelection = _selected.isNotEmpty;

                                    return Column(
                                      children: [
                                        // Totales + acciones
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                'Total plan: $totalPlan  •  Asignada: $totalAsign',
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: Wrap(
                                                spacing: 6,
                                                runSpacing: 6,
                                                children: [
                                                  OutlinedButton.icon(
                                                    style:
                                                        OutlinedButton.styleFrom(
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                        ),
                                                    onPressed: () =>
                                                        _printPdf(rows),
                                                    icon: const Icon(
                                                      Icons
                                                          .picture_as_pdf_outlined,
                                                    ),
                                                    label: const Text(
                                                      'Imprimir PDF',
                                                    ),
                                                  ),
                                                  OutlinedButton.icon(
                                                    style:
                                                        OutlinedButton.styleFrom(
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                        ),
                                                    onPressed: () =>
                                                        _copyCsv(rows),
                                                    icon: const Icon(
                                                      Icons.copy,
                                                    ),
                                                    label: const Text(
                                                      'Copiar CSV',
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),

                                        // Semáforo
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: Wrap(
                                            spacing: 8,
                                            runSpacing: 6,
                                            children: [
                                              _chip(
                                                'OK ${rows.where((r) => r.asignada >= r.plan).length}',
                                                color: Colors.green.withOpacity(
                                                  .12,
                                                ),
                                                textColor:
                                                    Colors.green.shade800,
                                              ),
                                              _chip(
                                                'Parcial ${rows.where((r) => r.asignada > 0 && r.asignada < r.plan).length}',
                                                color: Colors.orange
                                                    .withOpacity(.12),
                                                textColor:
                                                    Colors.orange.shade800,
                                              ),
                                              _chip(
                                                'Sin asignar ${rows.where((r) => r.asignada == 0).length}',
                                                color: Colors.red.withOpacity(
                                                  .12,
                                                ),
                                                textColor: Colors.red.shade800,
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 8),

                                        // Filtros
                                        Row(
                                          children: [
                                            Expanded(
                                              child: ValueListenableBuilder<bool>(
                                                valueListenable:
                                                    _onlyMaterialPending,
                                                builder: (_, v, __) =>
                                                    CheckboxListTile(
                                                      dense: true,
                                                      contentPadding:
                                                          EdgeInsets.zero,
                                                      value: v,
                                                      onChanged: (nv) => setState(
                                                        () =>
                                                            _onlyMaterialPending
                                                                    .value =
                                                                nv ?? false,
                                                      ),
                                                      title: const Text(
                                                        'Sólo material pendiente',
                                                      ),
                                                      controlAffinity:
                                                          ListTileControlAffinity
                                                              .leading,
                                                    ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: ValueListenableBuilder<bool>(
                                                valueListenable:
                                                    _onlyPurchasePending,
                                                builder: (_, v, __) =>
                                                    CheckboxListTile(
                                                      dense: true,
                                                      contentPadding:
                                                          EdgeInsets.zero,
                                                      value: v,
                                                      onChanged: (nv) => setState(
                                                        () =>
                                                            _onlyPurchasePending
                                                                    .value =
                                                                nv ?? false,
                                                      ),
                                                      title: const Text(
                                                        'Sólo pendiente de compra',
                                                      ),
                                                      controlAffinity:
                                                          ListTileControlAffinity
                                                              .leading,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),

                                        // Agrupado
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: Wrap(
                                            spacing: 8,
                                            children: [
                                              ElevatedButton.icon(
                                                onPressed: hasSelection
                                                    ? () => _bulkGroup(rows)
                                                    : null,
                                                icon: const Icon(
                                                  Icons.group_add,
                                                ),
                                                label: const Text(
                                                  'Agrupar seleccionadas',
                                                ),
                                              ),
                                              OutlinedButton.icon(
                                                onPressed: hasSelection
                                                    ? () => _bulkUngroup(rows)
                                                    : null,
                                                icon: const Icon(
                                                  Icons.group_off,
                                                ),
                                                label: const Text(
                                                  'Quitar grupo',
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 8),

                                        Expanded(
                                          child: rows.isEmpty
                                              ? const Center(
                                                  child: Text(
                                                    'BOM vacío con los filtros actuales.',
                                                  ),
                                                )
                                              : ListView.separated(
                                                  itemCount: rows.length,
                                                  separatorBuilder: (_, __) =>
                                                      const SizedBox(
                                                        height: 10,
                                                      ),
                                                  itemBuilder: (_, i) =>
                                                      _itemCard(rows[i], mats),
                                                ),
                                        ),
                                      ],
                                    );
                                  },
                                );
                              },
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _itemCard(_BomRow r, List<_MaterialDoc> mats) {
    final isSelected = _selected.contains(r.id);
    final Color? materialColor = _parseColorHex(r.materialColorHex);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // check + título + editar
            Row(
              children: [
                Checkbox(
                  value: isSelected,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selected.add(r.id);
                      } else {
                        _selected.remove(r.id);
                      }
                    });
                  },
                ),
                Expanded(
                  child: Text(
                    r.numero,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Editar',
                  onPressed: () => _editPart(r, mats),
                  icon: const Icon(Icons.edit),
                ),
              ],
            ),
            if (r.descr.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: Text(
                  r.descr,
                  style: const TextStyle(color: Colors.black87),
                ),
              ),

            // Chips plan/asign/faltan + grupo
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 6, right: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _chipPlan(r.plan),
                  _chipAsign(r.plan, r.asignada),
                  _chipFaltante(r.plan, r.asignada),
                  if (r.nestGroup.trim().isNotEmpty)
                    _chip(
                      'Grupo: ${r.nestGroup}',
                      color: Colors.indigo.withOpacity(.08),
                      textColor: Colors.indigo.shade700,
                    ),
                ],
              ),
            ),

            // Estatus COMPRA + proveedor
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _chip(
                    r.materialComprado ? 'Comprado' : 'Pendiente',
                    color: (r.materialComprado ? Colors.green : Colors.red)
                        .withOpacity(.12),
                    textColor: r.materialComprado
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                  ),
                  if (r.materialComprado && r.materialCompradoFecha != null)
                    _chip(
                      DateFormat(
                        'yyyy-MM-dd',
                      ).format(r.materialCompradoFecha!.toDate()),
                      color: Colors.blueGrey.withOpacity(.10),
                      textColor: Colors.blueGrey.shade800,
                    ),
                  if (r.proveedorMostrar.trim().isNotEmpty)
                    _chip(
                      'Proveedor: ${r.proveedorMostrar}',
                      color: Colors.blueGrey.withOpacity(.10),
                      textColor: Colors.blueGrey.shade800,
                    ),
                ],
              ),
            ),

            // Material + Dimensión
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (r.materialLabel.isNotEmpty)
                    Row(
                      children: [
                        if (materialColor != null)
                          Container(
                            width: 10,
                            height: 10,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: materialColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            'Material: ${r.materialLabel}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  if (r.nestDim.trim().isNotEmpty)
                    Text(
                      'Dimensión: ${r.nestDim}',
                      style: const TextStyle(color: Colors.black87),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Editar ----------
  Future<void> _editPart(_BomRow r, List<_MaterialDoc> mats) async {
    final dimCtrl = TextEditingController(text: r.nestDim);

    // material seleccionado (trata de encontrar por label)
    String? materialId;
    if (r.materialLabel.isNotEmpty) {
      final found = mats.firstWhere(
        (m) => '${m.code} · ${m.desc}' == r.materialLabel,
        orElse: () => _MaterialDoc.empty(),
      );
      materialId = found.isValid ? found.id : null;
    }

    bool comprado = r.materialComprado;
    Timestamp? fecha = r.materialCompradoFecha;

    // catálogo de proveedores
    final proveedores = await _suppliersFuture;
    String? supplierId;
    final match = proveedores.firstWhere(
      (s) => s.name.toLowerCase() == r.proveedorMostrar.toLowerCase(),
      orElse: () => _SupplierDoc.empty(),
    );
    if (match.isValid) supplierId = match.id;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              top: 8,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    r.numero,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Dimensión
                  TextField(
                    controller: dimCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Dimensión / Nesting',
                      hintText: 'p.ej. bloque 4x4x4',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Material
                  DropdownButtonFormField<String>(
                    value: materialId,
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('— Material —'),
                      ),
                      ...mats.map(
                        (m) => DropdownMenuItem<String>(
                          value: m.id,
                          child: Text('${m.code} · ${m.desc}'),
                        ),
                      ),
                    ],
                    onChanged: (v) => materialId = v,
                    decoration: const InputDecoration(
                      labelText: 'Material',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Estatus de COMPRA
                  SwitchListTile.adaptive(
                    title: const Text('Material comprado'),
                    value: comprado,
                    onChanged: (v) => setState(() => comprado = v),
                  ),
                  if (comprado) ...[
                    DropdownButtonFormField<String>(
                      value: supplierId,
                      isExpanded: true,
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('— Seleccionar proveedor —'),
                        ),
                        ...proveedores.map(
                          (s) => DropdownMenuItem<String>(
                            value: s.id,
                            child: Text(s.name),
                          ),
                        ),
                      ],
                      onChanged: (v) => supplierId = v,
                      decoration: const InputDecoration(
                        labelText: 'Proveedor',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        fecha == null
                            ? 'Fecha de compra: (toca para elegir)'
                            : 'Fecha de compra: ${DateFormat('yyyy-MM-dd').format(fecha!.toDate())}',
                      ),
                      trailing: const Icon(Icons.event),
                      onTap: () async {
                        final now = DateTime.now();
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: fecha?.toDate() ?? now,
                          firstDate: DateTime(now.year - 5),
                          lastDate: DateTime(now.year + 5),
                        );
                        if (picked != null) {
                          setState(() => fecha = Timestamp.fromDate(picked));
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 14),

                  FilledButton.icon(
                    onPressed: () async {
                      try {
                        final data = <String, dynamic>{
                          'nestDim': dimCtrl.text.trim(),
                          'materialComprado': comprado,
                          'materialCompradoFecha': comprado ? fecha : null,
                        };

                        // material
                        if (materialId == null) {
                          data['materialRef'] = FieldValue.delete();
                          data['materialCode'] = FieldValue.delete();
                        } else {
                          final matRef = FirebaseFirestore.instance
                              .collection('materials')
                              .doc(materialId);
                          final matSnap = await matRef.get();
                          data['materialRef'] = matRef;
                          data['materialCode'] = (matSnap.data()?['code'] ?? '')
                              .toString();
                        }

                        // proveedor (sólo si comprado)
                        if (comprado && supplierId != null) {
                          final supRef = FirebaseFirestore.instance
                              .collection('suppliers')
                              .doc(supplierId);
                          final supSnap = await supRef.get();
                          final supName = (supSnap.data()?['name'] ?? '')
                              .toString();
                          data['supplierRef'] = supRef;
                          data['proveedor'] = supName; // opcional, fácil export
                        } else {
                          data['supplierRef'] = FieldValue.delete();
                          data['proveedor'] = FieldValue.delete();
                        }

                        await r.ref.update(data);
                        if (mounted) Navigator.pop(ctx);
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error al guardar: $e')),
                        );
                      }
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('Guardar'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------- Helpers de UI ----------
  Widget _chip(String text, {Color? color, Color? textColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color ?? Colors.grey.shade200,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: textColor ?? Colors.black87,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _ratioColor({required int plan, required int asign}) {
    if (plan <= 0) return Colors.grey.shade500;
    if (asign >= plan) return Colors.green.shade700;
    if (asign > 0) return Colors.orange.shade700;
    return Colors.red.shade700;
  }

  Widget _chipPlan(int plan) =>
      _chip('Plan $plan', color: Colors.blueGrey.shade50);

  Widget _chipAsign(int plan, int asign) {
    final c = _ratioColor(plan: plan, asign: asign);
    return _chip('Asign. $asign', color: c.withOpacity(.12), textColor: c);
  }

  Widget _chipFaltante(int plan, int asign) {
    final falt = (plan - asign).clamp(0, 1 << 31);
    final c = falt == 0 ? Colors.green.shade700 : Colors.red.shade700;
    return _chip('Faltan $falt', color: c.withOpacity(.12), textColor: c);
  }

  Color? _parseColorHex(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final clean = hex.replaceFirst('#', '');
    if (clean.length != 6 && clean.length != 8) return null;
    final value = int.tryParse(
      clean.length == 6 ? 'FF$clean' : clean,
      radix: 16,
    );
    if (value == null) return null;
    return Color(value);
  }
}

// ------- Models -------
class _PartDoc {
  final String id;
  final String numero;
  final String descr;
  final int plan;
  final String nestDim;
  final bool materialComprado;
  final Timestamp? materialCompradoFecha;
  final String materialCode;
  final DocumentReference? materialRef;
  final String proveedorTexto;
  final DocumentReference? supplierRef;
  final String nestGroup;
  final DocumentReference docRef;

  _PartDoc({
    required this.id,
    required this.numero,
    required this.descr,
    required this.plan,
    required this.nestDim,
    required this.materialComprado,
    required this.materialCompradoFecha,
    required this.materialCode,
    required this.materialRef,
    required this.proveedorTexto,
    required this.supplierRef,
    required this.nestGroup,
    required this.docRef,
  });
}

class _BomRow {
  final String id;
  final String numero;
  final String descr;
  final int plan;
  final int asignada;
  final String nestDim;
  final String nestGroup;
  final String materialLabel;
  final String? materialColorHex;
  final bool materialComprado;
  final Timestamp? materialCompradoFecha;
  final String proveedorMostrar;
  final DocumentReference ref;

  _BomRow({
    required this.id,
    required this.numero,
    required this.descr,
    required this.plan,
    required this.asignada,
    required this.nestDim,
    required this.nestGroup,
    required this.materialLabel,
    required this.materialColorHex,
    required this.materialComprado,
    required this.materialCompradoFecha,
    required this.proveedorMostrar,
    required this.ref,
  });
}

class _MaterialDoc {
  final String id;
  final String code;
  final String desc;
  final String colorHex;
  final DocumentReference ref;
  const _MaterialDoc({
    required this.id,
    required this.code,
    required this.desc,
    required this.colorHex,
    required this.ref,
  });
  static _MaterialDoc empty() => _MaterialDoc(
    id: '',
    code: '',
    desc: '',
    colorHex: '',
    ref: FirebaseFirestore.instance.doc('_/x'),
  );
  bool get isValid => id.isNotEmpty;
}

class _SupplierDoc {
  final String id;
  final String name;
  final DocumentReference ref;
  const _SupplierDoc({required this.id, required this.name, required this.ref});
  static _SupplierDoc empty() => _SupplierDoc(
    id: '',
    name: '',
    ref: FirebaseFirestore.instance.doc('_/x'),
  );
  bool get isValid => id.isNotEmpty;
}
