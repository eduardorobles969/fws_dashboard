import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Pantalla para agregar una entrada de producción
class AddProductionEntryScreen extends StatefulWidget {
  const AddProductionEntryScreen({super.key});

  @override
  State<AddProductionEntryScreen> createState() =>
      _AddProductionEntryScreenState();
}

class _AddProductionEntryScreenState extends State<AddProductionEntryScreen> {
  final _formKey = GlobalKey<FormState>();

  // Controladores para los campos
  final TextEditingController _lineController = TextEditingController();
  final TextEditingController _producedController = TextEditingController();
  final TextEditingController _scrapController = TextEditingController();

  /// Guarda los datos en Firestore
  Future<void> _submit() async {
    if (_formKey.currentState!.validate()) {
      final int produced = int.parse(_producedController.text);
      final int scrap = int.parse(_scrapController.text);
      final int good = produced - scrap;

      await FirebaseFirestore.instance.collection('production_daily').add({
        'date': Timestamp.now(),
        'line': _lineController.text,
        'produced': produced,
        'scrap': scrap,
        'good': good,
      });

      // Muestra mensaje y regresa al dashboard
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Producción agregada')));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agregar Producción')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              const Text(
                'Llena los datos de producción',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _lineController,
                decoration: const InputDecoration(labelText: 'Máquina / Línea'),
                validator: (value) => value!.isEmpty ? 'Campo requerido' : null,
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _producedController,
                decoration: const InputDecoration(
                  labelText: 'Cantidad producida',
                ),
                keyboardType: TextInputType.number,
                validator: (value) => value!.isEmpty ? 'Campo requerido' : null,
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _scrapController,
                decoration: const InputDecoration(
                  labelText: 'Cantidad con error',
                ),
                keyboardType: TextInputType.number,
                validator: (value) => value!.isEmpty ? 'Campo requerido' : null,
              ),
              const SizedBox(height: 24),

              ElevatedButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('Guardar'),
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
