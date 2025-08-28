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
  final _passCtrl = TextEditingController();
  final _failCtrl = TextEditingController();
  bool _scrapPendiente = false;
  bool _saving = false;

  DocumentReference<Map<String, dynamic>> get _ref => FirebaseFirestore.instance
      .collection('production_daily')
      .doc(widget.docId);

  @override
  void dispose() {
    _passCtrl.dispose();
    _failCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final snap = await _ref.get();
    final d = snap.data()!;
    _passCtrl.text = (d['pass'] ?? 0).toString();
    _failCtrl.text = (d['fail'] ?? 0).toString();
    _scrapPendiente = (d['scrapPendiente'] ?? false) as bool;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _markStart() async {
    setState(() => _saving = true);
    try {
      await _ref.update({
        'inicio': FieldValue.serverTimestamp(),
        'status': 'en_proceso',
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Inicio registrado')));
      }
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

  Future<void> _markFinish() async {
    setState(() => _saving = true);
    try {
      await _ref.update({
        'fin': FieldValue.serverTimestamp(),
        'status': 'hecho',
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Fin registrado')));
      }
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

  Future<void> _saveCounts() async {
    final pass = int.tryParse(_passCtrl.text.trim()) ?? 0;
    final fail = int.tryParse(_failCtrl.text.trim()) ?? 0;
    setState(() => _saving = true);
    try {
      await _ref.update({
        'pass': pass,
        'fail': fail,
        'scrapPendiente': _scrapPendiente,
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Cantidades guardadas')));
      }
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

        final d = snap.data!.data()!;
        final proyecto = (d['proyecto'] ?? '—').toString();
        final parte = (d['numeroParte'] ?? '—').toString();
        final cantidad = (d['cantidad'] ?? 0) as int;
        final status = (d['status'] ?? 'programado').toString();
        final inicio = d['inicio'] as Timestamp?;
        final fin = d['fin'] as Timestamp?;

        return Scaffold(
          appBar: AppBar(title: Text('$proyecto • $parte')),
          body: AbsorbPointer(
            absorbing: _saving,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: [
                  Text('Status: $status'),
                  const SizedBox(height: 8),
                  Text('Cantidad plan: $cantidad'),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _saving ? null : _markStart,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Marcar inicio'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _saving ? null : _markFinish,
                          icon: const Icon(Icons.stop),
                          label: const Text('Marcar fin'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Pass'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _failCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Fail'),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: _scrapPendiente,
                    onChanged: (v) => setState(() => _scrapPendiente = v),
                    title: const Text('Scrap pendiente'),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _saving ? null : _saveCounts,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save),
                    label: Text(
                      _saving ? 'Guardando...' : 'Guardar cantidades',
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (inicio != null) Text('Inicio: ${inicio.toDate()}'),
                  if (fin != null) Text('Fin: ${fin.toDate()}'),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
