import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class OperatorEditEntryScreen extends StatefulWidget {
  final String docId;
  const OperatorEditEntryScreen({super.key, required this.docId});

  @override
  State<OperatorEditEntryScreen> createState() =>
      _OperatorEditEntryScreenState();
}

class _OperatorEditEntryScreenState extends State<OperatorEditEntryScreen> {
  bool _saving = false;
  bool _loaded = false;

  int _plan = 0;
  int _pass = 0;
  int _fail = 0;

  String? _failCauseId;
  String? _failCauseName;

  DocumentReference<Map<String, dynamic>> get _ref => FirebaseFirestore.instance
      .collection('production_daily')
      .doc(widget.docId);

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ---------- Catálogo de causas ----------
  Future<Map<String, String>?> _pickFailCause() async {
    try {
      final q = await FirebaseFirestore.instance
          .collection('rework_causes')
          .orderBy('name')
          .get();
      final items = q.docs
          .map((d) => {'id': d.id, 'name': (d.data()['name'] ?? '').toString()})
          .where((m) => m['name']!.isNotEmpty)
          .toList();

      if (!mounted) return null;
      return await showModalBottomSheet<Map<String, String>>(
        context: context,
        showDragHandle: true,
        builder: (_) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final m = items[i];
                return ListTile(
                  leading: const Icon(Icons.rule_folder_outlined),
                  title: Text(m['name']!),
                  onTap: () => Navigator.pop(context, m),
                );
              },
            ),
          ),
        ),
      );
    } catch (e) {
      _toast('No se pudo cargar el catálogo de causas. ($e)');
      return null;
    }
  }

  // ---------- Cantidades ----------
  int get _sum => _pass + _fail;
  bool get _canAddMore => _sum < _plan;

  void _incPass(bool enabled) {
    if (!enabled) return;
    if (!_canAddMore) return _toast('No puede exceder la cantidad plan.');
    setState(() => _pass++);
  }

  void _decPass(bool enabled) {
    if (!enabled) return;
    if (_pass == 0) return;
    setState(() => _pass--);
  }

  Future<void> _incFail(bool enabled) async {
    if (!enabled) return;
    if (!_canAddMore) return _toast('No puede exceder la cantidad plan.');
    if (_failCauseId == null) {
      final picked = await _pickFailCause();
      if (picked == null) return;
      setState(() {
        _failCauseId = picked['id'];
        _failCauseName = picked['name'];
      });
    }
    setState(() => _fail++);
  }

  void _decFail(bool enabled) {
    if (!enabled) return;
    if (_fail == 0) return;
    setState(() => _fail--);
    if (_fail == 0) {
      setState(() {
        _failCauseId = null;
        _failCauseName = null;
      });
    }
  }

  // ---------- Inicio / Fin ----------
  Future<void> _markStart() async {
    setState(() => _saving = true);
    try {      try {
        await _ref.update({
          'inicio': FieldValue.serverTimestamp(),
          'status': 'en_proceso',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied') {
          await _ref.update({
            'inicio': FieldValue.serverTimestamp(),
            'status': 'en_proceso',
          });
        } else {
          throw e;
        }
      }
      
      _toast('Inicio registrado');
    } catch (e) {
      _toast('Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _markFinish() async {
    if (_sum != _plan) {
      _toast('La suma PASS + FAIL debe ser igual al plan.');
      return;
    }
    if (_fail > 0 && (_failCauseId == null || _failCauseName == null)) {
      _toast('Selecciona la CAUSA de FAIL.');
      return;
    }

    setState(() => _saving = true);
    try {      try {
        await _ref.update({
          'pass': _pass,
          'fail': _fail,
          'failCauseId': _fail > 0 ? _failCauseId : null,
          'failCauseName': _fail > 0 ? _failCauseName : null,
          'fin': FieldValue.serverTimestamp(),
          'status': 'hecho',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied') {
          await _ref.update({
            'pass': _pass,
            'fail': _fail,
            'failCauseId': _fail > 0 ? _failCauseId : null,
            'failCauseName': _fail > 0 ? _failCauseName : null,
            'fin': FieldValue.serverTimestamp(),
            'status': 'hecho',
          });
        } else {
          throw e;
        }
      }
      
      _toast('Orden finalizada');
    } catch (e) {
      _toast('Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------- Reportar SCRAP (independiente del FAIL) ----------
  Future<void> _reportScrapDialog() async {
    final piezasCtrl = TextEditingController();
    final motivoCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reportar scrap'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: piezasCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Piezas scrap',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: motivoCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Causa / Comentario',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reportar'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final piezas = int.tryParse(piezasCtrl.text.trim()) ?? 0;
    final motivo = motivoCtrl.text.trim();
    if (piezas <= 0) {
      _toast('Indica piezas > 0');
      return;
    }

    setState(() => _saving = true);
    try {
      final entrySnap = await _ref.get();
      final d = entrySnap.data() ?? {};

      // crea evento
      final evRef = await FirebaseFirestore.instance
          .collection('scrap_events')
          .add({
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
            'status': 'nuevo',
            'piezas': piezas,
            'motivo': motivo,
            'proyecto': (d['proyecto'] ?? '').toString(),
            'numeroParte': (d['numeroParte'] ?? '').toString(),
            'operacionNombre': (d['operacionNombre'] ?? d['operacion'] ?? '')
                .toString(),
            'maquinaNombre': (d['maquinaNombre'] ?? '').toString(),
            'entryRef': _ref,
          });

      // refleja en la orden: suma scrap y marca pendiente
      final scrapActual = (d['scrap'] is int)
          ? d['scrap'] as int
          : int.tryParse('${d['scrap'] ?? 0}') ?? 0;

      await _ref.update({
        'scrap': scrapActual + piezas, // <-- KPI de scrap
        'scrapPendiente': true,
        'scrapAprobado': false,
        'lastScrapEventId': evRef.id, // último evento creado (opcional)
        'updatedAt': FieldValue.serverTimestamp(),
      });

      _toast('Scrap reportado');
    } catch (e) {
      _toast('Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _ref.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(body: Center(child: Text('Error: ${snap.error}')));
        }
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final d = snap.data!.data() ?? {};
        final proyecto = (d['proyecto'] ?? '—').toString();
        final parte = (d['numeroParte'] ?? '—').toString();
        final status = (d['status'] ?? 'programado').toString();
        final op = (d['operacionNombre'] ?? d['operacion'] ?? '').toString();
        final maq = (d['maquinaNombre'] ?? '').toString();

        if (!_loaded) {
          _plan = (d['cantidad'] ?? 0) is int
              ? d['cantidad'] as int
              : int.tryParse('${d['cantidad'] ?? '0'}') ?? 0;
          _pass = (d['pass'] ?? 0) is int
              ? d['pass'] as int
              : int.tryParse('${d['pass'] ?? '0'}') ?? 0;
          _fail = (d['fail'] ?? 0) is int
              ? d['fail'] as int
              : int.tryParse('${d['fail'] ?? '0'}') ?? 0;

          final fcId = (d['failCauseId'] ?? '') as String?;
          final fcName = (d['failCauseName'] ?? '') as String?;
          _failCauseId = (fcId == null || fcId.isEmpty) ? null : fcId;
          _failCauseName = (fcName == null || fcName.isEmpty) ? null : fcName;

          _loaded = true;
        }

        final started = status != 'programado';
        final finished = status == 'hecho';

        final enableStart = !started && !finished && !_saving;
        final enableCounters = started && !finished && !_saving;
        final enableFinish =
            started &&
            !finished &&
            !_saving &&
            _sum == _plan &&
            (_fail == 0 || _failCauseId != null);

        return Scaffold(
          appBar: AppBar(title: Text('$proyecto • $parte')),
          body: AbsorbPointer(
            absorbing: _saving,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Text('Status: $status'),
                const SizedBox(height: 4),
                Text('Cantidad plan: $_plan'),
                if (op.isNotEmpty || maq.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (op.isNotEmpty) 'Op: $op',
                      if (maq.isNotEmpty) 'Maq: $maq',
                    ].join(' • '),
                    style: const TextStyle(color: Colors.black54),
                  ),
                ],
                const SizedBox(height: 12),

                // Inicio / Fin
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: enableStart ? _markStart : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Marcar inicio'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: enableFinish ? _markFinish : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Marcar fin'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: enableFinish
                              ? Colors.green
                              : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // PASS
                _qtyCard(
                  title: 'Pass',
                  value: _pass,
                  onMinus: () => _decPass(enableCounters),
                  onPlus: () => _incPass(enableCounters),
                  enabled: enableCounters,
                ),

                const SizedBox(height: 12),

                // FAIL
                _qtyCard(
                  title: 'Fail',
                  value: _fail,
                  onMinus: () => _decFail(enableCounters),
                  onPlus: () => _incFail(enableCounters),
                  enabled: enableCounters,
                  extra: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: enableCounters
                            ? () async {
                                final picked = await _pickFailCause();
                                if (picked != null) {
                                  setState(() {
                                    _failCauseId = picked['id'];
                                    _failCauseName = picked['name'];
                                  });
                                }
                              }
                            : null,
                        icon: const Icon(Icons.rule_folder_outlined),
                        label: Text(
                          _failCauseName == null
                              ? 'Elegir CAUSA de FAIL'
                              : 'Causa seleccionada: $_failCauseName',
                        ),
                      ),
                      if (enableCounters && _fail > 0 && _failCauseId == null)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            'Requerido: selecciona la causa de FAIL.',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // Guía / suma
                Row(
                  children: [
                    Text(
                      'Suma actual: $_sum / $_plan',
                      style: const TextStyle(color: Colors.black54),
                    ),
                    const Spacer(),
                    if (!enableFinish && started && !finished)
                      const Text(
                        'Completa PASS/FAIL (y causa) para cerrar',
                        style: TextStyle(color: Colors.black45, fontSize: 12),
                      ),
                  ],
                ),

                const SizedBox(height: 16),

                // --------- BOTÓN REPORTAR SCRAP (independiente) ----------
                if (started && !finished)
                  FilledButton.icon(
                    onPressed: _saving ? null : _reportScrapDialog,
                    icon: const Icon(Icons.report_gmailerrorred_outlined),
                    label: const Text('Reportar scrap'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- UI contador ----------
  Widget _qtyCard({
    required String title,
    required int value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
    required bool enabled,
    Widget? extra,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            const SizedBox(height: 6),
            Row(
              children: [
                IconButton(
                  onPressed: enabled ? onMinus : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Text(
                  '$value',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  onPressed: enabled ? onPlus : null,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            if (extra != null) extra,
          ],
        ),
      ),
    );
  }
}
