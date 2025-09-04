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
  final _onlyNestingPending = ValueNotifier<bool>(false);

  /// selección para agrupar / desagrupar
  final Set<String> _selected = <String>{};

  // ---------- Data ----------
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
              nesting: (m['nesting'] ?? '').toString(),
              nestStatus: (m['nestStatus'] ?? 'pendiente').toString(),
              materialComprado: (m['materialComprado'] ?? false) == true,
              materialCompradoFecha: m['materialCompradoFecha'] is Timestamp
                  ? (m['materialCompradoFecha'] as Timestamp)
                  : null,
              proveedor: (m['proveedor'] ?? '').toString(),
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
      'nesting',
      'nestGroup',
      'nestStatus',
      'materialComprado',
      'materialCompradoFecha',
      'proveedor',
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
          r.nesting.replaceAll(',', ' '),
          r.nestGroup.replaceAll(',', ' '),
          r.nestStatus,
          r.materialComprado ? 'SI' : 'NO',
          r.materialCompradoFecha == null
              ? ''
              : DateFormat(
                  'yyyy-MM-dd',
                ).format(r.materialCompradoFecha!.toDate()),
          r.proveedor.replaceAll(',', ' '),
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
          pw.TableHelper.fromTextArray(
            headerStyle: h,
            cellStyle: n,
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            columnWidths: const {
              0: pw.FixedColumnWidth(90),
              1: pw.FlexColumnWidth(2),
              2: pw.FixedColumnWidth(30),
              3: pw.FixedColumnWidth(38),
              4: pw.FixedColumnWidth(38),
              5: pw.FlexColumnWidth(2),
              6: pw.FixedColumnWidth(55),
              7: pw.FixedColumnWidth(60),
              8: pw.FixedColumnWidth(70),
              9: pw.FixedColumnWidth(64),
            },
            headers: [
              'P/N',
              'Descripción',
              'Plan',
              'Asign.',
              'Faltan',
              'Nesting',
              'Grupo',
              'Estatus',
              'Material',
              'Proveedor',
            ],
            data: rows.map((r) {
              final falt = (r.plan - r.asignada).clamp(0, 1 << 31);
              final mat = r.materialComprado
                  ? (r.materialCompradoFecha == null
                        ? 'Comprado'
                        : 'Comprado ${DateFormat('yyyy-MM-dd').format(r.materialCompradoFecha!.toDate())}')
                  : 'Pendiente';
              return [
                r.numero,
                r.descr,
                r.plan.toString(),
                r.asignada.toString(),
                '$falt',
                r.nesting,
                r.nestGroup,
                _statusLabel(r.nestStatus),
                mat,
                r.proveedor,
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

    final nestingCtrl = TextEditingController();
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
              controller: nestingCtrl,
              decoration: const InputDecoration(
                labelText: 'Nesting del grupo',
                hintText: 'p.ej. bloque 4x4x4 / A36',
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

    final nesting = nestingCtrl.text.trim();
    final group = groupCtrl.text.trim().isEmpty ? '-' : groupCtrl.text.trim();

    final batch = FirebaseFirestore.instance.batch();
    for (final r in sel) {
      batch.update(r.ref, {
        if (nesting.isNotEmpty) 'nesting': nesting,
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
                    child: StreamBuilder<List<_PartDoc>>(
                      stream: _partsStream(),
                      builder: (context, partsSnap) {
                        final parts = partsSnap.data ?? const <_PartDoc>[];
                        if (_projectId == null) {
                          return const Center(child: Text('Elige un proyecto'));
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
                                assignSnap.data ?? const <String, int>{};

                            List<_BomRow> rows = parts.map((p) {
                              final asign = assigned[p.docRef.path] ?? 0;
                              return _BomRow(
                                id: p.id,
                                numero: p.numero,
                                descr: p.descr,
                                plan: p.plan,
                                asignada: asign,
                                nesting: p.nesting,
                                nestGroup: p.nestGroup,
                                nestStatus: p.nestStatus,
                                materialComprado: p.materialComprado,
                                materialCompradoFecha: p.materialCompradoFecha,
                                proveedor: p.proveedor,
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
                                        r.descr.toUpperCase().contains(_search),
                                  )
                                  .toList();
                            }
                            if (_onlyMaterialPending.value) {
                              rows.removeWhere((r) => r.materialComprado);
                            }
                            if (_onlyNestingPending.value) {
                              rows.removeWhere(
                                (r) => r.nestStatus == 'completo',
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
                                // Totales + acciones principales
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
                                            style: OutlinedButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                            ),
                                            onPressed: () => _printPdf(rows),
                                            icon: const Icon(
                                              Icons.picture_as_pdf_outlined,
                                            ),
                                            label: const Text('Imprimir PDF'),
                                          ),
                                          OutlinedButton.icon(
                                            style: OutlinedButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                            ),
                                            onPressed: () => _copyCsv(rows),
                                            icon: const Icon(Icons.copy),
                                            label: const Text('Copiar CSV'),
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
                                        color: Colors.green.withOpacity(.12),
                                        textColor: Colors.green.shade800,
                                      ),
                                      _chip(
                                        'Parcial ${rows.where((r) => r.asignada > 0 && r.asignada < r.plan).length}',
                                        color: Colors.orange.withOpacity(.12),
                                        textColor: Colors.orange.shade800,
                                      ),
                                      _chip(
                                        'Sin asignar ${rows.where((r) => r.asignada == 0).length}',
                                        color: Colors.red.withOpacity(.12),
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
                                        valueListenable: _onlyMaterialPending,
                                        builder: (_, v, __) => CheckboxListTile(
                                          dense: true,
                                          contentPadding: EdgeInsets.zero,
                                          value: v,
                                          onChanged: (nv) => setState(
                                            () => _onlyMaterialPending.value =
                                                nv ?? false,
                                          ),
                                          title: const Text(
                                            'Sólo material pendiente',
                                          ),
                                          controlAffinity:
                                              ListTileControlAffinity.leading,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: ValueListenableBuilder<bool>(
                                        valueListenable: _onlyNestingPending,
                                        builder: (_, v, __) => CheckboxListTile(
                                          dense: true,
                                          contentPadding: EdgeInsets.zero,
                                          value: v,
                                          onChanged: (nv) => setState(
                                            () => _onlyNestingPending.value =
                                                nv ?? false,
                                          ),
                                          title: const Text(
                                            'Sólo nesting pendiente/en proceso',
                                          ),
                                          controlAffinity:
                                              ListTileControlAffinity.leading,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),

                                // Botones de agrupado (solo si hay selección)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Wrap(
                                    spacing: 8,
                                    children: [
                                      ElevatedButton.icon(
                                        onPressed: hasSelection
                                            ? () => _bulkGroup(rows)
                                            : null,
                                        icon: const Icon(Icons.group_add),
                                        label: const Text(
                                          'Agrupar seleccionadas',
                                        ),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: hasSelection
                                            ? () => _bulkUngroup(rows)
                                            : null,
                                        icon: const Icon(Icons.group_off),
                                        label: const Text('Quitar grupo'),
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
                                              const SizedBox(height: 10),
                                          itemBuilder: (_, i) =>
                                              _itemCard(rows[i]),
                                        ),
                                ),
                              ],
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

  // ---------- UI helpers ----------
  Widget _itemCard(_BomRow r) {
    final isSelected = _selected.contains(r.id);
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
                  onPressed: () => _editPart(r),
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

            // Chips plan/asign/faltan
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

            // Estatus + material + proveedor + nesting
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _chip(
                    _statusLabel(r.nestStatus),
                    color: _statusColor(r.nestStatus).withOpacity(.12),
                    textColor: _statusColor(r.nestStatus),
                  ),
                  _chip(
                    r.materialComprado
                        ? (r.materialCompradoFecha == null
                              ? 'Material: Comprado'
                              : 'Material: Comprado ${DateFormat('yyyy-MM-dd').format(r.materialCompradoFecha!.toDate())}')
                        : 'Material: Pendiente',
                    color: (r.materialComprado ? Colors.green : Colors.red)
                        .withOpacity(.12),
                    textColor: r.materialComprado
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                  ),
                  if (r.proveedor.trim().isNotEmpty)
                    _chip(
                      'Proveedor: ${r.proveedor.trim()}',
                      color: Colors.blueGrey.withOpacity(.10),
                      textColor: Colors.blueGrey.shade800,
                    ),
                ],
              ),
            ),
            if (r.nesting.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 2),
                child: Text(
                  'Nesting: ${r.nesting}',
                  style: const TextStyle(color: Colors.black87),
                ),
              ),
          ],
        ),
      ),
    );
  }

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

  static String _statusLabel(String s) {
    switch (s) {
      case 'completo':
        return 'Completo';
      case 'en proceso':
        return 'En proceso';
      default:
        return 'Pendiente';
    }
  }

  static Color _statusColor(String s) {
    switch (s) {
      case 'completo':
        return Colors.green.shade700;
      case 'en proceso':
        return Colors.orange.shade700;
      default:
        return Colors.red.shade700;
    }
  }

  Future<void> _editPart(_BomRow r) async {
    final nestingCtrl = TextEditingController(text: r.nesting);
    final groupCtrl = TextEditingController(text: r.nestGroup);
    String status = r.nestStatus;
    bool comprado = r.materialComprado;
    Timestamp? fecha = r.materialCompradoFecha;
    final proveedorCtrl = TextEditingController(text: r.proveedor);

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
                  TextField(
                    controller: nestingCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nesting (p.ej. bloque 4x4x4 / A36)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: groupCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nombre de grupo (opcional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: status,
                    items: const [
                      DropdownMenuItem(
                        value: 'pendiente',
                        child: Text('Pendiente'),
                      ),
                      DropdownMenuItem(
                        value: 'en proceso',
                        child: Text('En proceso'),
                      ),
                      DropdownMenuItem(
                        value: 'completo',
                        child: Text('Completo'),
                      ),
                    ],
                    onChanged: (v) => status = v ?? 'pendiente',
                    decoration: const InputDecoration(
                      labelText: 'Estatus nesting',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    title: const Text('Material comprado'),
                    value: comprado,
                    onChanged: (v) => setState(() => comprado = v),
                  ),
                  if (comprado) ...[
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
                    const SizedBox(height: 6),
                    TextField(
                      controller: proveedorCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Proveedor',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: () async {
                      try {
                        await r.ref.update({
                          'nesting': nestingCtrl.text.trim(),
                          'nestGroup': groupCtrl.text.trim(),
                          'nestStatus': status,
                          'materialComprado': comprado,
                          'materialCompradoFecha': comprado ? fecha : null,
                          'proveedor': comprado
                              ? proveedorCtrl.text.trim()
                              : '',
                        });
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
}

// ------- Models -------
class _PartDoc {
  final String id;
  final String numero;
  final String descr;
  final int plan;
  final String nesting;
  final String nestStatus;
  final bool materialComprado;
  final Timestamp? materialCompradoFecha;
  final String proveedor;
  final String nestGroup;
  final DocumentReference docRef;

  _PartDoc({
    required this.id,
    required this.numero,
    required this.descr,
    required this.plan,
    required this.nesting,
    required this.nestStatus,
    required this.materialComprado,
    required this.materialCompradoFecha,
    required this.proveedor,
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
  final String nesting;
  final String nestGroup;
  final String nestStatus;
  final bool materialComprado;
  final Timestamp? materialCompradoFecha;
  final String proveedor;
  final DocumentReference ref;

  _BomRow({
    required this.id,
    required this.numero,
    required this.descr,
    required this.plan,
    required this.asignada,
    required this.nesting,
    required this.nestGroup,
    required this.nestStatus,
    required this.materialComprado,
    required this.materialCompradoFecha,
    required this.proveedor,
    required this.ref,
  });
}
