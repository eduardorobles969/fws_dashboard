import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class GanttScreen extends StatefulWidget {
  const GanttScreen({super.key});
  @override
  State<GanttScreen> createState() => _GanttScreenState();
}

class _GanttScreenState extends State<GanttScreen> {
  DateTimeRange? _range;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _range = DateTimeRange(
      start: DateTime(now.year, now.month, 1),
      end: DateTime(now.year, now.month + 1, 0),
    );
  }

  Query<Map<String, dynamic>> _query() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance.collection(
      'production_daily',
    );
    if (_range != null) {
      final start = Timestamp.fromDate(
        DateTime(_range!.start.year, _range!.start.month, _range!.start.day),
      );
      final end = Timestamp.fromDate(
        DateTime(
          _range!.end.year,
          _range!.end.month,
          _range!.end.day,
          23,
          59,
          59,
          999,
        ),
      );
      q = q
          .where('fecha', isGreaterThanOrEqualTo: start)
          .where('fecha', isLessThanOrEqualTo: end);
    }
    return q.orderBy('fecha'); // ascendente para Gantt
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('yyyy-MM-dd');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gantt producción'),
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range),
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDateRangePicker(
                context: context,
                firstDate: DateTime(now.year - 2),
                lastDate: DateTime(now.year + 2),
                initialDateRange: _range,
              );
              if (picked != null) setState(() => _range = picked);
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _query().snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text('Sin órdenes en el rango seleccionado.'),
            );
          }

          // calculamos rango total (dias)
          final start = DateTime(
            _range!.start.year,
            _range!.start.month,
            _range!.start.day,
          );
          final end = DateTime(
            _range!.end.year,
            _range!.end.month,
            _range!.end.day,
            23,
            59,
            59,
          );
          final total = end.difference(start).inHours.toDouble().clamp(1, 1e9);

          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final d = docs[i].data();
              final proyecto = (d['proyecto'] ?? '—').toString();
              final parte = (d['numeroParte'] ?? '—').toString();
              final status = (d['status'] ?? '').toString();
              final fecha = d['fecha'] as Timestamp?;
              final inicioTs = d['inicio'] as Timestamp?;
              final finTs = d['fin'] as Timestamp?;

              // si no hay inicio/fin, usamos el mismo punto 'fecha' como barra muy corta
              DateTime from = inicioTs?.toDate() ?? fecha?.toDate() ?? start;
              DateTime to =
                  finTs?.toDate() ?? from.add(const Duration(hours: 6));

              // recorta al rango visible
              if (to.isBefore(start)) to = start;
              if (from.isBefore(start)) from = start;
              if (from.isAfter(end)) from = end;
              if (to.isAfter(end)) to = end;
              if (!to.isAfter(from)) to = from.add(const Duration(hours: 1));

              final left = from
                  .difference(start)
                  .inHours
                  .toDouble()
                  .clamp(0, total);
              final width = (to.difference(from).inHours.toDouble()).clamp(
                1,
                total,
              );

              return ListTile(
                title: Text('$proyecto • $parte'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status: $status • ${fmt.format(from)} → ${fmt.format(to)}',
                    ),
                    const SizedBox(height: 6),
                    LayoutBuilder(
                      builder: (ctx, cons) {
                        final w = cons.maxWidth;
                        final relLeft = (left / total) * w;
                        final relWidth = (width / total) * w;

                        return SizedBox(
                          height: 16,
                          child: Stack(
                            children: [
                              Container(
                                width: w,
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade200,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              Positioned(
                                left: relLeft,
                                width: relWidth,
                                top: 0,
                                bottom: 0,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: _barColor(status),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Color _barColor(String status) {
    final s = status.toLowerCase();
    if (s.contains('proceso')) return Colors.amber;
    if (s.contains('hecho') || s.contains('terminado')) return Colors.green;
    if (s.contains('paus')) return Colors.orange;
    return Colors.blueGrey;
  }
}
