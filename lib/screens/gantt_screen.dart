import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Gantt de producción
/// Jerarquía: Proyecto > Nº de parte > Operación
/// Campos usados por doc en `production_daily`:
/// - proyecto (String), numeroParte (String), operacionNombre (String)
/// - planInicio (Timestamp?) / planFin (Timestamp?)   <-- preferente
/// - fecha (Timestamp?) / fechaCompromiso (Timestamp?) <-- fallback plan
/// - inicio (Timestamp?) / fin (Timestamp?)           <-- real
/// - opSecuencia (int?)                               <-- orden dentro del P/N
class GanttScreen extends StatefulWidget {
  const GanttScreen({super.key});

  @override
  State<GanttScreen> createState() => _GanttScreenState();
}

class _GanttScreenState extends State<GanttScreen> {
  // Tamaños base (pueden escalarse con _scale)
  static const double _baseRowH = 32;
  static const double _baseDayW = 32;

  double _scale = 1.0; // 0.5 .. 2.0

  double get _rowH => _baseRowH * _scale;
  double get _dayW => _baseDayW * _scale;

  @override
  Widget build(BuildContext context) {
    final q = FirebaseFirestore.instance
        .collection('production_daily')
        .orderBy('proyecto')
        .orderBy('numeroParte'); // ⚠️ requiere índice compuesto

    return Scaffold(
      appBar: AppBar(title: const Text('Gantt de producción')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('Sin datos.'));
          }

          // ---- Agrupar: proyecto > parte > lista de operaciones (con fechas calculadas)
          final grouped = <String, Map<String, List<_OpItem>>>{};
          DateTime? minD;
          DateTime? maxD;

          for (final d in docs) {
            final m = d.data();

            final p = (m['proyecto'] ?? '—').toString();
            final pn = (m['numeroParte'] ?? '—').toString();
            final opName = (m['operacionNombre'] ?? m['operacion'] ?? '—')
                .toString();

            final planInicio =
                (m['planInicio'] as Timestamp?)?.toDate() ??
                (m['fecha'] as Timestamp?)?.toDate();

            final planFin =
                (m['planFin'] as Timestamp?)?.toDate() ??
                (m['fechaCompromiso'] as Timestamp?)?.toDate() ??
                (planInicio != null
                    ? planInicio.add(const Duration(days: 1))
                    : null);

            final realInicio = (m['inicio'] as Timestamp?)?.toDate();
            final realFin = (m['fin'] as Timestamp?)?.toDate();

            final sec = (m['opSecuencia'] is int)
                ? (m['opSecuencia'] as int)
                : int.tryParse('${m['opSecuencia'] ?? ''}') ?? 9999;

            // Extremos del rango para cabecera/scroll
            for (final dt in [planInicio, planFin, realInicio, realFin]) {
              if (dt == null) continue;
              minD = (minD == null || dt.isBefore(minD!)) ? dt : minD;
              maxD = (maxD == null || dt.isAfter(maxD!)) ? dt : maxD;
            }

            grouped.putIfAbsent(p, () => {});
            grouped[p]!.putIfAbsent(pn, () => []);
            grouped[p]![pn]!.add(
              _OpItem(
                secuencia: sec,
                op: opName,
                planStart: planInicio,
                planEnd: planFin,
                realStart: realInicio,
                realEnd: realFin,
              ),
            );
          }

          // Rango por defecto si faltara algo
          minD ??= DateTime.now();
          maxD ??= DateTime.now().add(const Duration(days: 7));

          // Normaliza a medianoche para un grid “por día”
          minD = DateTime(minD!.year, minD!.month, minD!.day);
          maxD = DateTime(maxD!.year, maxD!.month, maxD!.day);

          final totalDays = max(1, maxD!.difference(minD!).inDays + 1);
          final fullWidth = totalDays * _dayW;

          // Ordena por secuencia dentro de cada parte
          grouped.forEach((_, parts) {
            parts.forEach((__, ops) {
              ops.sort((a, b) {
                final bySeq = a.secuencia.compareTo(b.secuencia);
                if (bySeq != 0) return bySeq;
                final aStart = a.planStart ?? DateTime(2100);
                final bStart = b.planStart ?? DateTime(2100);
                return aStart.compareTo(bStart);
              });
            });
          });

          return Column(
            children: [
              // Zoom
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.zoom_out),
                    Expanded(
                      child: Slider(
                        value: _scale,
                        min: 0.5,
                        max: 2.0,
                        divisions: 15,
                        label: '${(_scale * 100).round()}%',
                        onChanged: (v) => setState(() => _scale = v),
                      ),
                    ),
                    const Icon(Icons.zoom_in),
                  ],
                ),
              ),

              // Cabecera de días
              _headerDays(minD!, totalDays),

              const Divider(height: 1),

              // Lienzo
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Columna izquierda fija (etiquetas)
                    SizedBox(width: 320, child: _labelsPane(grouped)),
                    const VerticalDivider(width: 1),
                    // Barras con scroll horizontal
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: fullWidth,
                          child: _barsPane(grouped, minD!, totalDays),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(height: 1),
              _legend(),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }

  // ---------- Cabecera de días ----------
  Widget _headerDays(DateTime start, int total) {
    return SizedBox(
      height: max(36, 28 * _scale),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: List.generate(total, (i) {
            final d = start.add(Duration(days: i));
            final text = '${d.month}/${d.day}';
            final isToday = _isSameDay(d, DateTime.now());
            return Container(
              alignment: Alignment.center,
              width: _dayW,
              decoration: BoxDecoration(
                color: isToday ? Colors.red.withOpacity(0.05) : null,
                border: Border(
                  right: BorderSide(color: Colors.grey.shade300, width: 1),
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: max(10, 11 * _scale),
                  fontWeight: isToday ? FontWeight.w600 : FontWeight.w400,
                  color: isToday ? Colors.red.shade400 : null,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  // ---------- Panel de etiquetas izquierdo ----------
  Widget _labelsPane(Map<String, Map<String, List<_OpItem>>> g) {
    final rows = <Widget>[];
    g.forEach((project, parts) {
      rows.add(
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          color: Colors.grey.shade100,
          child: Text(
            project,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      );
      parts.forEach((pn, ops) {
        rows.add(
          Container(
            height: _rowH,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            child: Text('• $pn', overflow: TextOverflow.ellipsis),
          ),
        );
        for (final op in ops) {
          rows.add(
            Container(
              height: _rowH,
              padding: const EdgeInsets.only(left: 16, right: 8),
              alignment: Alignment.centerLeft,
              child: Text(
                '   └ [${op.secuencia}] ${op.op}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        }
      });
    });
    return ListView(children: rows);
  }

  // ---------- Panel de barras ----------
  Widget _barsPane(
    Map<String, Map<String, List<_OpItem>>> g,
    DateTime start,
    int totalDays,
  ) {
    final rows = <Widget>[];
    g.forEach((project, parts) {
      rows.add(
        Container(
          height: max(28, 24 * _scale),
          color: Colors.grey.shade100,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            project,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      );

      parts.forEach((pn, ops) {
        // Fila vacía separadora del P/N
        rows.add(
          Container(
            height: _rowH,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
          ),
        );

        for (final op in ops) {
          rows.add(
            _ganttRow(
              start: start,
              totalDays: totalDays,
              dayW: _dayW,
              rowH: _rowH,
              planStart: op.planStart,
              planEnd: op.planEnd,
              realStart: op.realStart,
              realEnd: op.realEnd,
            ),
          );
        }
      });
    });

    return Stack(
      children: [
        ListView(children: rows),
        // Línea de hoy superpuesta
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _TodayPainter(start: start, dayW: _dayW),
            ),
          ),
        ),
      ],
    );
  }

  /// Dibuja una fila con barra plan (clara) y real (oscura)
  Widget _ganttRow({
    required DateTime start,
    required int totalDays,
    required double dayW,
    required double rowH,
    DateTime? planStart,
    DateTime? planEnd,
    DateTime? realStart,
    DateTime? realEnd,
  }) {
    double leftOf(DateTime d) => d.difference(start).inDays * dayW;
    double widthOf(DateTime a, DateTime b) =>
        max(dayW * 0.8, (b.difference(a).inDays + 1) * dayW - 2);

    final stackChildren = <Widget>[];

    // Grid vertical tenue
    for (int i = 0; i < totalDays; i++) {
      stackChildren.add(
        Positioned(
          left: i * dayW,
          top: 0,
          bottom: 0,
          child: Container(width: 1, color: Colors.grey.withOpacity(0.12)),
        ),
      );
    }

    // Plan
    if (planStart != null && planEnd != null && !planEnd.isBefore(planStart)) {
      stackChildren.add(
        Positioned(
          left: leftOf(planStart),
          top: max(4, 3 * _scale),
          child: Container(
            width: widthOf(planStart, planEnd),
            height: max(10, 8 * _scale),
            decoration: BoxDecoration(
              color: Colors.blue.shade200,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      );
    }

    // Real
    if (realStart != null && realEnd != null && !realEnd.isBefore(realStart)) {
      stackChildren.add(
        Positioned(
          left: leftOf(realStart),
          top: max(10, 9 * _scale),
          child: Container(
            width: widthOf(realStart, realEnd),
            height: max(12, 10 * _scale),
            decoration: BoxDecoration(
              color: Colors.blue.shade700,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: rowH,
      child: Stack(children: stackChildren),
    );
  }

  Widget _legend() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _box(Colors.blue.shade200),
          const SizedBox(width: 6),
          const Text('Plan'),
          const SizedBox(width: 16),
          _box(Colors.blue.shade700),
          const SizedBox(width: 6),
          const Text('Real'),
          const SizedBox(width: 16),
          Container(width: 18, height: 2, color: Colors.red),
          const SizedBox(width: 6),
          const Text('Hoy'),
        ],
      ),
    );
  }

  Widget _box(Color c) => Container(
    width: 18,
    height: 10,
    decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
  );

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ---------- Model interno de una operación ----------
class _OpItem {
  final int secuencia;
  final String op;
  final DateTime? planStart;
  final DateTime? planEnd;
  final DateTime? realStart;
  final DateTime? realEnd;

  _OpItem({
    required this.secuencia,
    required this.op,
    required this.planStart,
    required this.planEnd,
    required this.realStart,
    required this.realEnd,
  });
}

// ---------- Painter línea de “hoy” ----------
class _TodayPainter extends CustomPainter {
  final DateTime start;
  final double dayW;

  _TodayPainter({required this.start, required this.dayW});

  @override
  void paint(Canvas canvas, Size size) {
    final today = DateTime.now();
    final d0 = DateTime(start.year, start.month, start.day);
    final d1 = DateTime(today.year, today.month, today.day);

    final days = d1.difference(d0).inDays;
    if (days < 0) return;

    final x = days * dayW + dayW / 2;
    final paint = Paint()
      ..color = Colors.red.withOpacity(0.6)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _TodayPainter oldDelegate) =>
      oldDelegate.start != start || oldDelegate.dayW != dayW;
}
