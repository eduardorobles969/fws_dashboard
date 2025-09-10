// lib/screens/scrap_investigations_screen.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter/services.dart' show rootBundle;

import 'scrap_investigation_detail_screen.dart';

class ScrapInvestigationsScreen extends StatefulWidget {
  const ScrapInvestigationsScreen({super.key});

  @override
  State<ScrapInvestigationsScreen> createState() =>
      _ScrapInvestigationsScreenState();
}

class _ScrapInvestigationsScreenState extends State<ScrapInvestigationsScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _stream() {
    return FirebaseFirestore.instance
        .collection('scrap_investigations')
        .orderBy('updatedAt', descending: true)
        .limit(200)
        .snapshots();
  }

  String _fmtTs(dynamic ts) {
    if (ts is Timestamp) {
      return DateFormat('yyyy-MM-dd HH:mm').format(ts.toDate());
    }
    return '';
  }

  Color _statusColor(String s, BuildContext ctx) {
    final theme = Theme.of(ctx);
    if (s == 'cerrada') {
      return Colors.green.shade100;
    }
    if (s == 'abierta') {
      return theme.colorScheme.secondaryContainer.withOpacity(.6);
    }
    return Colors.grey.shade200;
  }

  Widget _chip(String text, Color bg, {Color? fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg ?? Colors.black87,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Future<void> _openPdf(Map<String, dynamic> m) async {
    final bytes = await _buildPdfViaDetail(m);
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<Uint8List> _buildPdfViaDetail(Map<String, dynamic> m) async {
    final dummy = _ScrapInvestigationDetailPdfAdapter();
    return dummy.buildPdf(m);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Investigaciones de scrap')),
      body: Column(
        children: [
          // Buscador
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText:
                    'Buscar por proyecto, parte, operación, método o estado',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: (_searchCtrl.text.isEmpty)
                    ? null
                    : IconButton(
                        onPressed: () {
                          setState(() => _searchCtrl.clear());
                        },
                        icon: const Icon(Icons.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _stream(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text('Error: ${snap.error}'));
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snap.data!.docs;

                // Filtro local
                final q = _searchCtrl.text.trim().toLowerCase();
                final filtered = q.isEmpty
                    ? docs
                    : docs.where((d) {
                        final m = d.data();
                        final proyecto = (m['proyecto'] ?? '')
                            .toString()
                            .toLowerCase();
                        final parte = (m['numeroParte'] ?? '')
                            .toString()
                            .toLowerCase();
                        final op = (m['operacionNombre'] ?? '')
                            .toString()
                            .toLowerCase();
                        final method = (m['method'] ?? '')
                            .toString()
                            .toLowerCase();
                        final status = (m['status'] ?? '')
                            .toString()
                            .toLowerCase();
                        return proyecto.contains(q) ||
                            parte.contains(q) ||
                            op.contains(q) ||
                            method.contains(q) ||
                            status.contains(q);
                      }).toList();

                if (filtered.isEmpty) {
                  return const Center(child: Text('Sin resultados.'));
                }

                return ListView.separated(
                  padding: const EdgeInsets.only(
                    left: 12,
                    right: 12,
                    bottom: 16,
                  ),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final d = filtered[i];
                    final id = d.id;
                    final m = d.data();

                    final proyecto = (m['proyecto'] ?? '—').toString();
                    final parte = (m['numeroParte'] ?? '—').toString();
                    final op = (m['operacionNombre'] ?? '').toString();
                    final method = (m['method'] ?? '')
                        .toString(); // '8d'/'5whys'
                    final status = (m['status'] ?? 'abierta').toString();
                    final created = m['createdAt'];
                    final updated = m['updatedAt'];

                    final isClosed = status == 'cerrada';

                    return InkWell(
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                ScrapInvestigationDetailScreen(docId: id),
                          ),
                        );
                      },
                      onLongPress: () => _openPdf(m),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          border: Border.all(color: Colors.black12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // encabezado: proyecto/parte + chips
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    '$proyecto • $parte',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                if (isClosed) ...[
                                  const Icon(Icons.lock, size: 16),
                                  const SizedBox(width: 6),
                                ],
                                _chip(
                                  status == 'cerrada' ? 'Cerrada' : 'Abierta',
                                  _statusColor(status, context),
                                ),
                                const SizedBox(width: 6),
                                _chip(
                                  method == '5whys'
                                      ? '5 Porqués'
                                      : method.toUpperCase(),
                                  Colors.blue.shade50,
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (op.isNotEmpty)
                              Text(
                                'Operación: $op',
                                style: const TextStyle(color: Colors.black54),
                              ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Creada: ${_fmtTs(created)}',
                                    style: const TextStyle(
                                      color: Colors.black45,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    'Actualizada: ${_fmtTs(updated)}',
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      color: Colors.black45,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            ScrapInvestigationDetailScreen(
                                              docId: id,
                                            ),
                                      ),
                                    );
                                  },
                                  icon: const Icon(Icons.visibility_outlined),
                                  label: const Text('Abrir'),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () => _openPdf(m),
                                  icon: const Icon(
                                    Icons.picture_as_pdf_outlined,
                                  ),
                                  label: const Text('PDF'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ScrapInvestigationDetailPdfAdapter {
  Future<Uint8List> buildPdf(Map<String, dynamic> m) async {
    final state = _ScrapInvestigationDetailPdfShim();
    return state.buildPdfBytes(m);
  }
}

class _ScrapInvestigationDetailPdfShim {
  String _fmtTs(dynamic ts) =>
      ts is Timestamp ? DateFormat('yyyy-MM-dd HH:mm').format(ts.toDate()) : '';

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

  Future<Uint8List> buildPdfBytes(Map<String, dynamic> m) async {
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
                          ((m['d7_prev_start'] != null) ||
                                  (m['d7_prev_end'] != null))
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
}
