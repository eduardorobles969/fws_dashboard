import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_ui_auth/firebase_ui_auth.dart' hide ProfileScreen;
import 'package:cloud_firestore/cloud_firestore.dart';

import 'dashboard_screen.dart';
import 'profile_screen.dart';

/// Pantalla de login usando Firebase UI Auth
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final providers = [EmailAuthProvider()];

    return SignInScreen(
      providers: providers,

      // 🔹 Logo de la app
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

      // 🔹 Acciones al cambiar el estado de autenticación
      actions: [
        // ✅ Usuario recién creado → Guardar en Firestore y redirigir a perfil
        AuthStateChangeAction<UserCreated>((context, state) async {
          final user = FirebaseAuth.instance.currentUser;
          if (user != null) {
            final doc = FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid);
            await doc.set({
              'email': user.email ?? '',
              'displayName': user.displayName ?? '',
              'photoURL': user.photoURL ?? '',
              'createdAt': FieldValue.serverTimestamp(),
            });
          }

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const ProfileScreen()),
          );
        }),

        // ✅ Usuario existente → Verificar Firestore y redirigir al dashboard
        AuthStateChangeAction<SignedIn>((context, state) async {
          final user = FirebaseAuth.instance.currentUser;
          if (user != null) {
            final docRef = FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid);
            final doc = await docRef.get();

            if (!doc.exists) {
              await docRef.set({
                'email': user.email ?? '',
                'displayName': user.displayName ?? '',
                'photoURL': user.photoURL ?? '',
                'createdAt': FieldValue.serverTimestamp(),
              });
            }
          }

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const DashboardScreen()),
          );
        }),
      ],
    );
  }
}
