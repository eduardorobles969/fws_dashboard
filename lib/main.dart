import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:fws_dashboard/screens/profile_screen.dart';
import 'firebase_options.dart';
// ignore: unused_import
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/welcome_screen.dart';
import 'screens/auth_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FWS Dashboard',
      theme: ThemeData(primarySwatch: Colors.blue),

      // 🔹 Arranca con WelcomeScreen (pantalla animada)
      home: const WelcomeScreen(),

      // 🔹 Define las rutas disponibles
      routes: {
        '/auth': (context) => const AuthGate(), // ⛩️ Lógica de autenticación
        '/login': (context) => const LoginScreen(),
        '/dashboard': (context) => const DashboardScreen(),
        '/profile': (context) => const ProfileScreen(),
      },
    );
  }
}
