import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Alta de proyecto y carga masiva de números de parte.
/// - Puede crear un proyecto nuevo o agregar partes a uno existente.
/// - Permite pegar una lista masiva ("PN | Descripción" separados por coma, tab o barra vertical).
/// - Normaliza PN, evita duplicados (internos y contra Firestore) y guarda en batch.
class NewProjectPartScreen extends StatefulWidget {
  const NewProjectPartScreen({super.key});

  @override
  State<NewProjectPartScreen> createState() => _NewProjectPartScreenState();
}

class _NewProjectPartScreenState extends State<NewProjectPartScreen> {
  final _form = GlobalKey<FormState>();

  /// null => crear proyecto nuevo; de lo contrario, id de proyecto existente
  String? _selectedProjectId;

  // Campos de proyecto (solo visibles si es nuevo)
  final _proyectoCtrl = TextEditingController();
  final _descProyectoCtrl = TextEditingController();

  bool _saving = false;

  /// Filas dinámicas de números de parte
  final List<_PartRow> _rows = [_PartRow()];

  // =================== DATA ===================

  /// Proyectos activos para el dropdown
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

  /// Obtiene TODOS los PN existentes en el proyecto (para deduplicar rápido)
  Future<Set<String>> _getExistingPartNumbers(String projectId) async {
    final qs = await FirebaseFirestore.instance
        .collection('projects')
        .doc(projectId)
        .collection('parts')
        // sin orderBy -> no requiere índice
        .get();

    return qs.docs
        .map((d) => (d.data()['numeroParte'] ?? '').toString().toUpperCase())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  // =================== HELPERS ===================

  /// Normaliza el PN para mantener consistencia
  String _normPN(String s) {
    final trimmed = s.trim();
    // colapsar espacios múltiples y llevar a mayúsculas
    return trimmed.replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
  }

  /// Intenta parsear varias líneas pegadas: "PN[,| | \t | |] Descripción"
  /// Acepta:  CHM-1022-C1842 | COPLE 42MM X 18
  ///          FVF-0100-HF1-010, HERRAMIENTAL FRANKLIN 1
  ///          ABC123<TAB>Base izquierda
  List<_ParsedLine> _parseBulk(String raw) {
    final lines = raw.split('\n');
    final out = <_ParsedLine>[];
    for (final line in lines) {
      final clean = line.trim();
      if (clean.isEmpty) continue;

      // separadores: |  ,  \t (en ese orden)
      final byPipe = clean.split('|');
      final byComma = clean.split(',');
      final byTab = clean.split('\t');

      List<String> parts;
      if (byPipe.length >= 2) {
        parts = [byPipe[0], byPipe.sublist(1).join('|')];
      } else if (byComma.length >= 2) {
        parts = [byComma[0], byComma.sublist(1).join(',')];
      } else if (byTab.length >= 2) {
        parts = [byTab[0], byTab.sublist(1).join('\t')];
      } else {
        // solo PN
        parts = [clean, ''];
      }

      final pn = _normPN(parts[0]);
      final desc = parts[1].trim();
      if (pn.isNotEmpty) out.add(_ParsedLine(pn: pn, desc: desc));
    }
    return out;
  }

  // =================== SAVE ===================

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;

    // 1) Recolectar filas no vacías y normalizadas
    final entered = <_ParsedLine>[];
    for (final r in _rows) {
      final pn = _normPN(r.numeroCtrl.text);
      final desc = r.descCtrl.text.trim();
      if (pn.isNotEmpty) {
        entered.add(_ParsedLine(pn: pn, desc: desc));
      }
    }
    if (entered.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agrega al menos un número de parte.')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      // 2) Proyecto destino (crea si no existe)
      DocumentReference projRef;
      if (_selectedProjectId == null) {
        projRef = FirebaseFirestore.instance.collection('projects').doc();
        await projRef.set({
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

      // 3) Deduplicar internos (mismo PN repetido en la pantalla)
      final uniqueMap = <String, _ParsedLine>{};
      for (final p in entered) {
        uniqueMap[p.pn] = p; // la última descripción gana
      }
      var uniqueList = uniqueMap.values.toList();

      // 4) Deduplicar contra Firestore del proyecto (si es existente)
      final existing = _selectedProjectId != null
          ? await _getExistingPartNumbers(projRef.id)
          : <String>{};
      final toInsert = uniqueList
          .where((p) => !existing.contains(p.pn))
          .toList();
      final skippedCount = uniqueList.length - toInsert.length;

      if (toInsert.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No hay partes nuevas para guardar (todas duplicadas).',
            ),
          ),
        );
        return;
      }

      // 5) Batch write
      final batch = FirebaseFirestore.instance.batch();
      for (final p in toInsert) {
        final pRef = projRef.collection('parts').doc();
        batch.set(pRef, {
          'numeroParte': p.pn,
          'descripcionParte': p.desc,
          'activo': true,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Guardadas ${toInsert.length} parte(s) '
            '${skippedCount > 0 ? ' • Omitidas por duplicado: $skippedCount' : ''}',
          ),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // =================== UI ===================

  @override
  void dispose() {
    _proyectoCtrl.dispose();
    _descProyectoCtrl.dispose();
    for (final r in _rows) {
      r.dispose();
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
                    // Selector de proyecto
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
                            if (v == null) {
                              _proyectoCtrl.clear();
                              _descProyectoCtrl.clear();
                            }
                          }),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Campos de proyecto (solo si es nuevo)
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
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Números de parte',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        // Botón "Pegar lista"
                        TextButton.icon(
                          onPressed: () async {
                            final pasted = await showDialog<String>(
                              context: context,
                              builder: (_) => const _PasteDialog(),
                            );
                            if (pasted == null || pasted.trim().isEmpty) return;

                            final parsed = _parseBulk(pasted);
                            if (parsed.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'No se detectaron P/N válidos.',
                                  ),
                                ),
                              );
                              return;
                            }

                            setState(() {
                              for (final p in parsed) {
                                final row = _PartRow();
                                row.numeroCtrl.text = p.pn;
                                row.descCtrl.text = p.desc;
                                _rows.add(row);
                              }
                            });
                          },
                          icon: const Icon(Icons.content_paste),
                          label: const Text('Pegar lista'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Filas dinámicas
                    ..._rows.asMap().entries.map((e) {
                      final idx = e.key;
                      final row = e.value;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 4,
                              child: TextFormField(
                                controller: row.numeroCtrl,
                                textCapitalization:
                                    TextCapitalization.characters,
                                decoration: InputDecoration(
                                  labelText: 'Nº de parte ${idx + 1}',
                                  border: const OutlineInputBorder(),
                                ),
                                onChanged: (v) {
                                  // normaliza visualmente en tiempo real (opcional)
                                  final caret = row.numeroCtrl.selection;
                                  row.numeroCtrl.value = row.numeroCtrl.value
                                      .copyWith(
                                        text: _normPN(v),
                                        selection: caret,
                                        composing: TextRange.empty,
                                      );
                                },
                                validator: (v) {
                                  if (idx == 0 &&
                                      (v == null || v.trim().isEmpty)) {
                                    return 'Requerido';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
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

/// Helper: fila de captura
class _PartRow {
  final TextEditingController numeroCtrl = TextEditingController();
  final TextEditingController descCtrl = TextEditingController();

  void dispose() {
    numeroCtrl.dispose();
    descCtrl.dispose();
  }
}

/// Resultado del parseo de una línea pegada
class _ParsedLine {
  final String pn;
  final String desc;
  _ParsedLine({required this.pn, required this.desc});
}

/// Diálogo para pegar texto masivo
class _PasteDialog extends StatefulWidget {
  const _PasteDialog();

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _textCtrl = TextEditingController();

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pegar lista de P/N'),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _textCtrl,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText:
                'Una por línea. Formatos válidos:\n'
                'PN | Descripción\n'
                'PN, Descripción\n'
                'PN<tab>Descripción\n'
                'PN (solo PN)',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton.icon(
          onPressed: () => Navigator.pop(context, _textCtrl.text),
          icon: const Icon(Icons.content_paste_go),
          label: const Text('Agregar'),
        ),
      ],
    );
  }
}
