import 'dart:io' show File;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:math' as math;

/// Alta de proyecto y carga masiva de números de parte.
/// - Puede crear proyecto nuevo o agregar partes a uno existente.
/// - Pegar lista masiva: "PN | Descripción" (o coma, TAB, solo PN)
/// - Cada parte ahora trae:
///   * cantidadPlan (BOM)
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

  // =================== STORAGE ===================

  Future<String> _uploadFile({
    required String projectId,
    required String partDocId,
    required PlatformFile file,
    required String kind, // 'drawing' | 'solid'
  }) async {
    final storage = FirebaseStorage.instance;
    final ext = (file.extension ?? '').toLowerCase();
    final safeName = (file.name).replaceAll(RegExp(r'[^a-zA-Z0-9_\.-]'), '_');

    final path =
        'projects/$projectId/parts/$partDocId/$kind/$safeName'; // ruta clara

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
        uniqueMap[p.pn] = p; // la última descripción gana
      }
      final uniqueList = uniqueMap.values.toList();

      // 4) Deduplicar contra Firestore si aplica
      final existing = _selectedProjectId != null
          ? await _getExistingPartNumbers(projRef.id)
          : <String>{};
      final toInsert = <_PendingPart>[];

      for (final parsed in uniqueList) {
        if (existing.contains(parsed.pn)) continue;
        // Busca la fila UI correspondiente para extraer qty/archivos
        final row = _rows.firstWhere(
          (r) => _normPN(r.numeroCtrl.text) == parsed.pn,
          orElse: () => _PartRow(),
        );
        final qty = int.tryParse(row.cantidadCtrl.text.trim()) ?? 0;

        toInsert.add(
          _PendingPart(
            pn: parsed.pn,
            desc: parsed.desc,
            qty: math.max(0, qty),
            drawing: row.drawing,
            solids: List<PlatformFile>.from(row.solids),
          ),
        );
      }

      if (toInsert.isEmpty) {
        _snack('No hay partes nuevas para guardar (todas duplicadas).');
        return;
      }

      // 5) Guardado por parte + uploads
      // Nota: usamos set+update por cada doc para tener el ID antes de subir archivos.
      int ok = 0;
      for (final p in toInsert) {
        final pRef = projRef.collection('parts').doc();
        await pRef.set({
          'numeroParte': p.pn,
          'descripcionParte': p.desc,
          'cantidadPlan': p.qty,
          'activo': true,
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Upload plano (opcional)
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

        // Upload sólidos (opcional, múltiples)
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

        // Update con URLs si hay algo
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

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

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
                                      // normaliza visualmente en tiempo real (opcional)
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

/// Fila de captura + archivos + BOM
class _PartRow {
  final TextEditingController numeroCtrl = TextEditingController();
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController cantidadCtrl = TextEditingController();

  PlatformFile? drawing; // jpg/pdf
  final List<PlatformFile> solids = []; // x_t / step (múltiples)

  void dispose() {
    numeroCtrl.dispose();
    descCtrl.dispose();
    cantidadCtrl.dispose();
  }
}

/// Resultado del parseo de una línea pegada
class _ParsedLine {
  final String pn;
  final String desc;
  _ParsedLine({required this.pn, required this.desc});
}

/// Estructura interna para guardar y subir
class _PendingPart {
  final String pn;
  final String desc;
  final int qty;
  final PlatformFile? drawing;
  final List<PlatformFile> solids;
  _PendingPart({
    required this.pn,
    required this.desc,
    required this.qty,
    required this.drawing,
    required this.solids,
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
