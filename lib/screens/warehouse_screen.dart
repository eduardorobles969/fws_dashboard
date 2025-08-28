import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class WarehouseScreen extends StatefulWidget {
  const WarehouseScreen({super.key});
  @override
  State<WarehouseScreen> createState() => _WarehouseScreenState();
}

class _WarehouseScreenState extends State<WarehouseScreen> {
  String _search = '';
  bool _usingInventory = true; // si no hay inventory, caemos a bodegas

  Stream<QuerySnapshot<Map<String, dynamic>>> _inventoryStream() {
    // colección plana de inventario (si existe)
    return FirebaseFirestore.instance
        .collection('inventory')
        .orderBy('numeroParte')
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _bodegasStream() {
    return FirebaseFirestore.instance
        .collection('bodegas')
        .orderBy('nombre')
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    final invStream = _inventoryStream();

    return Scaffold(
      appBar: AppBar(title: const Text('Almacén')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Buscar (Nº de parte / bodega / desc.)',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) =>
                  setState(() => _search = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: invStream,
              builder: (context, snap) {
                if (snap.hasError) {
                  // Si marca que no existe la colección, caemos a bodegas
                  _usingInventory = false;
                }
                if (!snap.hasData ||
                    snap.data!.docs.isEmpty ||
                    !_usingInventory) {
                  // fallback: mostrar bodegas
                  return _buildBodegas();
                }

                var docs = snap.data!.docs;
                if (_search.isNotEmpty) {
                  docs = docs.where((d) {
                    final data = d.data();
                    final np = (data['numeroParte'] ?? '')
                        .toString()
                        .toLowerCase();
                    final b = (data['bodega'] ?? '').toString().toLowerCase();
                    final desc = (data['descripcion'] ?? '')
                        .toString()
                        .toLowerCase();
                    return np.contains(_search) ||
                        b.contains(_search) ||
                        desc.contains(_search);
                  }).toList();
                }

                if (docs.isEmpty) {
                  return const Center(child: Text('Sin coincidencias.'));
                }

                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final d = docs[i].data();
                    final np = (d['numeroParte'] ?? '—').toString();
                    final desc = (d['descripcion'] ?? '').toString();
                    final bodega = (d['bodega'] ?? '').toString();
                    final qty = (d['qty'] ?? 0) as int;
                    final minQty = (d['minQty'] ?? 0) as int;
                    final low = minQty > 0 && qty < minQty;

                    return ListTile(
                      leading: CircleAvatar(child: Text(qty.toString())),
                      title: Text(np),
                      subtitle: Text(
                        [
                          desc,
                          if (bodega.isNotEmpty) 'Bodega: $bodega',
                        ].where((e) => e.isNotEmpty).join(' • '),
                      ),
                      trailing: low
                          ? const Chip(
                              label: Text('Bajo'),
                              backgroundColor: Color(0xFFFFE1E1),
                              labelStyle: TextStyle(color: Colors.red),
                            )
                          : null,
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

  Widget _buildBodegas() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _bodegasStream(),
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
            final nombre = (d.data()['nombre'] ?? '').toString().toLowerCase();
            return nombre.contains(_search);
          }).toList();
        }
        if (docs.isEmpty) {
          return const Center(child: Text('No hay bodegas.'));
        }
        return ListView.separated(
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final d = docs[i].data();
            final nombre = (d['nombre'] ?? 'Bodega').toString();
            final ubicacion = (d['ubicacion'] ?? '').toString();
            return ListTile(
              leading: const Icon(Icons.warehouse_outlined),
              title: Text(nombre),
              subtitle: Text(ubicacion),
            );
          },
        );
      },
    );
  }
}
