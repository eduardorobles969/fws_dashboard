import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// ===============================================================
/// PANTALLA DE RETRABAJO
///
/// Muestra las órdenes de producción con piezas en fail para que el
/// supervisor asigne a qué operador se le enviarán a retrabajar.
/// Los documentos se leen de `production_daily` donde `fail > 0` y aún
/// no tienen operador de retrabajo asignado (`reworkOperatorId`).
/// ===============================================================
class ReworkScreen extends StatefulWidget {
  const ReworkScreen({super.key});

  @override
  State<ReworkScreen> createState() => _ReworkScreenState();
}

class _ReworkScreenState extends State<ReworkScreen> {
  Future<void> _assignToOperator(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    _UserRef? selected;

    try {
      final qs = await FirebaseFirestore.instance
          .collection('users')
          .where('role', isEqualTo: 'operador')
          .orderBy('displayName')
          .get();
      final users = qs.docs
          .map(
            (d) => _UserRef(
              uid: d.id,
              name:
                  (d.data()['displayName'] ?? d.data()['email'] ?? 'Operador')
                      .toString(),
            ),
          )
          .toList();

      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Asignar retrabajo'),
            content: DropdownButtonFormField<_UserRef>(
              value: selected,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Operador',
                border: OutlineInputBorder(),
              ),
              items: users
                  .map((u) => DropdownMenuItem(value: u, child: Text(u.name)))
                  .toList(),
              onChanged: (v) => selected = v,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Guardar'),
              ),
            ],
          );
        },
      );
      if (ok != true || selected == null) return;

      await doc.reference.update({
        'reworkOperatorId': selected!.uid,
        'reworkOperatorName': selected!.name,
        'status': 'retrabajo',
        'reworkAssignedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Retrabajo asignado')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = FirebaseFirestore.instance
        .collection('production_daily')
        .where('fail', isGreaterThan: 0);

    return Scaffold(
      appBar: AppBar(title: const Text('Retrabajo')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data!.docs.where((d) {
            final m = d.data();
            final op = (m['operacion'] ?? '').toString().toUpperCase();
            if (op == 'RETRABAJO') return false;
            final assigned = (m['reworkOperatorId'] ?? '').toString();
            return assigned.isEmpty;
          }).toList();

          if (docs.isEmpty) {
            return const Center(child: Text('Sin piezas para retrabajo'));
          }

          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final d = docs[i];
              final m = d.data();
              final proyecto = (m['proyecto'] ?? '—').toString();
              final parte = (m['numeroParte'] ?? '—').toString();
              final fail = (m['fail'] ?? 0).toString();
              final cause = (m['failCauseName'] ?? '').toString();

              return ListTile(
                title: Text('$proyecto • $parte'),
                subtitle: Text('Fail: $fail  •  Causa: $cause'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _assignToOperator(d),
              );
            },
          );
        },
      ),
    );
  }
}

class _UserRef {
  final String uid;
  final String name;
  _UserRef({required this.uid, required this.name});
}

