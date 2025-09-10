// lib/screens/dashboard_info_screen.dart
import 'package:flutter/material.dart';

class DashboardInfoScreen extends StatelessWidget {
  const DashboardInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "📊 Indicadores Clave (KPIs)",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          "✅ Producción",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Text(
                          "5 pzas",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          "⚠️ Scrap",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Text(
                          "2.3%",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            "📝 Notas del Turno",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("• Cierre de proyecto BS-0086-EV"),
                  Text("• Verificar niveles de aceite en M002 - Bodega 12"),
                  Text("• Reportar scrap generado de ensamble válvula"),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            "🔗 Links a Reportes",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.analytics),
                label: const Text("Dashboard Producción"),
              ),
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.assignment),
                label: const Text("Reporte Scrap"),
              ),
              ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.check_circle),
                label: const Text("Auditorías 5S"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
