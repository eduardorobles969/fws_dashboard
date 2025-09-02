// lib/screens/industry40_screen.dart
import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// ============ Industry 4.0 (MVP) ============
/// - Dropdown de máquinas (colección: machines)
/// - Panel en vivo (colección: i40_stream, doc = machineId)
/// - Historial (colección: i40_history, where machineId, orderBy ts desc)
/// - Simulador local (dev): genera datos cada 2s y escribe en ambas colecciones
///
/// Campos esperados en i40_stream/i40_history:
///   machineId (string), rpm (num), feed (num), temp (num), parts (int),
///   job (string), running (bool), alarms (array<string>),
///   updatedAt (ts, sólo en stream)  y  ts (ts, sólo en history).
class Industry40Screen extends StatefulWidget {
  const Industry40Screen({super.key});

  @override
  State<Industry40Screen> createState() => _Industry40ScreenState();
}

class _Industry40ScreenState extends State<Industry40Screen> {
  String? _machineId; // id seleccionado de 'machines'
  String? _machineLabel; // nombre bonito para AppBar/subtítulos

  // Simulador
  Timer? _sim;
  final _rnd = Random();
  int _jobCounter = 0;

  @override
  void dispose() {
    _sim?.cancel();
    super.dispose();
  }

  // ------- Carga máquinas (nombre + bodega opcional) -------
  Future<List<Map<String, String>>> _loadMachines() async {
    final qs = await FirebaseFirestore.instance.collection('machines').get();
    final out = <Map<String, String>>[];
    for (final d in qs.docs) {
      final data = d.data();
      final nombre = (data['nombre'] ?? '') as String;
      String bodega = (data['bodega'] ?? '') as String;

      // Si guardaste una referencia bodegaId (DocumentReference), intenta resolver nombre
      final bodegaRef = data['bodegaId'];
      if (bodegaRef is DocumentReference) {
        try {
          final b = await bodegaRef.get();
          if (b.exists) {
            bodega = ((b.data() as Map?)?['nombre'] ?? '') as String;
          }
        } catch (_) {}
      }

      out.add({
        'id': d.id,
        'label': bodega.isNotEmpty ? '$nombre • $bodega' : nombre,
      });
    }
    // orden alfabético
    out.sort((a, b) => (a['label']!).compareTo(b['label']!));
    return out;
  }

  // ------- Streams -------
  Stream<Map<String, dynamic>?> _liveStream(String machineId) {
    return FirebaseFirestore.instance
        .collection('i40_stream')
        .doc(machineId)
        .snapshots()
        .map((d) => d.data());
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _historyStream(String machineId) {
    return FirebaseFirestore.instance
        .collection('i40_history')
        .where('machineId', isEqualTo: machineId)
        .orderBy('ts', descending: true)
        .limit(30)
        .snapshots();
  }

  // ------- Simulador (dev) -------
  void _startSim() {
    final id = _machineId;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Elige una máquina para simular.')),
      );
      return;
    }
    _sim?.cancel();
    _sim = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _emitSample(id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Simulación iniciada en $_machineLabel')),
    );
    setState(() {}); // para refrescar icono
  }

  void _stopSim() {
    _sim?.cancel();
    _sim = null;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Simulación detenida')));
    setState(() {});
  }

  Future<void> _emitSample(String machineId) async {
    // Datos de ejemplo pseudo-realistas
    final now = DateTime.now();
    final running = _rnd.nextBool();
    final rpm = running ? (1400 + _rnd.nextInt(600)) : 0;
    final feed = running ? (180 + _rnd.nextDouble() * 140) : 0.0;
    final temp = 28 + _rnd.nextDouble() * (running ? 12 : 4);
    final parts = _rnd.nextInt(500);
    final alarms = _rnd.nextInt(10) == 0 ? ['Coolant low'] : <String>[];
    final job = 'JOB-${now.hour}${now.minute}-${_jobCounter++}';

    final streamData = {
      'machineId': machineId,
      'rpm': rpm,
      'feed': double.parse(feed.toStringAsFixed(1)),
      'temp': double.parse(temp.toStringAsFixed(1)),
      'parts': parts,
      'job': job,
      'running': running,
      'alarms': alarms,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final fs = FirebaseFirestore.instance;
    // snapshot en vivo
    await fs
        .collection('i40_stream')
        .doc(machineId)
        .set(streamData, SetOptions(merge: true));
    // histórico
    await fs.collection('i40_history').add({
      ...streamData,
      'ts': Timestamp.fromDate(now),
    });
  }

  @override
  Widget build(BuildContext context) {
    final simRunning = _sim != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Industry 4.0 • Telemetría'),
        bottom: _machineLabel == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _machineLabel!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                ),
              ),
        actions: [
          IconButton(
            tooltip: simRunning ? 'Detener simulación' : 'Iniciar simulación',
            icon: Icon(
              simRunning
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline,
            ),
            onPressed: simRunning ? _stopSim : _startSim,
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, String>>>(
        future: _loadMachines(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Text('Error cargando máquinas: ${snap.error}'),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final machines = snap.data!;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // ---------- Selector de máquina ----------
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Máquina',
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _machineId,
                      hint: const Text('Selecciona una máquina'),
                      items: machines.map((m) {
                        return DropdownMenuItem<String>(
                          value: m['id'],
                          child: Text(m['label']!),
                        );
                      }).toList(),
                      onChanged: (v) {
                        final item = machines.firstWhere((e) => e['id'] == v);
                        setState(() {
                          _machineId = v;
                          _machineLabel = item['label'];
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                if (_machineId == null)
                  Expanded(
                    child: Center(
                      child: Text(
                        'Selecciona una máquina para ver la telemetría.',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: _MachinePanel(
                      machineId: _machineId!,
                      liveStream: _liveStream(_machineId!),
                      historyStream: _historyStream(_machineId!),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Panel que muestra Live + History
class _MachinePanel extends StatelessWidget {
  final String machineId;
  final Stream<Map<String, dynamic>?> liveStream;
  final Stream<QuerySnapshot<Map<String, dynamic>>> historyStream;

  const _MachinePanel({
    required this.machineId,
    required this.liveStream,
    required this.historyStream,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // -------- LIVE CARD --------
        StreamBuilder<Map<String, dynamic>?>(
          stream: liveStream,
          builder: (context, snap) {
            final hasData = snap.hasData && snap.data != null;
            final d = snap.data ?? const {};

            final job = (d['job'] ?? '-').toString();
            final rpm = (d['rpm'] ?? 0).toString();
            final feed = (d['feed'] ?? 0).toString();
            final temp = (d['temp'] ?? 0).toString();
            final parts = (d['parts'] ?? 0).toString();
            final running = (d['running'] ?? false) as bool;
            final alarms = List<String>.from(d['alarms'] ?? const []);
            final updatedAt = d['updatedAt'];

            return Card(
              elevation: 3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _stateDot(running),
                        const SizedBox(width: 8),
                        Text(
                          running ? 'RUN' : 'IDLE',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: running
                                ? Colors.green.shade700
                                : Colors.blueGrey,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          hasData
                              ? Icons.cloud_done_outlined
                              : Icons.cloud_off_outlined,
                          color: hasData ? Colors.teal : Colors.grey,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _chip('Job', job),
                        _chip('RPM', rpm),
                        _chip('Feed', feed),
                        _chip('Temp °C', temp),
                        _chip('Parts', parts),
                      ],
                    ),
                    if (alarms.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Alarms: ${alarms.join(', ')}',
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'Actualizado: ${_fmtTs(updatedAt)}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),

        // -------- HISTORY LIST --------
        Expanded(
          child: Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: historyStream,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(child: Text('Error: ${snap.error}'));
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data!.docs;
                  if (docs.isEmpty) {
                    return const Center(child: Text('Sin historial.'));
                  }
                  return ListView.separated(
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final d = docs[i].data();
                      final ts = d['ts'];
                      final rpm = d['rpm'] ?? 0;
                      final feed = d['feed'] ?? 0;
                      final temp = d['temp'] ?? 0;
                      final parts = d['parts'] ?? 0;
                      final running = (d['running'] ?? false) as bool;

                      return ListTile(
                        dense: true,
                        title: Text(_fmtTs(ts)),
                        subtitle: Text(
                          'RPM $rpm • Feed $feed • Temp $temp • Parts $parts',
                        ),
                        trailing: Icon(
                          running ? Icons.play_arrow : Icons.pause,
                          color: running ? Colors.green : Colors.grey,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// ---------- Helpers UI ----------
Widget _chip(String label, String value) {
  return Chip(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    label: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: .2,
          ),
        ),
        Text(value),
      ],
    ),
  );
}

Widget _stateDot(bool on) {
  return Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      color: on ? Colors.green : Colors.grey,
      shape: BoxShape.circle,
    ),
  );
}

String _fmtTs(dynamic ts) {
  if (ts is Timestamp) {
    final d = ts.toDate();
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
  return '-';
}
