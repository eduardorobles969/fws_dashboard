// lib/screens/scrap_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'scrap_investigation_detail_screen.dart';

class ScrapScreen extends StatefulWidget {
  const ScrapScreen({super.key});
  @override
  State<ScrapScreen> createState() => _ScrapScreenState();
}

class _ScrapScreenState extends State<ScrapScreen> {
  String _status = 'abiertos'; // abiertos | cerrados | todos
  String _search = '';

  Query<Map<String, dynamic>> _baseQuery() {
    final col = FirebaseFirestore.instance.collection('scrap_events');
    switch (_status) {
      case 'abiertos':
        return col
            .where('status', whereIn: ['nuevo', 'revisado'])
            .orderBy('createdAt', descending: true);
      case 'cerrados':
        return col
            .where('status', isEqualTo: 'cerrado')
            .orderBy('createdAt', descending: true);
      default:
        return col.orderBy('createdAt', descending: true);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _setStatus(DocumentReference ref, String status) async {
    try {
      await ref.update({
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _toast('No se pudo actualizar: $e');
    }
  }

  /// Muestra selector de método y crea la investigación ligada al evento
  Future<void> _startInvestigation(
    DocumentSnapshot<Map<String, dynamic>> ev,
  ) async {
    final method = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            runSpacing: 12,
            children: [
              const Text(
                'Elegir metodología',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, '5whys'),
                icon: const Icon(Icons.filter_5),
                label: const Text('5 Porqués'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, '8d'),
                icon: const Icon(Icons.view_list),
                label: const Text('8D'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
            ],
          ),
        ),
      ),
    );
    if (method == null) return;

    final data = ev.data()!;
    try {
      await FirebaseFirestore.instance.collection('scrap_investigations').add({
        'eventRef': ev.reference,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'status': 'abierta', // abierta | cerrada
        'method': method, // 5whys | 8d
        'proyecto': (data['proyecto'] ?? '').toString(),
        'numeroParte': (data['numeroParte'] ?? '').toString(),
        'operacionNombre': (data['operacionNombre'] ?? '').toString(),
        // plantillas mínimas
        if (method == '5whys') 'whys': List<String>.filled(5, ''),
        if (method == '8d')
          'd': {
            'd1_equipo': '',
            'd2_descripcion': '',
            'd3_contencion': '',
            'd4_causa_raiz': '',
            'd5_acciones_correc': '',
            'd6_implementar': '',
            'd7_prevenir': '',
            'd8_cerrar': '',
          },
      });

      // marca el evento como en investigación (revisado) por si aún está "nuevo"
      if ((data['status'] ?? 'nuevo') == 'nuevo') {
        await ev.reference.update({
          'status': 'revisado',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      _toast('Investigación ($method) creada');
    } catch (e) {
      _toast('Error creando investigación: $e');
    }
  }

  /// Busca si ya hay investigación ligada al evento (eventRef == docRef)
  Stream<QuerySnapshot<Map<String, dynamic>>> _investigationStreamFor(
    DocumentReference<Map<String, dynamic>> eventRef,
  ) {
    return FirebaseFirestore.instance
        .collection('scrap_investigations')
        .where('eventRef', isEqualTo: eventRef)
        .limit(1)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    final query = _baseQuery();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reporte de scrap'),
        actions: [
          PopupMenuButton<String>(
            initialValue: _status,
            onSelected: (v) => setState(() => _status = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'abiertos', child: Text('Abiertos')),
              PopupMenuItem(value: 'cerrados', child: Text('Cerrados')),
              PopupMenuItem(value: 'todos', child: Text('Todos')),
            ],
            icon: const Icon(Icons.filter_list),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar proyecto, parte u operación',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) =>
                  setState(() => _search = v.trim().toLowerCase()),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: query.snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text('Error: ${snap.error}'));
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                var docs = snap.data!.docs;
                if (_search.isNotEmpty) {
                  docs = docs.where((d) {
                    final m = d.data();
                    final t =
                        '${m['proyecto']} ${m['numeroParte']} ${m['operacionNombre']} ${m['motivo']}'
                            .toLowerCase();
                    return t.contains(_search);
                  }).toList();
                }

                if (docs.isEmpty) {
                  return const Center(
                    child: Text('Sin eventos con los filtros actuales.'),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final d = docs[i];
                    final m = d.data();
                    final status = (m['status'] ?? 'nuevo').toString();
                    final proyecto = (m['proyecto'] ?? '—').toString();
                    final parte = (m['numeroParte'] ?? '—').toString();
                    final op = (m['operacionNombre'] ?? '').toString();
                    final maq = (m['maquinaNombre'] ?? '').toString();
                    final motivo = (m['motivo'] ?? '').toString();
                    final piezas = (m['piezas'] ?? 0).toString();

                    Color chipColor;
                    String chipText;
                    switch (status) {
                      case 'nuevo':
                        chipColor = Colors.red.shade100;
                        chipText = 'Nuevo';
                        break;
                      case 'revisado':
                        chipColor = Colors.orange.shade100;
                        chipText = 'Revisado';
                        break;
                      default:
                        chipColor = Colors.green.shade100;
                        chipText = 'Cerrado';
                    }

                    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _investigationStreamFor(d.reference),
                      builder: (context, invSnap) {
                        final hasInv =
                            invSnap.hasData && invSnap.data!.docs.isNotEmpty;
                        final invId = hasInv
                            ? invSnap.data!.docs.first.id
                            : null;
                        final invMethod = hasInv
                            ? (invSnap.data!.docs.first.data()['method'] ?? '')
                                  .toString()
                            : null;
                        final invStatus = hasInv
                            ? (invSnap.data!.docs.first.data()['status'] ?? '')
                                  .toString()
                            : null;

                        return Card(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              if (hasInv && invId != null) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ScrapInvestigationDetailScreen(
                                          docId: invId,
                                        ),
                                  ),
                                );
                              } else if (status == 'revisado') {
                                _startInvestigation(d);
                              } else {
                                _toast(
                                  'Primero marca este evento como revisado.',
                                );
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                12,
                                12,
                                12,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Título + chip
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '$proyecto • $parte',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: chipColor,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Text(
                                          chipText,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),

                                  if (op.isNotEmpty || maq.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      [
                                        if (op.isNotEmpty) 'Op: $op',
                                        if (maq.isNotEmpty) 'Maq: $maq',
                                      ].join(' • '),
                                      style: const TextStyle(
                                        color: Colors.black54,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],

                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 6,
                                    children: [
                                      _chip('Scrap: $piezas pza(s)'),
                                      if (motivo.isNotEmpty)
                                        _chip('Causa: $motivo'),
                                      if (hasInv &&
                                          invMethod != null &&
                                          invMethod.isNotEmpty)
                                        _chip(
                                          'Metodología: ${invMethod == '5whys' ? '5 Porqués' : '8D'}',
                                        ),
                                      if (hasInv &&
                                          invStatus != null &&
                                          invStatus.isNotEmpty)
                                        _chip('Investigación: $invStatus'),
                                    ],
                                  ),
                                  const SizedBox(height: 10),

                                  // Acciones
                                  Row(
                                    children: [
                                      if (status == 'nuevo') ...[
                                        OutlinedButton.icon(
                                          onPressed: () => _setStatus(
                                            d.reference,
                                            'revisado',
                                          ),
                                          icon: const Icon(Icons.visibility),
                                          label: const Text('Marcar revisado'),
                                        ),
                                        const SizedBox(width: 8),
                                      ] else
                                        OutlinedButton.icon(
                                          onPressed: null,
                                          icon: const Icon(Icons.visibility),
                                          label: const Text('Revisado'),
                                        ),
                                      const Spacer(),

                                      // Botón principal según estado/investigación
                                      if (hasInv && invId != null)
                                        FilledButton.icon(
                                          onPressed: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    ScrapInvestigationDetailScreen(
                                                      docId: invId,
                                                    ),
                                              ),
                                            );
                                          },
                                          icon: const Icon(Icons.open_in_new),
                                          label: const Text(
                                            'Abrir investigación',
                                          ),
                                        )
                                      else if (status == 'revisado')
                                        FilledButton.icon(
                                          onPressed: () =>
                                              _startInvestigation(d),
                                          icon: const Icon(Icons.bolt),
                                          label: const Text(
                                            'Iniciar 5 Porqués / 8D',
                                          ),
                                        )
                                      else
                                        OutlinedButton.icon(
                                          onPressed: null,
                                          icon: const Icon(Icons.info_outline),
                                          label: const Text(
                                            'Primero: revisado',
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
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

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.blueGrey.shade50,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(text, style: const TextStyle(fontSize: 12)),
  );
}
