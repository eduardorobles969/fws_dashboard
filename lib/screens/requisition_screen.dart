// lib/screens/requisition_screen.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class RequisitionScreen extends StatefulWidget {
  const RequisitionScreen({super.key});

  @override
  State<RequisitionScreen> createState() => _RequisitionScreenState();
}

class _RequisitionScreenState extends State<RequisitionScreen> {
  final _formKey = GlobalKey<FormState>();

  // Encabezado
  final TextEditingController _requisitorCtrl = TextEditingController();
  String? _projectId;
  String? _projectName;
  DateTime? _deadline;

  // Filas (arranca con 1)
  final List<_ReqRow> _rows = [_ReqRow()];

  @override
  void initState() {
    super.initState();
    final u = FirebaseAuth.instance.currentUser;
    _requisitorCtrl.text = (u?.displayName ?? u?.email ?? '').trim();
  }

  @override
  void dispose() {
    _requisitorCtrl.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  // ---------------------- DATA ----------------------
  Future<List<Map<String, String>>> _projects() async {
    final qs = await FirebaseFirestore.instance
        .collection('projects')
        .where('activo', isEqualTo: true)
        .orderBy('proyecto')
        .get();

    return qs.docs
        .map((d) => {'id': d.id, 'name': (d['proyecto'] ?? '').toString()})
        .toList();
  }

  /// Picker de materiales (lee /materials activos y ordena en cliente)
  Future<Map<String, String>?> _pickMaterial() async {
    try {
      final qs = await FirebaseFirestore.instance
          .collection('materials')
          .where('active', isEqualTo: true)
          .limit(500)
          .get();

      final all = qs.docs.map((d) {
        final m = d.data();
        final code = (m['code'] ?? '').toString();
        final desc = (m['desc'] ?? '').toString();
        final sort = (m['sort'] ?? 999999);
        return <String, dynamic>{
          'id': d.id,
          'code': code,
          'desc': desc,
          'sort': sort,
        };
      }).toList();

      // ordena por sort -> code -> desc
      all.sort((a, b) {
        final sa = (a['sort'] is int) ? a['sort'] as int : 999999;
        final sb = (b['sort'] is int) ? b['sort'] as int : 999999;
        final s = sa.compareTo(sb);
        if (s != 0) return s;
        final ca = (a['code'] ?? '') as String;
        final cb = (b['code'] ?? '') as String;
        final c = ca.compareTo(cb);
        if (c != 0) return c;
        return ((a['desc'] ?? '') as String).compareTo(
          (b['desc'] ?? '') as String,
        );
      });

      if (!mounted) return null;

      final txt = TextEditingController();
      List<Map<String, dynamic>> filtered = List.of(all);

      return await showModalBottomSheet<Map<String, String>>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 8,
              bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: txt,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Buscar código o descripción…',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    final t = v.trim().toLowerCase();
                    filtered = all.where((m) {
                      final code = (m['code'] ?? '').toString().toLowerCase();
                      final desc = (m['desc'] ?? '').toString().toLowerCase();
                      return code.contains(t) || desc.contains(t);
                    }).toList();
                    (context as Element).markNeedsBuild();
                  },
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: Card(
                    elevation: 1.5,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final m = filtered[i];
                        final code = (m['code'] ?? '').toString();
                        final desc = (m['desc'] ?? '').toString();
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.category_outlined),
                          title: Text(code),
                          subtitle: Text(desc),
                          onTap: () => Navigator.pop<Map<String, String>>(
                            context,
                            {'code': code, 'desc': desc},
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
      );
    } catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo cargar materiales: $e')),
      );
      return null;
    }
  }

  // ---------------------- PDF ----------------------
  Future<Uint8List> _buildPdfBytes({
    String? requisitor,
    String? projectName,
    DateTime? deadline,
    List<List<String>>? rowsFromArgs,
  }) async {
    final pdf = pw.Document();

    pw.MemoryImage? logo;
    try {
      final bytes = await rootBundle.load('assets/icon.png');
      logo = pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {}

    String fmtDate(DateTime? d) =>
        d == null ? '' : DateFormat('yyyy-MM-dd').format(d);

    final H = pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold);
    final small = pw.TextStyle(fontSize: 9);
    final cell = pw.TextStyle(fontSize: 10);
    final head = pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold);

    final rows =
        rowsFromArgs ??
        _rows.where((r) => r.hasAny).map((r) {
          return [
            r.qtyCtrl.text.trim(),
            r.unitCtrl.text.trim(),
            [
              r.materialCode ?? '',
              r.materialDesc ?? '',
            ].where((e) => e.isNotEmpty).join(' – '),
            r.descCtrl.text.trim(),
            r.dimCtrl.text.trim(),
            r.supCtrl.text.trim(),
          ];
        }).toList();

    while (rows.length < 12) {
      rows.add(['', '', '', '', '', '']);
    }

    pdf.addPage(
      pw.MultiPage(
        margin: const pw.EdgeInsets.fromLTRB(24, 24, 24, 28),
        build: (ctx) => [
          pw.Container(
            width: double.infinity,
            color: PdfColors.grey300,
            padding: const pw.EdgeInsets.symmetric(vertical: 8),
            child: pw.Center(
              child: pw.Text(
                'REQUISICIÓN DE MATERIALES',
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          ),
          pw.SizedBox(height: 10),

          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (logo != null) pw.Image(logo, width: 54, height: 54),
              pw.SizedBox(width: 10),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('FUSION WELDING SOLUTIONS MEXICO', style: H),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'REPUBLICA DE PANAMÁ 428 INT.12  COL. UNIÓN DE LADRILLEROS, HERMOSILLO, SON',
                      style: small,
                    ),
                    pw.Text('662-688-6174', style: small),
                    pw.Text('compras@fusionwelding.com.mx', style: small),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 10),

          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.black, width: 1),
            columnWidths: {
              0: const pw.FixedColumnWidth(120),
              1: const pw.FlexColumnWidth(),
            },
            children: [
              _headerRow('REQUISITOR', requisitor ?? _requisitorCtrl.text),
              _headerRow('PROYECTO', projectName ?? (_projectName ?? '')),
              _headerRow('FECHA LÍMITE', fmtDate(deadline ?? _deadline)),
            ],
          ),
          pw.SizedBox(height: 12),

          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.black, width: 1),
            columnWidths: const {
              0: pw.FixedColumnWidth(55),
              1: pw.FixedColumnWidth(65),
              2: pw.FlexColumnWidth(2),
              3: pw.FlexColumnWidth(2),
              4: pw.FlexColumnWidth(1.4),
              5: pw.FlexColumnWidth(1.4),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  _cell('Cantidad', head, pad: 6),
                  _cell('Unidad', head, pad: 6),
                  _cell('Material (catálogo)', head, pad: 6),
                  _cell('Descripción', head, pad: 6),
                  _cell('Dimensión', head, pad: 6),
                  _cell('Proveedor(es)', head, pad: 6),
                ],
              ),
              ...rows.map(
                (r) => pw.TableRow(
                  children: [
                    _cell(r[0], cell),
                    _cell(r[1], cell),
                    _cell(r[2], cell),
                    _cell(r[3], cell),
                    _cell(r[4], cell),
                    _cell(r[5], cell),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return pdf.save();
  }

  pw.TableRow _headerRow(String label, String value) => pw.TableRow(
    children: [
      _cell(label, const pw.TextStyle(fontSize: 10), boldLeft: true),
      _cell(value, const pw.TextStyle(fontSize: 11)),
    ],
  );

  pw.Widget _cell(
    String text,
    pw.TextStyle style, {
    double pad = 10,
    bool boldLeft = false,
  }) {
    return pw.Container(
      padding: pw.EdgeInsets.all(pad),
      alignment: pw.Alignment.centerLeft,
      child: pw.Text(
        text,
        style: boldLeft
            ? style.copyWith(fontWeight: pw.FontWeight.bold)
            : style,
      ),
    );
  }

  // ---------------------- SAVE + PDF ----------------------
  Future<void> _saveAndPdf() async {
    if (!_formKey.currentState!.validate()) return;

    if (_projectId != null) {
      final doc = await FirebaseFirestore.instance
          .collection('projects')
          .doc(_projectId)
          .get();
      _projectName = (doc.data()?['proyecto'] ?? '').toString();
    }

    final user = FirebaseAuth.instance.currentUser;

    final items = _rows.where((r) => r.hasAny).map((r) {
      return {
        'qty': r.qtyCtrl.text.trim(),
        'unit': r.unitCtrl.text.trim(),
        'materialCode': r.materialCode ?? '',
        'materialDesc': r.materialDesc ?? '',
        'desc': r.descCtrl.text.trim(),
        'dim': r.dimCtrl.text.trim(),
        'sup': r.supCtrl.text.trim(),
      };
    }).toList();

    final meta = {
      'requisitor': _requisitorCtrl.text.trim(),
      'projectId': _projectId,
      'projectName': _projectName ?? '',
      'deadline': _deadline == null ? null : Timestamp.fromDate(_deadline!),
      'items': items,
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': user?.uid,
      'status': 'borrador',
    };
    final docRef = await FirebaseFirestore.instance
        .collection('requisitions')
        .add(meta);

    final rowsForPdf = items
        .map<List<String>>(
          (m) => [
            (m['qty'] ?? '') as String,
            (m['unit'] ?? '') as String,
            [
              m['materialCode'] ?? '',
              m['materialDesc'] ?? '',
            ].where((e) => (e as String).isNotEmpty).join(' – '),
            (m['desc'] ?? '') as String,
            (m['dim'] ?? '') as String,
            (m['sup'] ?? '') as String,
          ],
        )
        .toList();

    final pdfBytes = await _buildPdfBytes(
      requisitor: meta['requisitor'] as String?,
      projectName: meta['projectName'] as String?,
      deadline: _deadline,
      rowsFromArgs: rowsForPdf,
    );
    await Printing.layoutPdf(onLayout: (_) async => pdfBytes);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Requisición guardada (#${docRef.id.substring(0, 6)})'),
      ),
    );
  }

  Future<void> _printOnly() async {
    final bytes = await _buildPdfBytes();
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  // ---------------------- UI ----------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Requisición de materiales'),
        actions: [
          IconButton(
            tooltip: 'Limpiar',
            onPressed: () {
              setState(() {
                _requisitorCtrl.clear();
                _projectId = null;
                _projectName = null;
                _deadline = null;
                for (final r in _rows) r.dispose();
                _rows
                  ..clear()
                  ..add(_ReqRow());
              });
            },
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
          IconButton(
            tooltip: 'Imprimir / PDF rápido',
            onPressed: _printOnly,
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<Map<String, String>>>(
          future: _projects(),
          builder: (context, snap) {
            final projects = snap.data ?? const <Map<String, String>>[];
            return Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                children: [
                  // Encabezado
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _requisitorCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Requisitor',
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Requerido'
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _projectId,
                          items: projects
                              .map(
                                (p) => DropdownMenuItem<String>(
                                  value: p['id'],
                                  child: Text(p['name']!),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => _projectId = v),
                          decoration: const InputDecoration(
                            labelText: 'Proyecto',
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) =>
                              (v == null || v.isEmpty) ? 'Requerido' : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.event),
                          label: Text(
                            _deadline == null
                                ? 'Fecha límite'
                                : DateFormat('yyyy-MM-dd').format(_deadline!),
                          ),
                          onPressed: () async {
                            final now = DateTime.now();
                            final picked = await showDatePicker(
                              context: context,
                              firstDate: DateTime(now.year - 1),
                              lastDate: DateTime(now.year + 2),
                              initialDate: _deadline ?? now,
                            );
                            if (picked != null) {
                              setState(() => _deadline = picked);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Agregar fila'),
                        onPressed: () => setState(() => _rows.add(_ReqRow())),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Tabla editable (responsiva)
                  _editableTable(),

                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _saveAndPdf,
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Guardar + PDF'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ========= Editable, pero responsivo =========
  Widget _editableTable() {
    final headStyle = Theme.of(context).textTheme.labelMedium;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
        child: Column(
          children: [
            // Encabezados
            LayoutBuilder(
              builder: (context, c) {
                final narrow = c.maxWidth < 420;
                if (narrow) {
                  return Row(
                    children: [
                      _tag('Cant.', headStyle),
                      const SizedBox(width: 8),
                      _tag('Unidad', headStyle),
                      const SizedBox(width: 8),
                      _tag('Material', headStyle),
                    ],
                  );
                }
                return Row(
                  children: [
                    _th('Cant.', flex: 10, style: headStyle),
                    _th('Unidad', flex: 12, style: headStyle),
                    _th('Material (catálogo)', flex: 22, style: headStyle),
                    _th('Descripción', flex: 22, style: headStyle),
                    _th('Dimensión', flex: 16, style: headStyle),
                    _th('Proveedor(es)', flex: 18, style: headStyle),
                    const SizedBox(width: 36),
                  ],
                );
              },
            ),
            const Divider(height: 14),

            // Filas
            ..._rows.asMap().entries.map((e) {
              final i = e.key;
              final r = e.value;

              return LayoutBuilder(
                builder: (context, c) {
                  final narrow = c.maxWidth < 420;

                  if (narrow) {
                    // ----- diseño móvil (2 líneas con Wraps) -----
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _miniBox(
                                width: 88,
                                child: _txt(
                                  r.qtyCtrl,
                                  hint: '0',
                                  numeric: true,
                                ),
                              ),
                              _miniBox(
                                width: 96,
                                child: _txt(r.unitCtrl, hint: 'pza, kg, m'),
                              ),
                              _miniBox(
                                minWidth: 200,
                                child: OutlinedButton.icon(
                                  onPressed: () async {
                                    final picked = await _pickMaterial();
                                    if (picked != null) {
                                      setState(() {
                                        r.materialCode = picked['code'];
                                        r.materialDesc = picked['desc'];
                                      });
                                    }
                                  },
                                  icon: const Icon(Icons.dataset_outlined),
                                  label: Text(
                                    (r.materialCode == null ||
                                            r.materialCode!.isEmpty)
                                        ? 'Elegir material'
                                        : '${r.materialCode} – ${r.materialDesc ?? ''}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _miniBox(
                                minWidth: 220,
                                child: _txt(r.descCtrl, hint: 'Descripción'),
                              ),
                              _miniBox(
                                width: 150,
                                child: _txt(r.dimCtrl, hint: 'Dimensión'),
                              ),
                              _miniBox(
                                minWidth: 180,
                                child: _txt(r.supCtrl, hint: 'Proveedor(es)'),
                              ),
                              IconButton(
                                tooltip: 'Eliminar',
                                onPressed: () {
                                  setState(() {
                                    _rows.removeAt(i).dispose();
                                    if (_rows.isEmpty) _rows.add(_ReqRow());
                                  });
                                },
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }

                  // ----- diseño ancho (flex en una sola fila) -----
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _td(
                          _txt(r.qtyCtrl, hint: '0', numeric: true),
                          flex: 10,
                        ),
                        _td(_txt(r.unitCtrl, hint: 'pza, kg, m'), flex: 12),
                        _td(
                          OutlinedButton.icon(
                            onPressed: () async {
                              final picked = await _pickMaterial();
                              if (picked != null) {
                                setState(() {
                                  r.materialCode = picked['code'];
                                  r.materialDesc = picked['desc'];
                                });
                              }
                            },
                            icon: const Icon(Icons.dataset_outlined),
                            label: Text(
                              (r.materialCode == null ||
                                      r.materialCode!.isEmpty)
                                  ? 'Elegir material'
                                  : '${r.materialCode} – ${r.materialDesc ?? ''}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          flex: 22,
                        ),
                        _td(_txt(r.descCtrl, hint: 'Descripción'), flex: 22),
                        _td(_txt(r.dimCtrl, hint: 'Dimensión'), flex: 16),
                        _td(_txt(r.supCtrl, hint: 'Proveedor(es)'), flex: 18),
                        IconButton(
                          tooltip: 'Eliminar',
                          onPressed: () {
                            setState(() {
                              _rows.removeAt(i).dispose();
                              if (_rows.isEmpty) _rows.add(_ReqRow());
                            });
                          },
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  );
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  // Helpers UI
  Widget _tag(String t, TextStyle? s) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.grey.shade200,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(t, style: s),
  );

  Widget _miniBox({double? width, double? minWidth, required Widget child}) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: minWidth ?? 0,
        maxWidth: width ?? double.infinity,
      ),
      child: child,
    );
  }

  Widget _txt(TextEditingController c, {String? hint, bool numeric = false}) {
    return TextField(
      controller: c,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      maxLines: 3,
      decoration: InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    );
  }

  Widget _th(String text, {int flex = 1, TextStyle? style}) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Text(text, style: style),
    ),
  );

  Widget _td(Widget child, {int flex = 1}) => Expanded(
    flex: flex,
    child: Padding(padding: const EdgeInsets.only(right: 6), child: child),
  );
}

// --------- Modelo de fila editable ---------
class _ReqRow {
  final TextEditingController qtyCtrl = TextEditingController();
  final TextEditingController unitCtrl = TextEditingController();
  final TextEditingController descCtrl =
      TextEditingController(); // descripción libre
  final TextEditingController dimCtrl = TextEditingController(); // dimensión
  final TextEditingController supCtrl = TextEditingController();

  String? materialCode;
  String? materialDesc;

  bool get hasAny =>
      qtyCtrl.text.trim().isNotEmpty ||
      unitCtrl.text.trim().isNotEmpty ||
      (materialCode != null && materialCode!.isNotEmpty) ||
      descCtrl.text.trim().isNotEmpty ||
      dimCtrl.text.trim().isNotEmpty ||
      supCtrl.text.trim().isNotEmpty;

  void dispose() {
    qtyCtrl.dispose();
    unitCtrl.dispose();
    descCtrl.dispose();
    dimCtrl.dispose();
    supCtrl.dispose();
  }
}
