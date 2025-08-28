import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class NewProjectPartScreen extends StatefulWidget {
  const NewProjectPartScreen({super.key});

  @override
  State<NewProjectPartScreen> createState() => _NewProjectPartScreenState();
}

class _NewProjectPartScreenState extends State<NewProjectPartScreen> {
  final _form = GlobalKey<FormState>();

  // modo: usar existente o crear nuevo
  String? _selectedProjectId; // null => "Nuevo proyecto"
  final _proyectoCtrl = TextEditingController();
  final _descProyectoCtrl = TextEditingController();

  bool _saving = false;

  // filas dinámicas de partes
  final List<_PartRow> _rows = [_PartRow()];

  // ====== carga de proyectos existentes (activos) ======
  Future<List<Map<String, dynamic>>> _getProjects() async {
    final qs = await FirebaseFirestore.instance
        .collection('projects')
        .where('activo', isEqualTo: true)
        .orderBy('proyecto')
        .get();
    return qs.docs
        .map((d) => {'id': d.id, 'proyecto': (d['proyecto'] ?? '') as String})
        .toList();
  }

  // ====== guardar ======
  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;

    // Debe haber al menos un P/N válido
    final validParts = _rows.where((r) => r.numeroCtrl.text.trim().isNotEmpty);
    if (validParts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agrega al menos un número de parte.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final batch = FirebaseFirestore.instance.batch();

      // 1) Proyecto destino
      DocumentReference projRef;
      if (_selectedProjectId == null) {
        // nuevo
        projRef = FirebaseFirestore.instance.collection('projects').doc();
        batch.set(projRef, {
          'proyecto': _proyectoCtrl.text.trim(),
          'descripcionProyecto': _descProyectoCtrl.text.trim(),
          'activo': true,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        projRef = FirebaseFirestore.instance
            .collection('projects')
            .doc(_selectedProjectId);
      }

      // 2) Partes (N filas)
      for (final row in validParts) {
        final pRef = projRef.collection('parts').doc();
        batch.set(pRef, {
          'numeroParte': row.numeroCtrl.text.trim(),
          'descripcionParte': row.descCtrl.text.trim(),
          'activo': true,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _selectedProjectId == null
                ? 'Proyecto y ${validParts.length} parte(s) guardados'
                : '${validParts.length} parte(s) agregadas al proyecto',
          ),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _proyectoCtrl.dispose();
    _descProyectoCtrl.dispose();
    for (final r in _rows) {
      r.numeroCtrl.dispose();
      r.descCtrl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alta proyecto / Nº de parte')),
      body: AbsorbPointer(
        absorbing: _saving,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _getProjects(),
          builder: (context, snap) {
            final projects = (snap.data ?? const <Map<String, dynamic>>[]);

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _form,
                child: ListView(
                  children: [
                    // selector proyecto
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Proyecto',
                        border: OutlineInputBorder(),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          value: _selectedProjectId, // null = nuevo
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('➕ Nuevo proyecto…'),
                            ),
                            ...projects.map(
                              (p) => DropdownMenuItem<String?>(
                                value: p['id'] as String,
                                child: Text(p['proyecto'] as String),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() {
                            _selectedProjectId = v;
                            // si es nuevo, limpiamos
                            if (v == null) {
                              _proyectoCtrl.clear();
                              _descProyectoCtrl.clear();
                            }
                          }),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    if (_selectedProjectId == null) ...[
                      TextFormField(
                        controller: _proyectoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Nombre del proyecto',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Requerido para proyecto nuevo'
                            : null,
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _descProyectoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Descripción del proyecto (opcional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                    ],

                    const SizedBox(height: 8),
                    const Text(
                      'Números de parte',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // tabla de filas dinámicas
                    ..._rows.asMap().entries.map((e) {
                      final idx = e.key;
                      final row = e.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            // Nº de parte
                            Expanded(
                              flex: 4,
                              child: TextFormField(
                                controller: row.numeroCtrl,
                                decoration: InputDecoration(
                                  labelText: 'Nº de parte ${idx + 1}',
                                  border: const OutlineInputBorder(),
                                ),
                                validator: (v) {
                                  // sólo valida la 1ª fila; el resto se filtra al guardar
                                  if (idx == 0 &&
                                      (v == null || v.trim().isEmpty)) {
                                    return 'Requerido';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            // descripción
                            Expanded(
                              flex: 5,
                              child: TextFormField(
                                controller: row.descCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Descripción (opcional)',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // eliminar
                            IconButton(
                              tooltip: 'Quitar fila',
                              onPressed: _rows.length == 1
                                  ? null
                                  : () => setState(() => _rows.removeAt(idx)),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                          ],
                        ),
                      );
                    }),

                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _rows.add(_PartRow())),
                        icon: const Icon(Icons.add),
                        label: const Text('Agregar otra parte'),
                      ),
                    ),

                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save),
                      label: Text(_saving ? 'Guardando…' : 'Guardar'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// Helper: una fila de captura
class _PartRow {
  final TextEditingController numeroCtrl = TextEditingController();
  final TextEditingController descCtrl = TextEditingController();
}
