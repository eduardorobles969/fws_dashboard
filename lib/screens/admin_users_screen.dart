// lib/screens/admin_users_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class AdminUsersScreen extends StatelessWidget {
  const AdminUsersScreen({super.key});

  static const roles = ['operador', 'supervisor', 'diseñador', 'administrador'];

  @override
  Widget build(BuildContext context) {
    final q = FirebaseFirestore.instance
        .collection('users')
        .orderBy('displayName');

    return Scaffold(
      appBar: AppBar(title: const Text('Administrar usuarios')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data!.docs;
          if (docs.isEmpty) return const Center(child: Text('No hay usuarios'));

          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final ref = docs[i].reference;
              final d = docs[i].data();
              final name = (d['displayName'] ?? '').toString();
              final email = (d['email'] ?? '').toString();
              final role = (d['role'] ?? 'operador').toString();
              final active = (d['active'] ?? true) as bool;

              return ListTile(
                title: Text(
                  name.isEmpty ? email : name,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(email),
                trailing: SizedBox(
                  width: 260,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DropdownButton<String>(
                        value: roles.contains(role) ? role : 'operador',
                        items: roles
                            .map(
                              (r) => DropdownMenuItem(value: r, child: Text(r)),
                            )
                            .toList(),
                        onChanged: (val) async {
                          if (val == null) return;
                          await ref.update({'role': val});
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Rol actualizado a "$val"')),
                          );
                        },
                      ),
                      const SizedBox(width: 12),
                      Switch(
                        value: active,
                        onChanged: (v) async {
                          await ref.update({'active': v});
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
