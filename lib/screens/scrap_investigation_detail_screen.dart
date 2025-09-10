// lib/screens/scrap_investigation_detail_screen.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

// PDF / Print
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class ScrapInvestigationDetailScreen extends StatefulWidget {
  final String docId;
  final bool autoPdf;
  const ScrapInvestigationDetailScreen({
    super.key,
    required this.docId,
    this.autoPdf = false,
  });

  @override
  State<ScrapInvestigationDetailScreen> createState() =>
      _ScrapInvestigationDetailScreenState();
}

class _ScrapInvestigationDetailScreenState
    extends State<ScrapInvestigationDetailScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  bool _isAdmin = false;

  DocumentReference<Map<String, dynamic>> get _ref => FirebaseFirestore.instance
      .collection('scrap_investigations')
      .doc(widget.docId);

  String _fmtTs(dynamic ts) =>
      ts is Timestamp ? DateFormat('yyyy-MM-dd HH:mm').format(ts.toDate()) : '';

  // ---------- CARGA DE ROL (admin) ----------
  Future<void> _loadRole() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(u.uid)
          .get();
      final role = (doc.data()?['role'] ?? '').toString();
      if (mounted) setState(() => _isAdmin = (role == 'administrador'));
    } catch (_) {
      // ignora: sin rol => no admin
    }
  }

  // ---------- GUARDAR 5 PORQUÉS ----------
  Future<void> _save5Whys(List<TextEditingController> whysCtrls) async {
    setState(() => _saving = true);
    try {
      await _ref.update({
        'whys': whysCtrls.map((c) => c.text.trim()).toList(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Guardado')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------- GUARDAR 8D ----------
  Future<void> _save8D(Map<String, TextEditingController> ctrls) async {
    setState(() => _saving = true);
    try {
      await _ref.update({
        'd': {
          'd1_equipo': ctrls['d1']!.text.trim(),
          'd2_descripcion': ctrls['d2']!.text.trim(),
          'd3_contencion': ctrls['d3']!.text.trim(),
          'd4_causa_raiz': ctrls['d4']!.text.trim(),
          'd5_acciones_correc': ctrls['d5']!.text.trim(),
          'd6_implementar': ctrls['d6']!.text.trim(),
          'd7_prevenir': ctrls['d7']!.text.trim(),
          'd8_cerrar': ctrls['d8']!.text.trim(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Guardado')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------- CAMBIAR ESTADO (solo admin) ----------
  Future<void> _toggleStatus(String current) async {
    if (!_isAdmin) return;
    final next = current == 'abierta' ? 'cerrada' : 'abierta';
    setState(() => _saving = true);
    try {
      await _ref.update({
        'status': next,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Propagar a evento y producción solo cuando se cierra
      if (next == 'cerrada') {
        await _propagateClose();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------- Al cerrar: propagar a scrap_event y production_daily ----------
  Future<void> _propagateClose() async {
    // 1) Obtener investigación -> eventRef
    final inv = await _ref.get();
    final m = inv.data();
    if (m == null) return;
    final eventRef = m['eventRef'];
    if (eventRef is! DocumentReference) return;

    // 2) Cerrar evento y obtener entryRef + piezas
    final evSnap = await eventRef.get();
    final ev = evSnap.data() as Map<String, dynamic>?;

    await eventRef.update({
      'status': 'cerrado',
      'updatedAt': FieldValue.serverTimestamp(),
    });

    final entryRef = (ev != null) ? ev['entryRef'] : null;
    final piezas = (ev != null)
        ? ((ev['piezas'] is int)
              ? ev['piezas'] as int
              : int.tryParse('${ev['piezas'] ?? 0}') ?? 0)
        : 0;

    if (entryRef is! DocumentReference) return;
    // 3) Actualizar production_daily
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final entrySnap = await tx.get(entryRef as DocumentReference);
      final data = entrySnap.data() as Map<String, dynamic>? ?? {};
      final currentScrap = (data['scrap'] ?? 0) is int
          ? data['scrap'] as int
          : int.tryParse('${data['scrap'] ?? 0}') ?? 0;

      tx.update(entryRef, {
        'scrap': currentScrap + piezas,
        'scrapPendiente': false,
        'scrapAprobado': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _loadRole();

    // Si nos pidieron abrir PDF automáticamente (desde el listado)
    if (widget.autoPdf) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final snap = await _ref.get();
        final data = snap.data();
        if (data != null && mounted) {
          final bytes = await _buildPdfBytes(data);
          await Printing.layoutPdf(onLayout: (_) async => bytes);
        }
      });
    }
  }

  // ---------- D6 verificación ----------
  Future<void> _setD6Verified(bool v) async {
    final u = FirebaseAuth.instance.currentUser;
    await _ref.update({
      'd6_verified': v,
      'd6_verifiedAt': FieldValue.serverTimestamp(),
      if (u != null) ...{
        'd6_verifiedByUid': u.uid,
        'd6_verifiedByEmail': u.email ?? '',
        'd6_verifiedByName': u.displayName ?? '',
      },
    });
  }

  // ---------- D7 rango de vigencia ----------
  Future<void> _pickD7Range(
    Timestamp? startTs,
    Timestamp? endTs,
    BuildContext ctx,
  ) async {
    final now = DateTime.now();
    final initial = DateTimeRange(
      start: startTs?.toDate() ?? now,
      end: endTs?.toDate() ?? now.add(const Duration(days: 30)),
    );
    final picked = await showDateRangePicker(
      context: ctx,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      initialDateRange: initial,
    );
    if (picked == null) return;
    await _ref.update({
      'd7_prev_start': Timestamp.fromDate(
        DateTime(picked.start.year, picked.start.month, picked.start.day, 0, 0),
      ),
      'd7_prev_end': Timestamp.fromDate(
        DateTime(picked.end.year, picked.end.month, picked.end.day, 23, 59, 59),
      ),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ================== PDF ==================
  // Checkbox dibujado (sin emojis/wingdings)
  pw.Widget _pdfCheck({required bool checked}) {
    return pw.Container(
      width: 12,
      height: 12,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey700, width: 1),
      ),
      child: checked
          ? pw.Text('X', style: const pw.TextStyle(fontSize: 9))
          : null,
    );
  }

  Future<Uint8List> _buildPdfBytes(Map<String, dynamic> m) async {
    // Logo
    pw.MemoryImage? logo;
    try {
      final bytes = await rootBundle.load('assets/icon.png');
      logo = pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {
      logo = null;
    }

    final pdf = pw.Document();

    final f10 = pw.TextStyle(fontSize: 10);
    final f11 = pw.TextStyle(fontSize: 11);
    final f12b = pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold);
    final f18b = pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold);

    final method = (m['method'] ?? '').toString();
    final proyecto = (m['proyecto'] ?? '—').toString();
    final parte = (m['numeroParte'] ?? '—').toString();
    final op = (m['operacionNombre'] ?? '').toString();

    // Cuerpo tabla
    List<List<String>> body = [];
    if (method == '5whys') {
      final whys = (m['whys'] is List)
          ? (m['whys'] as List)
          : List.filled(5, '');
      for (int i = 0; i < 5; i++) {
        body.add(['¿Por qué ${i + 1}?', '${i < whys.length ? whys[i] : ''}']);
      }
    } else {
      final d = (m['d'] ?? {}) as Map<String, dynamic>;
      body = [
        ['D1. Equipo', '${d['d1_equipo'] ?? ''}'],
        ['D2. Descripción', '${d['d2_descripcion'] ?? ''}'],
        ['D3. Contención', '${d['d3_contencion'] ?? ''}'],
        ['D4. Causa raíz', '${d['d4_causa_raiz'] ?? ''}'],
        ['D5. Acciones correctivas', '${d['d5_acciones_correc'] ?? ''}'],
        ['D6. Implementación', '${d['d6_implementar'] ?? ''}'],
        ['D7. Prevención', '${d['d7_prevenir'] ?? ''}'],
        ['D8. Cierre', '${d['d8_cerrar'] ?? ''}'],
      ];
    }

    // D6/D7
    final d6Verified = (m['d6_verified'] ?? false) as bool;
    final d6Who = (m['d6_verifiedByName'] ?? m['d6_verifiedByEmail'] ?? '')
        .toString();
    final d6When = _fmtTs(m['d6_verifiedAt']);
    final d7Start = _fmtTs(m['d7_prev_start']);
    final d7End = _fmtTs(m['d7_prev_end']);

    pdf.addPage(
      pw.MultiPage(
        margin: const pw.EdgeInsets.fromLTRB(24, 24, 24, 28),
        build: (ctx) => [
          // Header
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              if (logo != null)
                pw.Container(
                  width: 60,
                  height: 36,
                  margin: const pw.EdgeInsets.only(right: 10),
                  child: pw.Image(logo!),
                ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    method == '5whys' ? 'REPORTE 5 PORQUÉS' : 'REPORTE 8D',
                    style: f18b,
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    'Proyecto: $proyecto   •   Parte: $parte',
                    style: f11,
                  ),
                  if (op.isNotEmpty) pw.Text('Operación: $op', style: f11),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 12),

          // Tabla principal
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.black, width: 1),
            columnWidths: const {
              0: pw.FixedColumnWidth(170),
              1: pw.FlexColumnWidth(),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: pw.Text('Campo', style: f12b),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: pw.Text('Detalle', style: f12b),
                  ),
                ],
              ),
              ...body.map(
                (r) => pw.TableRow(
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(6),
                      child: pw.Text(r[0], style: f10),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(6),
                      child: pw.Text(r[1], style: f10),
                    ),
                  ],
                ),
              ),
            ],
          ),

          pw.SizedBox(height: 10),
          // Metadatos + D6/D7
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Estado: ${m['status'] ?? ''}', style: f10),
                    pw.Text('Creada: ${_fmtTs(m['createdAt'])}', style: f10),
                    pw.Text(
                      'Actualizada: ${_fmtTs(m['updatedAt'])}',
                      style: f10,
                    ),
                  ],
                ),
              ),
              if (method == '8d')
                pw.Expanded(
                  child: pw.Container(
                    padding: const pw.EdgeInsets.all(8),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: PdfColors.grey700),
                      borderRadius: pw.BorderRadius.circular(4),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('D6 - Verificación', style: f12b),
                        pw.SizedBox(height: 4),
                        pw.Row(
                          crossAxisAlignment: pw.CrossAxisAlignment.center,
                          children: [
                            _pdfCheck(checked: d6Verified),
                            pw.SizedBox(width: 6),
                            pw.Text(
                              d6Verified
                                  ? 'Implementadas y verificadas'
                                  : 'Pendiente de verificación',
                              style: f10,
                            ),
                          ],
                        ),
                        if (d6Who.isNotEmpty || d6When.isNotEmpty) ...[
                          pw.SizedBox(height: 4),
                          pw.Text(
                            'Por: ${d6Who.isEmpty ? '—' : d6Who}',
                            style: f10,
                          ),
                          pw.Text(
                            'Fecha: ${d6When.isEmpty ? '—' : d6When}',
                            style: f10,
                          ),
                        ],
                        pw.SizedBox(height: 8),
                        pw.Text(
                          'D7 - Vigencia acciones preventivas',
                          style: f12b,
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          (d7Start.isNotEmpty || d7End.isNotEmpty)
                              ? 'Del $d7Start al $d7End'
                              : 'Sin definir',
                          style: f10,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    return pdf.save();
  }
  // ========================================

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _ref.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(body: Center(child: Text('Error: ${snap.error}')));
        }
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final m = snap.data!.data()!;
        final method = (m['method'] ?? '').toString();
        final status = (m['status'] ?? 'abierta').toString();
        final proyecto = (m['proyecto'] ?? '—').toString();
        final parte = (m['numeroParte'] ?? '—').toString();
        final op = (m['operacionNombre'] ?? '').toString();

        final locked = status == 'cerrada'; // bloquea edición si está cerrada

        return Scaffold(
          appBar: AppBar(
            title: Text(
              '${method == '5whys' ? '5 Porqués' : '8D'} • $proyecto • $parte',
            ),
            actions: [
              // Exportar PDF
              IconButton(
                tooltip: 'Exportar PDF',
                onPressed: _saving
                    ? null
                    : () async {
                        final snap = await _ref.get();
                        final data = snap.data()!;
                        final bytes = await _buildPdfBytes(data);
                        await Printing.layoutPdf(onLayout: (_) async => bytes);
                      },
                icon: const Icon(Icons.picture_as_pdf_outlined),
              ),
              // Cerrar / Reabrir (solo admin)
              if (_isAdmin)
                TextButton.icon(
                  onPressed: _saving ? null : () => _toggleStatus(status),
                  icon: Icon(
                    status == 'abierta' ? Icons.lock_open : Icons.lock,
                    color: Colors.white,
                  ),
                  label: Text(
                    status == 'abierta' ? 'Cerrar' : 'Reabrir',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
            ],
          ),
          body: AbsorbPointer(
            absorbing: locked || _saving,
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  if (op.isNotEmpty)
                    Text(
                      'Operación: $op',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  if (locked)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Row(
                        children: const [
                          Icon(Icons.lock, size: 16, color: Colors.black54),
                          SizedBox(width: 6),
                          Text(
                            'Investigación cerrada (solo lectura)',
                            style: TextStyle(color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (method == '5whys') _fiveWhysEditor(m),
                  if (method == '8d') _eightDEditor(m, context),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _fiveWhysEditor(Map<String, dynamic> m) {
    final List<dynamic> whys = (m['whys'] is List)
        ? (m['whys'] as List)
        : List.filled(5, '');
    final ctrls = List.generate(
      5,
      (i) => TextEditingController(text: (i < whys.length ? '${whys[i]}' : '')),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...List.generate(5, (i) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextFormField(
              controller: ctrls[i],
              maxLines: 3,
              decoration: InputDecoration(
                labelText: '¿Por qué ${i + 1}?',
                border: const OutlineInputBorder(),
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _saving ? null : () => _save5Whys(ctrls),
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          label: const Text('Guardar'),
        ),
      ],
    );
  }

  Widget _eightDEditor(Map<String, dynamic> m, BuildContext ctx) {
    final d = (m['d'] ?? {}) as Map<String, dynamic>;
    final ctrls = <String, TextEditingController>{
      'd1': TextEditingController(text: '${d['d1_equipo'] ?? ''}'),
      'd2': TextEditingController(text: '${d['d2_descripcion'] ?? ''}'),
      'd3': TextEditingController(text: '${d['d3_contencion'] ?? ''}'),
      'd4': TextEditingController(text: '${d['d4_causa_raiz'] ?? ''}'),
      'd5': TextEditingController(text: '${d['d5_acciones_correc'] ?? ''}'),
      'd6': TextEditingController(text: '${d['d6_implementar'] ?? ''}'),
      'd7': TextEditingController(text: '${d['d7_prevenir'] ?? ''}'),
      'd8': TextEditingController(text: '${d['d8_cerrar'] ?? ''}'),
    };

    final bool d6Verified = (m['d6_verified'] ?? false) as bool;
    final d6Who = (m['d6_verifiedByName'] ?? m['d6_verifiedByEmail'] ?? '')
        .toString();
    final d6When = _fmtTs(m['d6_verifiedAt']);

    final tsStart = m['d7_prev_start'] as Timestamp?;
    final tsEnd = m['d7_prev_end'] as Timestamp?;
    final d7Label = (tsStart != null || tsEnd != null)
        ? '${_fmtTs(tsStart)}  →  ${_fmtTs(tsEnd)}'
        : 'Sin definir';

    List<Widget> field(String label, String key) => [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      TextFormField(
        controller: ctrls[key],
        maxLines: 4,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...field('D1. Equipo de trabajo', 'd1'),
        ...field('D2. Descripción del problema', 'd2'),
        ...field('D3. Acción de contención', 'd3'),
        ...field('D4. Causa raíz', 'd4'),
        ...field('D5. Acciones correctivas', 'd5'),

        // D6: verificación con checkbox funcional
        Text(
          'D6. Implementación / Verificación',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: ctrls['d6'],
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: 6),
        CheckboxListTile(
          value: d6Verified,
          onChanged: (v) => _setD6Verified(v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Acciones implementadas y verificadas'),
          contentPadding: EdgeInsets.zero,
        ),
        if (d6Who.isNotEmpty || d6When.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Verificado por: ${d6Who.isEmpty ? '—' : d6Who}'
              '${d6When.isNotEmpty ? ' • $d6When' : ''}',
              style: const TextStyle(color: Colors.black54),
            ),
          ),

        // D7: preventivas + rango visible
        ...field('D7. Prevención de recurrencia', 'd7'),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Definir vigencia de'),
                  Text(
                    'acciones preventivas',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
            FilledButton(
              onPressed: () => _pickD7Range(tsStart, tsEnd, ctx),
              child: const Text('Elegir fechas'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Vigencia: $d7Label',
          style: const TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 12),

        ...field('D8. Cierre y reconocimiento', 'd8'),

        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : () => _save8D(ctrls),
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Guardar'),
              ),
            ),
            const SizedBox(width: 8),
            if (_isAdmin)
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saving
                      ? null
                      : () async {
                          await _save8D(ctrls);
                          await _toggleStatus('abierta'); // cerrar + propagar
                        },
                  icon: const Icon(Icons.lock),
                  label: const Text('Guardar y cerrar'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
