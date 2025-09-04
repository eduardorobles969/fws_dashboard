// lib/screens/new_project_part_screen.dart
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

class NewProjectPartScreen extends StatefulWidget {
  const NewProjectPartScreen({super.key});
  @override
  State<NewProjectPartScreen> createState() => _NewProjectPartScreenState();
}

class _NewProjectPartScreenState extends State<NewProjectPartScreen> {
  final _form = GlobalKey<FormState>();

  // null => crear proyecto; otro => id de proyecto existente
  String? _selectedProjectId;

  // Campos si es proyecto nuevo
  final _proyectoCtrl = TextEditingController();
  final _descProyectoCtrl = TextEditingController();

  bool _saving = false;

  /// Filas dinámicas
  final List<_PartRow> _rows = [_PartRow()];

  // ---------- DATA ----------
  Future<List<Map<String, dynamic>>> _getProjects() async {
    final qs = await FirebaseFirestore.instance
        .collection('projects')
        .where('activo', isEqualTo: true)
        .orderBy('proyecto')
        .get();
    return qs.docs
        .map((d) => {'id': d.id, 'proyecto': (d['proyecto'] ?? '').toString()})
        .toList();
  }

  Future<Set<String>> _getExistingPN(String projectId) async {
    final qs = await FirebaseFirestore.instance
        .collection('projects')
        .doc(projectId)
        .collection('parts')
        .get();
    return qs.docs
        .map((d) => (d.data()['numeroParte'] ?? '').toString().toUpperCase())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  // ---------- HELPERS ----------
  String _normPN(String s) =>
      s.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();

  List<_ParsedLine> _parseBulk(String raw) {
    final out = <_ParsedLine>[];
    for (final line in raw.split('\n')) {
      final clean = line.trim();
      if (clean.isEmpty) continue;

      List<String> parts;
      final byPipe = clean.split('|');
      final byComma = clean.split(',');
      final byTab = clean.split('\t');
      if (byPipe.length >= 2) {
        parts = [byPipe[0], byPipe.sublist(1).join('|')];
      } else if (byComma.length >= 2) {
        parts = [byComma[0], byComma.sublist(1).join(',')];
      } else if (byTab.length >= 2) {
        parts = [byTab[0], byTab.sublist(1).join('\t')];
      } else {
        parts = [clean, ''];
      }
      final pn = _normPN(parts[0]);
      final desc = parts[1].trim();
      if (pn.isNotEmpty) out.add(_ParsedLine(pn: pn, desc: desc));
    }
    return out;
  }

  // ---------- STORAGE ----------
  Future<String> _uploadFile({
    required String projectId,
    required String partDocId,
    required PlatformFile file,
    required String kind, // 'drawing' | 'solids'
  }) async {
    final storage = FirebaseStorage.instance;
    final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9_\.-]'), '_');
    final path = 'projects/$projectId/parts/$partDocId/$kind/$safeName';
    final ref = storage.ref().child(path);
    UploadTask task;
    if (kIsWeb) {
      task = ref.putData(file.bytes!);
    } else {
      task = ref.putFile(File(file.path!));
    }
    final snap = await task.whenComplete(() {});
    return snap.ref.getDownloadURL();
  }

  // ---------- SAVE ----------
  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;

    // 1) recolectar
    final entered = <_ParsedLine>[];
    for (final r in _rows) {
      final pn = _normPN(r.pn.text);
      if (pn.isNotEmpty) {
        entered.add(_ParsedLine(pn: pn, desc: r.desc.text.trim()));
      }
    }
    if (entered.isEmpty) {
      _snack('Agrega al menos un número de parte.');
      return;
    }

    setState(() => _saving = true);
    try {
      // 2) proyecto
      late DocumentReference projRef;
      if (_selectedProjectId == null) {
        if (_proyectoCtrl.text.trim().isEmpty) {
          _snack('Nombre del proyecto requerido.');
          setState(() => _saving = false);
          return;
        }
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

      // 3) dedup internos
      final map = <String, _ParsedLine>{};
      for (final e in entered) map[e.pn] = e;
      final unique = map.values.toList();

      // 4) dedup contra firestore
      final existing = _selectedProjectId != null
          ? await _getExistingPN(projRef.id)
          : <String>{};

      final toInsert = <_PendingPart>[];
      for (final p in unique) {
        if (existing.contains(p.pn)) continue;

        // recuperar fila original para qty/nesting/archivos
        final row = _rows.firstWhere(
          (r) => _normPN(r.pn.text) == p.pn,
          orElse: () => _PartRow(),
        );

        toInsert.add(
          _PendingPart(
            pn: p.pn,
            desc: p.desc,
            qty: math.max(0, int.tryParse(row.qty.text.trim()) ?? 0),
            nesting: row.nesting.text.trim(),
            drawing: row.drawing,
            solids: List<PlatformFile>.from(row.solids),
          ),
        );
      }

      if (toInsert.isEmpty) {
        _snack('No hay partes nuevas (todas duplicadas).');
        return;
      }

      // 5) guardar + uploads
      int ok = 0;
      for (final p in toInsert) {
        final pRef = projRef.collection('parts').doc();
        await pRef.set({
          'numeroParte': p.pn,
          'descripcionParte': p.desc,
          'cantidadPlan': p.qty,
          'nesting': p.nesting, // texto libre
          'nestGroupId': null, // se asigna en BOM al agrupar
          'nestStatus': 'pendiente', // se gestiona en BOM
          'materialComprado': false, // se gestiona en BOM
          'activo': true,
          'createdAt': FieldValue.serverTimestamp(),
        });

        String? drawingUrl, drawingName;
        if (p.drawing != null) {
          drawingUrl = await _uploadFile(
            projectId: projRef.id,
            partDocId: pRef.id,
            file: p.drawing!,
            kind: 'drawing',
          );
          drawingName = p.drawing!.name;
        }

        final solidUrls = <String>[];
        final solidNames = <String>[];
        for (final s in p.solids) {
          final url = await _uploadFile(
            projectId: projRef.id,
            partDocId: pRef.id,
            file: s,
            kind: 'solids',
          );
          solidUrls.add(url);
          solidNames.add(s.name);
        }

        if (drawingUrl != null || solidUrls.isNotEmpty) {
          await pRef.update({
            if (drawingUrl != null) 'drawingUrl': drawingUrl,
            if (drawingUrl != null) 'drawingName': drawingName,
            if (solidUrls.isNotEmpty) 'solidUrls': solidUrls,
            if (solidUrls.isNotEmpty) 'solidNames': solidNames,
          });
        }
        ok++;
      }

      if (!mounted) return;
      _snack('Guardadas $ok parte(s).');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) _snack('Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------- UI ----------
  @override
  void dispose() {
    _proyectoCtrl.dispose();
    _descProyectoCtrl.dispose();
    for (final r in _rows) r.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alta proyecto / Nº de parte')),
      body: AbsorbPointer(
        absorbing: _saving,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _getProjects(),
          builder: (context, snap) {
            final projects = snap.data ?? const [];
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _form,
                child: ListView(
                  children: [
                    // Proyecto
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Proyecto',
                        border: OutlineInputBorder(),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          value: _selectedProjectId,
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('➕ Nuevo proyecto…'),
                            ),
                            ...projects.map(
                              (p) => DropdownMenuItem(
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

                    if (_selectedProjectId == null) ...[
                      TextFormField(
                        controller: _proyectoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Nombre del proyecto',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Requerido'
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
                        TextButton.icon(
                          onPressed: () async {
                            final pasted = await showDialog<String>(
                              context: context,
                              builder: (_) => const _PasteDialog(),
                            );
                            if (pasted == null || pasted.trim().isEmpty) return;
                            final parsed = _parseBulk(pasted);
                            if (parsed.isEmpty) {
                              _snack('No se detectaron P/N válidos.');
                              return;
                            }
                            setState(() {
                              for (final p in parsed) {
                                final r = _PartRow();
                                r.pn.text = p.pn;
                                r.desc.text = p.desc;
                                _rows.add(r);
                              }
                            });
                          },
                          icon: const Icon(Icons.content_paste),
                          label: const Text('Pegar lista'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    ..._rows.asMap().entries.map((e) {
                      final idx = e.key;
                      final row = e.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: TextFormField(
                                    controller: row.pn,
                                    textCapitalization:
                                        TextCapitalization.characters,
                                    decoration: InputDecoration(
                                      labelText: 'Nº de parte ${idx + 1}',
                                      border: const OutlineInputBorder(),
                                    ),
                                    onChanged: (v) {
                                      final caret = row.pn.selection;
                                      row.pn.value = row.pn.value.copyWith(
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
                                    controller: row.desc,
                                    decoration: const InputDecoration(
                                      labelText: 'Descripción (opcional)',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 110,
                                  child: TextFormField(
                                    controller: row.qty,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Cantidad',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Quitar fila',
                                  onPressed: _rows.length == 1
                                      ? null
                                      : () =>
                                            setState(() => _rows.removeAt(idx)),
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),

                            // Nesting (TEXTO ÚNICO)
                            TextFormField(
                              controller: row.nesting,
                              decoration: const InputDecoration(
                                labelText: 'Nesting (texto)',
                                hintText: 'p.ej. “bloque 4x4x4 / A36”',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 8),

                            // Archivos
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final pick = await FilePicker.platform
                                        .pickFiles(
                                          type: FileType.custom,
                                          allowedExtensions: [
                                            'jpg',
                                            'jpeg',
                                            'pdf',
                                          ],
                                          withData: kIsWeb,
                                        );
                                    if (pick != null && pick.files.isNotEmpty) {
                                      setState(
                                        () => row.drawing = pick.files.first,
                                      );
                                    }
                                  },
                                  icon: const Icon(
                                    Icons.picture_as_pdf_outlined,
                                  ),
                                  label: const Text('Plano (.jpg/.pdf)'),
                                ),
                                if (row.drawing != null)
                                  Chip(
                                    label: Text(row.drawing!.name),
                                    onDeleted: () =>
                                        setState(() => row.drawing = null),
                                  ),
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final pick = await FilePicker.platform
                                        .pickFiles(
                                          type: FileType.custom,
                                          allowMultiple: true,
                                          allowedExtensions: ['x_t', 'step'],
                                          withData: kIsWeb,
                                        );
                                    if (pick != null && pick.files.isNotEmpty) {
                                      setState(
                                        () => row.solids.addAll(pick.files),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.view_in_ar_outlined),
                                  label: const Text('Sólido (.x_t/.step)'),
                                ),
                                ...row.solids.asMap().entries.map(
                                  (s) => Chip(
                                    label: Text(s.value.name),
                                    onDeleted: () => setState(
                                      () => row.solids.removeAt(s.key),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 22),
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

                    const SizedBox(height: 8),
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

// ------- helpers -------
class _PartRow {
  final TextEditingController pn = TextEditingController();
  final TextEditingController desc = TextEditingController();
  final TextEditingController qty = TextEditingController();
  final TextEditingController nesting = TextEditingController();

  PlatformFile? drawing;
  final List<PlatformFile> solids = [];

  void dispose() {
    pn.dispose();
    desc.dispose();
    qty.dispose();
    nesting.dispose();
  }
}

class _ParsedLine {
  final String pn;
  final String desc;
  _ParsedLine({required this.pn, required this.desc});
}

class _PendingPart {
  final String pn;
  final String desc;
  final int qty;
  final String nesting;
  final PlatformFile? drawing;
  final List<PlatformFile> solids;
  _PendingPart({
    required this.pn,
    required this.desc,
    required this.qty,
    required this.nesting,
    required this.drawing,
    required this.solids,
  });
}

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
                'Una por línea. Formatos:\n'
                'PN | Descripción\n'
                'PN, Descripción\n'
                'PN<TAB>Descripción\n'
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
