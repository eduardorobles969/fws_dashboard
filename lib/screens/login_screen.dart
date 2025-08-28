import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_ui_auth/firebase_ui_auth.dart' hide ProfileScreen;
import 'package:cloud_firestore/cloud_firestore.dart';

import 'dashboard_screen.dart';

/// Pantalla de login usando Firebase UI Auth
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  Future<void> _ensureUserDoc(User user) async {
    final ref = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final snap = await ref.get();

    final base = {
      'uid': user.uid,
      'email': user.email ?? '',
      'displayName': user.displayName ?? '',
      'photoURL': user.photoURL ?? '',
      'active': true,
      'role': 'operador', // rol por defecto
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (!snap.exists) {
      await ref.set({...base, 'createdAt': FieldValue.serverTimestamp()});
    } else {
      // Pequeño update para refrescar datos si cambian desde Auth
      await ref.update(base);
    }
  }

  void _goToDashboard(BuildContext context) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const DashboardScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final providers = [EmailAuthProvider()];

    return SignInScreen(
      providers: providers,

      // Logo
      headerBuilder: (context, constraints, _) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Image.network(
            'https://fusionweldingsolution.wordpress.com/wp-content/uploads/2024/06/fusionlogo__hard.png',
            height: 120,
            errorBuilder: (_, __, ___) => const Icon(Icons.error, size: 120),
          ),
        );
      },

      actions: [
        // Usuario recién creado
        AuthStateChangeAction<UserCreated>((context, state) async {
          final user = FirebaseAuth.instance.currentUser;
          if (user != null) {
            await _ensureUserDoc(user);
          }
          _goToDashboard(context); // 👉 directo al dashboard
        }),

        // Usuario inició sesión (existente)
        AuthStateChangeAction<SignedIn>((context, state) async {
          final user = FirebaseAuth.instance.currentUser;
          if (user != null) {
            await _ensureUserDoc(user);
          }
          _goToDashboard(context); // 👉 directo al dashboard
        }),
      ],
    );
  }
}
