import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

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
            final s = (d.data()['status'] ?? '').toString().toLowerCase();
            return s != 'hecho' && s != 'terminado';
          }).toList();

          if (items.isEmpty) {
            return const Center(child: Text('No hay órdenes pendientes.'));
          }

          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final d = items[i].data();
              final id = items[i].id;
              final proyecto = (d['proyecto'] ?? '—').toString();
              final parte = (d['numeroParte'] ?? '—').toString();
              final op = (d['operacion'] ?? '—').toString();
              final status = (d['status'] ?? 'programado').toString();

              return ListTile(
                title: Text('$proyecto • $parte'),
                subtitle: Text('Operación: $op  •  Status: $status'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
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
