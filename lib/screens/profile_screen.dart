import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:io';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final user = FirebaseAuth.instance.currentUser;
  final nameController = TextEditingController();
  File? _imageFile;
  String? photoURL;

  @override
  void initState() {
    super.initState();
    loadUserData();
  }

  Future<void> loadUserData() async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user!.uid)
        .get();
    if (doc.exists) {
      final data = doc.data()!;
      nameController.text = data['displayName'] ?? '';
      photoURL = data['photoURL'];
      setState(() {});
    }
  }

  Future<void> pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source, imageQuality: 70);

    if (pickedFile != null) {
      setState(() {
        _imageFile = File(pickedFile.path);
      });
    }
  }

  Future<String?> uploadImage(File image) async {
    final ref = FirebaseStorage.instance.ref().child(
      'profile_photos/${user!.uid}.jpg',
    );
    await ref.putFile(image);
    return await ref.getDownloadURL();
  }

  Future<void> saveChanges() async {
    String? uploadedURL = photoURL;

    if (_imageFile != null) {
      uploadedURL = await uploadImage(_imageFile!);
    }

    await FirebaseFirestore.instance.collection('users').doc(user!.uid).update({
      'displayName': nameController.text,
      'photoURL': uploadedURL ?? '',
    });

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('✅ Cambios guardados')));

    setState(() {
      photoURL = uploadedURL;
    });
  }

  @override
  Widget build(BuildContext context) {
    final avatar = _imageFile != null
        ? FileImage(_imageFile!)
        : (photoURL != null && photoURL!.isNotEmpty
              ? NetworkImage(photoURL!)
              : null);

    return Scaffold(
      appBar: AppBar(title: const Text('Tu perfil')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            CircleAvatar(
              radius: 50,
              backgroundImage: avatar as ImageProvider?,
              child: avatar == null ? const Icon(Icons.person, size: 50) : null,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.photo),
                  onPressed: () => pickImage(ImageSource.gallery),
                  tooltip: 'Elegir de galería',
                ),
                IconButton(
                  icon: const Icon(Icons.camera_alt),
                  onPressed: () => pickImage(ImageSource.camera),
                  tooltip: 'Tomar foto',
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: saveChanges,
              child: const Text('Guardar cambios'),
            ),
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
      ),
    );
  }
}
