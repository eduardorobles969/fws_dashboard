import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'operator_edit_entry_screen.dart';

class OperatorTasksScreen extends StatelessWidget {
  const OperatorTasksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    final q = FirebaseFirestore.instance
        .collection('production_daily')
        .where('operadorUid', isEqualTo: uid) // 👈 simple y rápido
        .orderBy('fecha', descending: true);

    return Scaffold(
      appBar: AppBar(title: const Text('Mis órdenes')),
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
            return const Center(child: Text('No tienes órdenes asignadas.'));
          }

          // si quieres ocultar finalizadas, filtra aquí:
          final items = docs.where((d) {
            final m = d.data();
            final s = (m['status'] ?? '').toString().toLowerCase();
            final op = (m['operacion'] ?? '').toString().toUpperCase();
            if (op == 'RETRABAJO') return false;
            return s != 'hecho' && s != 'terminado';
          }).toList();

          if (items.isEmpty) {
            return const Center(child: Text('No hay órdenes pendientes.'));
          }

          final dateFmt = DateFormat('dd/MM/yyyy HH:mm');

          String _formatTs(dynamic value) {
            if (value is Timestamp) {
              return dateFmt.format(value.toDate());
            }
            if (value is DateTime) {
              return dateFmt.format(value);
            }
            if (value is String && value.isNotEmpty) {
              final parsed = DateTime.tryParse(value);
              if (parsed != null) {
                return dateFmt.format(parsed);
              }
            }
            return '—';
          }

          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (itemContext, i) {
              final d = items[i].data();
              final id = items[i].id;
              final proyecto = (d['proyecto'] ?? '—').toString();
              final parte = (d['numeroParte'] ?? '—').toString();
              final op = (d['operacion'] ?? '—').toString();
              final status = (d['status'] ?? 'programado').toString();
              final inicioLabel = _formatTs(d['inicio']);
              final finLabel = _formatTs(d['fin']);

              return ListTile(
                title: Text('$proyecto • $parte'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Operación: $op  •  Status: $status'),
                    const SizedBox(height: 2),
                    Text(
                      'Inicio: $inicioLabel',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                    Text(
                      'Fin: $finLabel',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  ],
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  final navigator = Navigator.of(itemContext);
                  if (!navigator.mounted) return;
                  navigator.push(
                    MaterialPageRoute(
                      builder: (_) => OperatorEditEntryScreen(docId: id),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
