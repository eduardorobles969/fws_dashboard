import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

enum UserRole { operador, supervisor, disenador, administrador }

extension UserRoleExtension on UserRole {
  String get name {
    switch (this) {
      case UserRole.operador:
        return 'operador';
      case UserRole.supervisor:
        return 'supervisor';
      case UserRole.disenador:
        return 'diseñador';
      case UserRole.administrador:
        return 'administrador';
    }
  }

  static UserRole fromString(String value) {
    final norm = value.trim().toLowerCase();
    for (final r in UserRole.values) {
      if (r.name == norm) return r;
    }
    return UserRole.operador; // por defecto
  }

  String get label {
    // Bonito para UI
    return '${name[0].toUpperCase()}${name.substring(1)}';
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _auth = FirebaseAuth.instance;
  final _picker = ImagePicker();

  final nameController = TextEditingController();

  User? get user => _auth.currentUser;
  DocumentReference<Map<String, dynamic>> get userRef =>
      FirebaseFirestore.instance.collection('users').doc(user!.uid);

  // Estado local
  File? _imageFile;
  String? _photoURL;
  String? _email;
  UserRole _role = UserRole.operador;
  bool _active = true;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    if (user == null) return;
    try {
      final doc = await userRef.get();

      if (!doc.exists) {
        // Si no existe, lo creamos base
        await userRef.set({
          'uid': user!.uid,
          'displayName': user!.displayName ?? '',
          'email': user!.email ?? '',
          'photoURL': '',
          'role': UserRole.operador.name,
          'active': true,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        nameController.text = user!.displayName ?? '';
        _email = user!.email ?? '';
        _photoURL = '';
        _role = UserRole.operador;
        _active = true;
      } else {
        final data = doc.data()!;
        nameController.text = (data['displayName'] ?? '') as String;
        _email = (data['email'] ?? user!.email ?? '') as String;
        _photoURL = (data['photoURL'] ?? '') as String;
        _role = UserRoleExtension.fromString(
          (data['role'] ?? 'operador') as String,
        );
        _active = (data['active'] ?? true) as bool;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error cargando perfil: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _picker.pickImage(source: source, imageQuality: 75);
    if (picked != null) {
      setState(() => _imageFile = File(picked.path));
    }
  }

  Future<String?> _uploadImage(File image) async {
    final ref = FirebaseStorage.instance.ref('profile_photos/${user!.uid}.jpg');
    await ref.putFile(image);
    return ref.getDownloadURL();
  }

  Future<void> _save() async {
    if (user == null) return;

    setState(() => _saving = true);
    try {
      String? url = _photoURL;
      if (_imageFile != null) {
        url = await _uploadImage(_imageFile!);
      }

      // Sólo permitir cambiar el role si YA es admin
      final canEditRole = _roleIsAdminInMemory;

      await userRef.update({
        'displayName': nameController.text.trim(),
        'photoURL': url ?? '',
        'role': canEditRole
            ? _role.name
            : FieldValue.delete(), // si no es admin no sobre-escribimos role
        'active': _active,
        'updatedAt': FieldValue.serverTimestamp(),
        // Siempre guardamos el email actual por conveniencia
        'email': _email ?? user!.email ?? '',
      });

      if (!canEditRole) {
        // Si no es admin, volvemos a leer para no perder el role verdadero guardado
        final fresh = await userRef.get();
        if (fresh.exists) {
          final data = fresh.data()!;
          _role = UserRoleExtension.fromString(
            (data['role'] ?? 'operador') as String,
          );
        }
      }

      setState(() {
        _photoURL = url;
        _imageFile = null;
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('✅ Cambios guardados')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error guardando: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _roleIsAdminInMemory => _role == UserRole.administrador;

  Future<void> _confirmDeleteAccount() async {
    if (user == null) return;

    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Eliminar cuenta'),
            content: const Text(
              '¿Seguro que deseas eliminar tu cuenta? Esta acción es irreversible.\n'
              'Puede requerir volver a iniciar sesión por seguridad.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Eliminar'),
              ),
            ],
          ),
        ) ??
        false;

    if (!ok) return;

    try {
      // Borramos sólo el Auth; el doc en Firestore suele desactivarse en vez de borrar.
      // Si te interesa borrar también el doc:
      // await userRef.delete();
      await user!.delete();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Cuenta eliminada')));
      }
    } on FirebaseAuthException catch (e) {
      // La API suele exigir re-autenticación reciente
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.code == 'requires-recent-login'
                ? 'Debes volver a iniciar sesión para eliminar tu cuenta.'
                : 'Error eliminando cuenta: ${e.message}',
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error eliminando: $e')));
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final ImageProvider? avatarProvider = _imageFile != null
        ? FileImage(_imageFile!)
        : (_photoURL != null && _photoURL!.isNotEmpty
              ? NetworkImage(_photoURL!)
              : null);

    final canEditRole =
        _roleIsAdminInMemory; // sólo admins pueden cambiar su role

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tu perfil'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () async => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundImage: avatarProvider,
                    child: avatarProvider == null
                        ? const Icon(Icons.person, size: 50)
                        : null,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: PopupMenuButton<ImageSource>(
                      tooltip: 'Cambiar foto',
                      onSelected: (src) => _pickImage(src),
                      itemBuilder: (ctx) => const [
                        PopupMenuItem(
                          value: ImageSource.gallery,
                          child: ListTile(
                            leading: Icon(Icons.photo),
                            title: Text('Galería'),
                          ),
                        ),
                        PopupMenuItem(
                          value: ImageSource.camera,
                          child: ListTile(
                            leading: Icon(Icons.camera_alt),
                            title: Text('Cámara'),
                          ),
                        ),
                      ],
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: const Icon(
                          Icons.edit,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Nombre
            TextField(
              controller: nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Nombre',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),

            // Email (sólo lectura)
            TextField(
              controller: TextEditingController(text: _email ?? ''),
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.alternate_email),
              ),
            ),
            const SizedBox(height: 12),

            // Role
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Rol',
                prefixIcon: Icon(Icons.verified_user_outlined),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<UserRole>(
                  value: _role,
                  isExpanded: true,
                  items: UserRole.values.map((r) {
                    return DropdownMenuItem<UserRole>(
                      value: r,
                      child: Text(r.label),
                    );
                  }).toList(),
                  onChanged: canEditRole
                      ? (newRole) {
                          if (newRole != null) setState(() => _role = newRole);
                        }
                      : null, // bloqueado si no es admin
                ),
              ),
            ),
            if (!canEditRole)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Solo un administrador puede cambiar el rol.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),

            const SizedBox(height: 12),

            // Activo
            SwitchListTile(
              title: const Text('Usuario activo'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),

            const SizedBox(height: 20),

            // Guardar
            ElevatedButton.icon(
              onPressed: _save,
              icon: _saving
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: const Text('Guardar cambios'),
            ),

            const SizedBox(height: 12),

            // Eliminar cuenta
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: const Text('Eliminar cuenta'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
              ),
              onPressed: _confirmDeleteAccount,
            ),
          ],
        ),
      ),
    );
  }
}
