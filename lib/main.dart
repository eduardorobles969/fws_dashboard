import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:fws_dashboard/screens/profile_screen.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/welcome_screen.dart';

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

      // 🔹 Escucha el estado de autenticación en tiempo real
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          // ⏳ Mientras carga Firebase
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          final user = snapshot.data;

          // ❌ No autenticado → Login
          if (user == null) return const LoginScreen();

          // ❌ Autenticado pero no verificado → Mostrar aviso
          if (!user.emailVerified) {
            return Scaffold(
              appBar: AppBar(title: const Text('Verifica tu correo')),
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Por favor verifica tu correo electrónico.'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () async {
                        await user.sendEmailVerification();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Correo de verificación enviado'),
                          ),
                        );
                      },
                      child: const Text('Reenviar correo'),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () async {
                        await user.reload(); // 🔄 Recarga el estado del usuario
                        final refreshedUser = FirebaseAuth.instance.currentUser;

                        if (refreshedUser != null &&
                            refreshedUser.emailVerified) {
                          // ✅ Si ya verificó → redirigir manualmente
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ProfileScreen(),
                            ),
                          );
                        } else {
                          // ❌ Aún no verificado → mostrar mensaje
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Tu correo aún no está verificado'),
                            ),
                          );
                        }
                      },
                      child: const Text('Ya verifiqué, continuar'),
                    ),
                  ],
                ),
              ),
            );
          }

          // ✅ Autenticado y verificado → Dashboard
          return const DashboardScreen();
        },
      ),
    );
  }
}
