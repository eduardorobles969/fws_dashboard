import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Pantalla de perfil del usuario
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user?.uid);

    return Scaffold(
      appBar: AppBar(title: const Text('Perfil del Usuario')),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: docRef.get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(
              child: Text('No se encontraron datos del usuario.'),
            );
          }

          final data = snapshot.data!.data()!;
          final name = data['displayName'] ?? 'Sin nombre';
          final email = data['email'] ?? 'Sin email';
          final photoURL = data['photoURL'] ?? '';

          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 50,
                  backgroundImage: photoURL.isNotEmpty
                      ? NetworkImage(photoURL)
                      : null,
                  child: photoURL.isEmpty
                      ? const Icon(Icons.person, size: 50)
                      : null,
                ),
                const SizedBox(height: 16),
                Text(name, style: const TextStyle(fontSize: 20)),
                const SizedBox(height: 8),
                Text(email, style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  icon: const Icon(Icons.delete),
                  label: const Text('Eliminar cuenta'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () async {
                    await user?.delete();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Cuenta eliminada')),
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
