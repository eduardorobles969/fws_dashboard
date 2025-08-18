import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'login_screen.dart';
import 'dashboard_screen.dart';
import 'profile_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
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
        if (user == null) {
          return const LoginScreen();
        }

        // ❌ Autenticado pero no verificado → Mostrar aviso
        if (!user.emailVerified) {
          return _EmailVerificationScreen(user: user);
        }

        return const DashboardScreen();
      },
    );
  }
}

class _EmailVerificationScreen extends StatelessWidget {
  final User user;
  const _EmailVerificationScreen({required this.user});

  @override
  Widget build(BuildContext context) {
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

                if (refreshedUser != null && refreshedUser.emailVerified) {
                  // ✅ Si ya verificó → redirigir manualmente
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
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
}
