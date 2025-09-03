import 'dart:io' show File;
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Alta de proyecto y carga masiva de números de parte.
/// - Puede crear proyecto nuevo o agregar partes a uno existente.
/// - Pegar lista masiva: "PN | Descripción | BOM | Nesting1 | Nesting2"
///   (también con coma o TAB; las columnas 3, 4 y 5 son opcionales)
/// - Cada parte ahora trae:
///   * cantidadPlan (BOM)
///   * nesting1, nesting2 (texto)
///   * plano (jpg/pdf)
///   * sólidos (x_t/step, múltiples)
/// - Archivos se suben a Storage y se guardan sus URLs en el doc.
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

  /// Intenta parsear varias líneas pegadas:
  /// Soporta separadores |  ,  TAB
  /// Columnas: PN | Descripción | BOM | Nesting1 | Nesting2  (3..5 columnas)
  List<_ParsedLine> _parseBulk(String raw) {
    final lines = raw.split('\n');
    final out = <_ParsedLine>[];
    for (final line in lines) {
      final clean = line.trim();
      if (clean.isEmpty) continue;

      List<String> cols;
      if (clean.contains('|')) {
        cols = clean.split('|');
      } else if (clean.contains('\t')) {
        cols = clean.split('\t');
      } else if (clean.contains(',')) {
        cols = clean.split(',');
      } else {
        cols = [clean]; // solo PN
      }

      // normaliza: recorta espacios de cada celda
      cols = cols.map((c) => c.trim()).toList();

      final pn = _normPN(cols.isNotEmpty ? cols[0] : '');
      if (pn.isEmpty) continue;

      final desc = cols.length >= 2 ? cols[1] : '';
      final qty = (cols.length >= 3 ? int.tryParse(cols[2]) : null) ?? 0;
      final nesting1 = cols.length >= 4 ? cols[3] : '';
      final nesting2 = cols.length >= 5 ? cols[4] : '';

      out.add(
        _ParsedLine(
          pn: pn,
          desc: desc,
          qty: qty,
          nesting1: nesting1,
          nesting2: nesting2,
        ),
      );
    }
    return out;
  }

  // =================== STORAGE ===================

  Future<String> _uploadFile({
    required String projectId,
    required String partDocId,
    required PlatformFile file,
    required String kind, // 'drawing' | 'solids'
  }) async {
    final storage = FirebaseStorage.instance;
    final safeName = (file.name).replaceAll(RegExp(r'[^a-zA-Z0-9_\.-]'), '_');
    final path = 'projects/$projectId/parts/$partDocId/$kind/$safeName';
    final ref = storage.ref().child(path);

    UploadTask task;
    if (kIsWeb) {
      task = ref.putData(file.bytes!);
    } else {
      task = ref.putFile(File(file.path!));
    }

    final snap = await task.whenComplete(() {});
    return await snap.ref.getDownloadURL();
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // =================== SAVE ===================

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;

    // 1) Recolectar filas no vacías y normalizadas
    final entered = <_ParsedLine>[];
    for (final r in _rows) {
      final pn = _normPN(r.numeroCtrl.text);
      final desc = r.descCtrl.text.trim();
      // si hay qty/nesting escritos en UI, los tomamos
      final qtyUI = int.tryParse(r.cantidadCtrl.text.trim());
      final nesting1UI = r.nesting1Ctrl.text.trim();
      final nesting2UI = r.nesting2Ctrl.text.trim();

      if (pn.isNotEmpty) {
        entered.add(
          _ParsedLine(
            pn: pn,
            desc: desc,
            qty: qtyUI ?? 0,
            nesting1: nesting1UI,
            nesting2: nesting2UI,
          ),
        );
      }
    }
    if (entered.isEmpty) {
      _snack('Agrega al menos un número de parte.');
      return;
    }

    setState(() => _saving = true);

    try {
      // 2) Proyecto destino (crea si no existe)
      DocumentReference projRef;
      if (_selectedProjectId == null) {
        if (_proyectoCtrl.text.trim().isEmpty) {
          _snack('Nombre de proyecto requerido.');
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

      // 3) Deduplicar internos
      final uniqueMap = <String, _ParsedLine>{};
      for (final p in entered) {
        uniqueMap[p.pn] = p; // la última línea para mismo PN gana
      }
      final uniqueList = uniqueMap.values.toList();

      // 4) Deduplicar contra Firestore si aplica
      final existing = _selectedProjectId != null
          ? await _getExistingPartNumbers(projRef.id)
          : <String>{};

      // 5) Transformar a _PendingPart y guardar
      int ok = 0;
      for (final parsed in uniqueList) {
        if (existing.contains(parsed.pn)) continue;

        // localiza la fila UI real (para archivos)
        final row = _rows.firstWhere(
          (r) => _normPN(r.numeroCtrl.text) == parsed.pn,
          orElse: () => _PartRow(),
        );

        final qty =
            (int.tryParse(row.cantidadCtrl.text.trim()) ??
            parsed.qty); // prioridad UI
        final nesting1 =
            (row.nesting1Ctrl.text.trim().isNotEmpty
                    ? row.nesting1Ctrl.text
                    : parsed.nesting1)
                .trim();
        final nesting2 =
            (row.nesting2Ctrl.text.trim().isNotEmpty
                    ? row.nesting2Ctrl.text
                    : parsed.nesting2)
                .trim();

        final pRef = projRef.collection('parts').doc();
        await pRef.set({
          'numeroParte': parsed.pn,
          'descripcionParte': parsed.desc,
          'cantidadPlan': math.max(0, qty),
          if (nesting1.isNotEmpty) 'nesting1': nesting1,
          if (nesting2.isNotEmpty) 'nesting2': nesting2,
          'activo': true,
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Upload plano (opcional)
        String? drawingUrl, drawingName;
        if (row.drawing != null) {
          drawingUrl = await _uploadFile(
            projectId: projRef.id,
            partDocId: pRef.id,
            file: row.drawing!,
            kind: 'drawing',
          );
          drawingName = row.drawing!.name;
        }

        // Upload sólidos (opcional, múltiples)
        final solidUrls = <String>[];
        final solidNames = <String>[];
        for (final s in row.solids) {
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
      if (!mounted) return;
      _snack('Error: $e');
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
                              _snack('No se detectaron P/N válidos.');
                              return;
                            }

                            setState(() {
                              for (final p in parsed) {
                                final row = _PartRow();
                                row.numeroCtrl.text = p.pn;
                                row.descCtrl.text = p.desc;
                                if (p.qty > 0) {
                                  row.cantidadCtrl.text = p.qty.toString();
                                }
                                row.nesting1Ctrl.text = p.nesting1;
                                row.nesting2Ctrl.text = p.nesting2;
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
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
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
                                      // normaliza visualmente
                                      final caret = row.numeroCtrl.selection;
                                      row.numeroCtrl.value = row
                                          .numeroCtrl
                                          .value
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
                                SizedBox(
                                  width: 110,
                                  child: TextFormField(
                                    controller: row.cantidadCtrl,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'BOM',
                                      helperText: '',
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
                            // Nesting
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: row.nesting1Ctrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Nesting (caso 1)',
                                      hintText: 'p. ej. bloque 4x4x4 / A36',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextFormField(
                                    controller: row.nesting2Ctrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Nesting (caso 2)',
                                      hintText: 'p. ej. bloque 4x4x16 / A36',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                              ],
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
                                          withData: kIsWeb, // bytes en web
                                        );
                                    if (pick != null && pick.files.isNotEmpty) {
                                      setState(() {
                                        row.drawing = pick.files.first;
                                      });
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
                                      setState(() {
                                        row.solids.addAll(pick.files);
                                      });
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
                            const Divider(height: 20),
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

/// Fila de captura + archivos + BOM + Nesting
class _PartRow {
  final TextEditingController numeroCtrl = TextEditingController();
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController cantidadCtrl = TextEditingController();
  final TextEditingController nesting1Ctrl = TextEditingController();
  final TextEditingController nesting2Ctrl = TextEditingController();

  PlatformFile? drawing; // jpg/pdf
  final List<PlatformFile> solids = []; // x_t / step (múltiples)

  void dispose() {
    numeroCtrl.dispose();
    descCtrl.dispose();
    cantidadCtrl.dispose();
    nesting1Ctrl.dispose();
    nesting2Ctrl.dispose();
  }
}

/// Resultado del parseo de una línea pegada
class _ParsedLine {
  final String pn;
  final String desc;
  final int qty;
  final String nesting1;
  final String nesting2;
  _ParsedLine({
    required this.pn,
    required this.desc,
    required this.qty,
    required this.nesting1,
    required this.nesting2,
  });
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
        width: 520,
        child: TextField(
          controller: _textCtrl,
          maxLines: 12,
          decoration: const InputDecoration(
            hintText:
                'Una por línea. Formatos válidos (usa |, , o TAB):\n'
                'PN | Descripción\n'
                'PN | Descripción | BOM\n'
                'PN | Descripción | BOM | Nesting1\n'
                'PN | Descripción | BOM | Nesting1 | Nesting2\n'
                'Ej: BS-0086-EV-001 | Válvula 1 | 3 | bloque 4x4x4 / A36 | bloque 4x4x16 / A36',
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
