import 'dart:io' show File;
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Alta de proyecto y carga masiva de números de parte.
class NewProjectPartScreen extends StatefulWidget {
  const NewProjectPartScreen({super.key});

  @override
  State<NewProjectPartScreen> createState() => _NewProjectPartScreenState();
}

class _NewProjectPartScreenState extends State<NewProjectPartScreen> {
  final _form = GlobalKey<FormState>();

  String? _selectedProjectId;

  // Campos de proyecto (solo visibles si es nuevo)
  final _proyectoCtrl = TextEditingController();
  final _descProyectoCtrl = TextEditingController();

  bool _saving = false;

  /// Filas dinámicas de números de parte
  final List<_PartRow> _rows = [_PartRow()];

  // =================== MATERIALS ===================
  late Future<List<_MaterialDoc>> _materialsFuture;

  @override
  void initState() {
    super.initState();
    _materialsFuture = _getMaterials();
  }

  Future<List<_MaterialDoc>> _getMaterials() async {
    final qs = await FirebaseFirestore.instance
        .collection('materials')
        .orderBy('sort')
        .get();

    return qs.docs
        .map((d) {
          final m = d.data();
          final active = (m['active'] ?? true) == true;
          if (!active) return null;
          return _MaterialDoc(
            id: d.id,
            code: (m['code'] ?? '').toString(),
            desc: (m['desc'] ?? '').toString(),
            colorHex: (m['color'] ?? '').toString(),
            ref: d.reference,
          );
        })
        .whereType<_MaterialDoc>()
        .toList();
  }

  // =================== DATA ===================

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

  String _normPN(String s) {
    final trimmed = s.trim();
    return trimmed.replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
  }

  List<_ParsedLine> _parseBulk(String raw) {
    final lines = raw.split('\n');
    final out = <_ParsedLine>[];
    for (final line in lines) {
      final clean = line.trim();
      if (clean.isEmpty) continue;

      List<String> parts;
      if (clean.contains('|')) {
        parts = clean.split('|').map((s) => s.trim()).toList();
      } else if (clean.contains(',')) {
        parts = clean.split(',').map((s) => s.trim()).toList();
      } else if (clean.contains('\t')) {
        parts = clean.split('\t').map((s) => s.trim()).toList();
      } else {
        parts = [clean];
      }

      final pn = _normPN(parts[0]);
      String desc = '';
      int? qty;

      if (parts.length >= 2) desc = parts[1];
      if (parts.length >= 3) {
        final qTry = int.tryParse(parts[2]);
        if (qTry != null && qTry >= 0) qty = qTry;
      }

      if (pn.isNotEmpty) out.add(_ParsedLine(pn: pn, desc: desc, qty: qty));
    }
    return out;
  }

  _PartRow? _rowForPn(String pn) {
    for (final r in _rows) {
      if (_normPN(r.numeroCtrl.text) == pn) return r;
    }
    return null;
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

  // =================== SAVE ===================

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;

    final entered = <_ParsedLine>[];
    for (final r in _rows) {
      final pn = _normPN(r.numeroCtrl.text);
      final desc = r.descCtrl.text.trim();
      if (pn.isNotEmpty) {
        int? qty;
        if (r.cantidadCtrl.text.trim().isNotEmpty) {
          qty = int.tryParse(r.cantidadCtrl.text.trim());
        }
        entered.add(_ParsedLine(pn: pn, desc: desc, qty: qty));
      }
    }
    if (entered.isEmpty) {
      _snack('Agrega al menos un número de parte.');
      return;
    }

    setState(() => _saving = true);

    try {
      // Proyecto
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

      // Deduplicaciones
      final uniqueMap = <String, _ParsedLine>{};
      for (final p in entered) {
        uniqueMap[p.pn] = p;
      }
      final uniqueList = uniqueMap.values.toList();

      final existing = _selectedProjectId != null
          ? await _getExistingPartNumbers(projRef.id)
          : <String>{};
      final toInsert = <_PendingPart>[];

      for (final parsed in uniqueList) {
        if (existing.contains(parsed.pn)) continue;

        final row = _rowForPn(parsed.pn);
        final qtyFromRow =
            int.tryParse(row?.cantidadCtrl.text.trim() ?? '') ?? 0;
        final qty = parsed.qty ?? qtyFromRow;

        final drawingLink = row?.drawingLinkCtrl.text.trim();
        final solidsLinks = <String>[];
        final solidsTxt = row?.solidsLinkCtrl.text.trim() ?? '';
        if (solidsTxt.isNotEmpty) {
          solidsTxt
              .split(RegExp(r"[\n,;]+"))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .forEach(solidsLinks.add);
        }

        toInsert.add(
          _PendingPart(
            pn: parsed.pn,
            desc: parsed.desc,
            qty: math.max(0, qty),
            drawing: row?.drawing,
            solids: List<PlatformFile>.from(row?.solids ?? const []),
            nestDim: row?.nestCtrl.text.trim() ?? '',
            materialDocId: row?.materialDocId,
            drawingLink: (drawingLink != null && drawingLink.isNotEmpty)
                ? drawingLink
                : null,
            solidLinks: solidsLinks,
          ),
        );
      }

      if (toInsert.isEmpty) {
        _snack('No hay partes nuevas para guardar (todas duplicadas).');
        return;
      }

      int ok = 0;
      for (final p in toInsert) {
        final pRef = projRef.collection('parts').doc();
        final data = <String, dynamic>{
          'numeroParte': p.pn,
          'descripcionParte': p.desc,
          'cantidadPlan': p.qty,
          'activo': true,
          'createdAt': FieldValue.serverTimestamp(),
        };
        if (p.nestDim.isNotEmpty) data['nestDim'] = p.nestDim;
        if (p.materialDocId != null && p.materialDocId!.isNotEmpty) {
          final matRef = FirebaseFirestore.instance
              .collection('materials')
              .doc(p.materialDocId);
          data['materialRef'] = matRef;
          final matSnap = await matRef.get();
          data['materialCode'] = (matSnap.data()?['code'] ?? '').toString();
        }

        await pRef.set(data);

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

        final hasDrawingLink =
            (p.drawingLink != null && p.drawingLink!.isNotEmpty);
        final hasSolidLinks = p.solidLinks.isNotEmpty;
        final hasAttachment =
            drawingUrl != null ||
            solidUrls.isNotEmpty ||
            hasDrawingLink ||
            hasSolidLinks;

        if (hasAttachment) {
          await pRef.update({
            if (drawingUrl != null) 'drawingUrl': drawingUrl,
            if (drawingUrl != null) 'drawingName': drawingName,
            if (solidUrls.isNotEmpty) 'solidUrls': solidUrls,
            if (solidUrls.isNotEmpty) 'solidNames': solidNames,
            if (hasDrawingLink) 'drawingLink': p.drawingLink,
            if (hasSolidLinks) 'solidLinkList': p.solidLinks,
          });

          try {
            String projectName;
            if (_selectedProjectId == null) {
              projectName = _proyectoCtrl.text.trim();
            } else {
              final projSnap = await projRef.get();
              final data = projSnap.data() as Map<String, dynamic>?;
              projectName = (data?['proyecto'] ?? '').toString();
            }
            await _upsertAutoOp(
              projectRef: projRef,
              partRef: pRef,
              projectName: projectName,
              partNumber: p.pn,
              opName: 'DIBUJO',
              status: 'hecho',
            );
          } catch (e) {
            // Si falla el registro automático, no cancelamos el flujo
            debugPrint('Auto-op DIBUJO error: $e');
          }
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

  Future<void> _upsertAutoOp({
    required DocumentReference projectRef,
    required DocumentReference partRef,
    required String projectName,
    required String partNumber,
    required String opName,
    required String status,
  }) async {
    final db = FirebaseFirestore.instance;
    final q = await db
        .collection('production_daily')
        .where('parteRef', isEqualTo: partRef)
        .where('operacionNombre', isEqualTo: opName)
        .where('auto', isEqualTo: true)
        .limit(1)
        .get();
    if (q.docs.isEmpty) {
      await db.collection('production_daily').add({
        'auto': true,
        'proyectoRef': projectRef,
        'parteRef': partRef,
        'proyecto': projectName,
        'numeroParte': partNumber,
        'operacion': opName,
        'operacionNombre': opName,
        'opSecuencia': 0,
        'cantidad': 0,
        'status': status,
        'fecha': Timestamp.now(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } else {
      await q.docs.first.reference.update({
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
        if (status == 'hecho') 'fin': FieldValue.serverTimestamp(),
        if (status != 'hecho') 'fin': null,
      });
    }
  }

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
      body: FutureBuilder<List<_MaterialDoc>>(
        future: _materialsFuture,
        builder: (context, matSnap) {
          if (matSnap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (matSnap.hasError) {
            return Center(
              child: Text('Error cargando materiales: ${matSnap.error}'),
            );
          }
          final mats = matSnap.data ?? const <_MaterialDoc>[];
          return AbsorbPointer(
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
                        DropdownButtonFormField<String?>(
                          isExpanded: true,
                          value: _selectedProjectId,
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('Nuevo proyecto'),
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
                          decoration: const InputDecoration(
                            labelText: 'Proyecto',
                            border: OutlineInputBorder(),
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
                            TextButton.icon(
                              onPressed: () async {
                                final pasted = await showDialog<String>(
                                  context: context,
                                  builder: (_) => const _PasteDialog(),
                                );
                                if (pasted == null || pasted.trim().isEmpty) {
                                  return;
                                }

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
                                    if (p.qty != null) {
                                      row.cantidadCtrl.text = '${p.qty}';
                                    }
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
                                          final caret =
                                              row.numeroCtrl.selection;
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
                                          labelText: 'Cantidad',
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
                                          : () => setState(
                                              () => _rows.removeAt(idx),
                                            ),
                                      icon: const Icon(
                                        Icons.remove_circle_outline,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                // Dimensión + Material
                                Row(
                                  children: [
                                    Expanded(
                                      flex: 6,
                                      child: TextField(
                                        controller: row.nestCtrl,
                                        decoration: const InputDecoration(
                                          labelText:
                                              'Dimensión / Nesting (texto)',
                                          hintText: 'p.ej. "bloque 4x4x4"',
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      flex: 5,
                                      child: DropdownButtonFormField<String?>(
                                        value: row.materialDocId,
                                        isExpanded: true,
                                        items: [
                                          const DropdownMenuItem<String?>(
                                            value: null,
                                            child: Text(
                                              '— Material (opcional) —',
                                            ),
                                          ),
                                          ...mats.map(
                                            (m) => DropdownMenuItem<String?>(
                                              value: m.id,
                                              child: Text(
                                                '${m.code} · ${m.desc}',
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                        ],
                                        onChanged: (v) => setState(
                                          () => row.materialDocId = v,
                                        ),
                                        decoration: const InputDecoration(
                                          labelText: 'Material',
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
                                              withData: kIsWeb,
                                            );
                                        if (pick != null &&
                                            pick.files.isNotEmpty) {
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
                                              allowedExtensions: [
                                                'x_t',
                                                'step',
                                              ],
                                              withData: kIsWeb,
                                            );
                                        if (pick != null &&
                                            pick.files.isNotEmpty) {
                                          setState(() {
                                            row.solids.addAll(pick.files);
                                          });
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.view_in_ar_outlined,
                                      ),
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
                                const SizedBox(height: 8),
                                // Alternativa: links (SharePoint u otros)
                                TextField(
                                  controller: row.drawingLinkCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Plano (URL opcional)',
                                    hintText:
                                        'https://... (si no subes archivo)',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: row.solidsLinkCtrl,
                                  decoration: const InputDecoration(
                                    labelText:
                                        'Sólidos (URLs separadas por coma)',
                                    hintText: 'https://... , https://... , ...',
                                    border: OutlineInputBorder(),
                                  ),
                                  maxLines: 2,
                                ),
                                const Divider(height: 20),
                              ],
                            ),
                          );
                        }),

                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () =>
                                setState(() => _rows.add(_PartRow())),
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
          );
        },
      ),
    );
  }
}

class _PartRow {
  final TextEditingController numeroCtrl = TextEditingController();
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController cantidadCtrl = TextEditingController();

  final TextEditingController nestCtrl = TextEditingController();
  String? materialDocId;

  final TextEditingController drawingLinkCtrl = TextEditingController();
  final TextEditingController solidsLinkCtrl = TextEditingController();

  PlatformFile? drawing;
  final List<PlatformFile> solids = [];

  void dispose() {
    numeroCtrl.dispose();
    descCtrl.dispose();
    cantidadCtrl.dispose();
    nestCtrl.dispose();
    drawingLinkCtrl.dispose();
    solidsLinkCtrl.dispose();
  }
}

class _ParsedLine {
  final String pn;
  final String desc;
  final int? qty;
  _ParsedLine({required this.pn, required this.desc, this.qty});
}

class _PendingPart {
  final String pn;
  final String desc;
  final int qty;
  final PlatformFile? drawing;
  final List<PlatformFile> solids;
  final String nestDim;
  final String? materialDocId;
  final String? drawingLink;
  final List<String> solidLinks;
  _PendingPart({
    required this.pn,
    required this.desc,
    required this.qty,
    required this.drawing,
    required this.solids,
    required this.nestDim,
    required this.materialDocId,
    required this.drawingLink,
    required this.solidLinks,
  });
}

class _MaterialDoc {
  final String id;
  final String code;
  final String desc;
  final String colorHex;
  final DocumentReference ref;
  _MaterialDoc({
    required this.id,
    required this.code,
    required this.desc,
    required this.colorHex,
    required this.ref,
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
                'Una por línea. Formatos válidos:\n'
                'PN | Descripción | Cantidad\n'
                'PN, Descripción, Cantidad\n'
                'PN<tab>Descripción<tab>Cantidad\n'
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
