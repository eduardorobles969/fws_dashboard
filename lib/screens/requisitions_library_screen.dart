// lib/screens/requisitions_library_screen.dart
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter/services.dart' show rootBundle;

class RequisitionsLibraryScreen extends StatelessWidget {
  const RequisitionsLibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('requisitions')
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots();

    return Scaffold(
      appBar: AppBar(title: const Text('Requisiciones')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          if (!snap.hasData)
            return const Center(child: CircularProgressIndicator());

          final docs = snap.data!.docs;
          if (docs.isEmpty)
            return const Center(child: Text('Sin requisiciones.'));

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final d = docs[i];
              final m = d.data();
              final created = (m['createdAt'] as Timestamp?)?.toDate();
              final deadline = (m['deadline'] as Timestamp?)?.toDate();
              final items = (m['items'] as List?) ?? [];

              return ListTile(
                tileColor: Colors.grey.shade50,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                title: Text(m['projectName']?.toString() ?? '(sin proyecto)'),
                subtitle: Text(
                  'Requisitor: ${m['requisitor'] ?? '-'} • '
                  'Fecha límite: ${deadline == null ? '-' : DateFormat('yyyy-MM-dd').format(deadline)} • '
                  '${items.length} item(s)',
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      created == null
                          ? ''
                          : DateFormat('yyyy-MM-dd').format(created),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Icon(Icons.picture_as_pdf_outlined),
                  ],
                ),
                onTap: () async {
                  final bytes = await _buildPdfFromDoc(m);
                  await Printing.layoutPdf(onLayout: (_) async => bytes);
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<Uint8List> _buildPdfFromDoc(Map<String, dynamic> m) async {
    pw.MemoryImage? logo;
    try {
      final bytes = await rootBundle.load('assets/icon.png');
      logo = pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {}

    String fmtDate(DateTime? d) =>
        d == null ? '' : DateFormat('yyyy-MM-dd').format(d);

    final pdf = pw.Document();
    final H = pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold);
    final small = pw.TextStyle(fontSize: 9);
    final cell = pw.TextStyle(fontSize: 10);
    final head = pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold);

    final rows = <List<String>>[];
    for (final it in (m['items'] as List? ?? [])) {
      final map = Map<String, dynamic>.from(it as Map);
      rows.add([
        (map['qty'] ?? '').toString(),
        (map['unit'] ?? '').toString(),
        [
          map['materialCode'] ?? '',
          map['materialDesc'] ?? '',
        ].where((e) => e.toString().isNotEmpty).join(' – '),
        (map['desc'] ?? '').toString(),
        (map['dim'] ?? '').toString(),
        (map['sup'] ?? '').toString(),
      ]);
    }
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
              _headerRow('REQUISITOR', (m['requisitor'] ?? '').toString()),
              _headerRow('PROYECTO', (m['projectName'] ?? '').toString()),
              _headerRow(
                'FECHA LÍMITE',
                fmtDate((m['deadline'] as Timestamp?)?.toDate()),
              ),
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
}
