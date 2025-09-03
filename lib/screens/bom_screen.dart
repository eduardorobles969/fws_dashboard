import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, rootBundle;
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
  String _projectName = '';
  String _search = '';

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

  Stream<List<_BomRow>> _partsStream() {
    if (_projectId == null) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection('projects')
        .doc(_projectId)
        .collection('parts')
        .orderBy('numeroParte')
        .snapshots()
        .map(
          (qs) => qs.docs.map((d) {
            final m = d.data();
            return _BomRow(
              id: d.id,
              numeroParte: (m['numeroParte'] ?? '').toString(),
              descripcionParte: (m['descripcionParte'] ?? '').toString(),
              cantidadPlan: (m['cantidadPlan'] ?? 0) is int
                  ? (m['cantidadPlan'] as int)
                  : int.tryParse('${m['cantidadPlan']}') ?? 0,
              ref: d.reference,
            );
          }).toList(),
        );
  }

  /// Suma de cantidades programadas por parte (production_daily)
  Stream<Map<String, int>> _asignadasPorParte() {
    if (_projectId == null) return const Stream.empty();
    final proyectoRef = FirebaseFirestore.instance
        .collection('projects')
        .doc(_projectId);

    return FirebaseFirestore.instance
        .collection('production_daily')
        .where('proyectoRef', isEqualTo: proyectoRef)
        .snapshots()
        .map((qs) {
          final map = <String, int>{}; // parteRef.id -> suma
          for (final d in qs.docs) {
            final m = d.data() as Map<String, dynamic>;
            final parteRef = m['parteRef'];
            final cant = (m['cantidad'] ?? 0) is int
                ? (m['cantidad'] as int)
                : int.tryParse('${m['cantidad']}') ?? 0;
            if (parteRef is DocumentReference) {
              map.update(parteRef.id, (v) => v + cant, ifAbsent: () => cant);
            }
          }
          return map;
        });
  }

  Future<void> _copyCsv(List<_BomRow> rows, Map<String, int> asignadas) async {
    final header = [
      'numeroParte',
      'descripcionParte',
      'cantidadPlan',
      'asignada',
    ];
    final csv = StringBuffer()..writeln(header.join(','));
    for (final r in rows) {
      final asig = asignadas[r.id] ?? 0;
      csv.writeln(
        [
          r.numeroParte,
          r.descripcionParte.replaceAll(',', ' '),
          r.cantidadPlan.toString(),
          asig.toString(),
        ].join(','),
      );
    }
    await Clipboard.setData(ClipboardData(text: csv.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('BOM copiado al portapapeles (CSV)')),
    );
  }

  Future<Uint8List> _buildPdfBytes({
    required String projectName,
    required List<_BomRow> rows,
    required Map<String, int> asignadas,
  }) async {
    final pdf = pw.Document();

    // Logo (opcional). Usa assets/icon.png si existe.
    pw.ImageProvider? logo;
    try {
      final bytes = await rootBundle.load('assets/icon.png');
      logo = pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {
      logo = null;
    }

    final totalPlan = rows.fold<int>(0, (sum, r) => sum + r.cantidadPlan);
    final totalAsignada = rows.fold<int>(
      0,
      (sum, r) => sum + (asignadas[r.id] ?? 0),
    );

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.all(24),
          theme: pw.ThemeData.withFont(
            base: await PdfGoogleFonts.robotoRegular(),
            bold: await PdfGoogleFonts.robotoBold(),
          ),
        ),
        header: (_) => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            if (logo != null) pw.Image(logo, width: 40, height: 40),
            if (logo != null) pw.SizedBox(width: 10),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'BOM del proyecto',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(projectName, style: const pw.TextStyle(fontSize: 12)),
              ],
            ),
            pw.Spacer(),
            pw.Text(
              DateTime.now().toString().substring(0, 16),
              style: const pw.TextStyle(fontSize: 10),
            ),
          ],
        ),
        build: (_) => [
          pw.SizedBox(height: 10),
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Row(
              children: [
                pw.Text(
                  'Total plan: ',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
                pw.Text('$totalPlan'),
                pw.SizedBox(width: 18),
                pw.Text(
                  'Asignada: ',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
                pw.Text('$totalAsignada'),
              ],
            ),
          ),
          pw.SizedBox(height: 12),
          pw.Table.fromTextArray(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            cellAlignment: pw.Alignment.centerLeft,
            headerAlignments: const {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
            },
            cellAlignments: const {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
            },
            data: <List<String>>[
              ['Nº de parte', 'Descripción', 'Plan', 'Asignada'],
              ...rows.map(
                (r) => [
                  r.numeroParte,
                  r.descripcionParte,
                  '${r.cantidadPlan}',
                  '${asignadas[r.id] ?? 0}',
                ],
              ),
            ],
          ),
        ],
      ),
    );

    return pdf.save();
  }

  Future<void> _printPdf(List<_BomRow> rows, Map<String, int> asignadas) async {
    final bytes = await _buildPdfBytes(
      projectName: _projectName,
      rows: rows,
      asignadas: asignadas,
    );
    await Printing.layoutPdf(onLayout: (format) async => bytes);
  }

  /// Rellena partes viejas sin `cantidadPlan` con 0.
  Future<void> _backfillCantidadPlan() async {
    if (_projectId == null) return;
    final partsCol = FirebaseFirestore.instance
        .collection('projects')
        .doc(_projectId)
        .collection('parts');

    final qs = await partsCol.get();
    final toFix = qs.docs.where((d) => !d.data().containsKey('cantidadPlan'));

    if (toFix.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Nada que actualizar.')));
      return;
    }

    WriteBatch batch = FirebaseFirestore.instance.batch();
    int count = 0;
    for (final d in toFix) {
      batch.update(d.reference, {'cantidadPlan': 0});
      count++;
      if (count % 400 == 0) {
        await batch.commit();
        batch = FirebaseFirestore.instance.batch();
      }
    }
    await batch.commit();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Actualizados $count documento(s).')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parts$ = _partsStream();
    final asignadas$ = _asignadasPorParte();

    return Scaffold(
      appBar: AppBar(
        title: const Text('BOM del proyecto'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (key) async {
              if (key == 'backfill') {
                await _backfillCantidadPlan();
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'backfill',
                child: Text('Backfill cantidadPlan = 0'),
              ),
            ],
          ),
        ],
      ),
      body: Padding(
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
                  onChanged: (v) {
                    final name =
                        projs.firstWhere((e) => e['id'] == v)['proyecto']
                            as String;
                    setState(() {
                      _projectId = v;
                      _projectName = name;
                    });
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Buscar Nº de parte',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) =>
                      setState(() => _search = v.trim().toUpperCase()),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _projectId == null
                      ? const Center(child: Text('Elige un proyecto'))
                      : StreamBuilder<List<_BomRow>>(
                          stream: parts$,
                          builder: (context, ps) {
                            if (ps.connectionState != ConnectionState.active) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            final parts = (ps.data ?? const <_BomRow>[])
                                .where(
                                  (r) => _search.isEmpty
                                      ? true
                                      : r.numeroParte.toUpperCase().contains(
                                          _search,
                                        ),
                                )
                                .toList();

                            if (parts.isEmpty) {
                              return const Center(child: Text('BOM vacío.'));
                            }

                            return StreamBuilder<Map<String, int>>(
                              stream: asignadas$,
                              builder: (context, as) {
                                final asignadas = as.data ?? const {};
                                final totalPlan = parts.fold<int>(
                                  0,
                                  (sum, r) => sum + r.cantidadPlan,
                                );
                                final totalAsignada = parts.fold<int>(
                                  0,
                                  (sum, r) => sum + (asignadas[r.id] ?? 0),
                                );

                                // ---- Fila de totales + acciones (sin overflow) ----
                                final totalsText = Text(
                                  'Total plan: $totalPlan   •   Asignada: $totalAsignada',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                );

                                final copyBtn = TextButton.icon(
                                  onPressed: () => _copyCsv(parts, asignadas),
                                  icon: const Icon(Icons.copy),
                                  label: const Text('Copiar CSV'),
                                );

                                final pdfBtn = TextButton.icon(
                                  onPressed: () => _printPdf(parts, asignadas),
                                  icon: const Icon(Icons.picture_as_pdf),
                                  label: const Text('Imprimir PDF'),
                                );

                                return Column(
                                  children: [
                                    // Wrap evita el overflow (elimina la franja amarilla)
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      alignment: WrapAlignment.spaceBetween,
                                      children: [
                                        totalsText,
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            copyBtn,
                                            const SizedBox(width: 4),
                                            pdfBtn,
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Expanded(
                                      child: ListView.separated(
                                        itemCount: parts.length,
                                        separatorBuilder: (_, __) =>
                                            const Divider(height: 1),
                                        itemBuilder: (_, i) {
                                          final r = parts[i];
                                          final asig = asignadas[r.id] ?? 0;
                                          return ListTile(
                                            title: Text(r.numeroParte),
                                            subtitle: Text(r.descripcionParte),
                                            trailing: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.end,
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Text('Plan: ${r.cantidadPlan}'),
                                                Text('Asignada: $asig'),
                                              ],
                                            ),
                                          );
                                        },
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
    );
  }
}

class _BomRow {
  final String id;
  final String numeroParte;
  final String descripcionParte;
  final int cantidadPlan;
  final DocumentReference ref;

  _BomRow({
    required this.id,
    required this.numeroParte,
    required this.descripcionParte,
    required this.cantidadPlan,
    required this.ref,
  });
}
