import 'package:flutter/material.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();

    // 🎬 Controlador de animaciones
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );

    // 🎭 Animación de opacidad
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));

    // 🔍 Animación de escala
    _scaleAnimation = Tween<double>(
      begin: 0.8,
      end: 1.2,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.elasticOut));

    _controller.forward();

    // ⏳ Espera 3.5 segundos y navega según estado de autenticación
    Timer(const Duration(milliseconds: 3500), () {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        // ❌ No autenticado → Login
        Navigator.pushReplacementNamed(context, '/login');
      } else if (!user.emailVerified) {
        // ❌ Autenticado pero no verificado → Perfil para verificar
        Navigator.pushReplacementNamed(context, '/profile');
      } else {
        // ✅ Autenticado y verificado → Dashboard
        Navigator.pushReplacementNamed(context, '/dashboard');
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ✨ Efecto de destello tipo soldadura
  Widget _buildShineEffect() {
    return ShaderMask(
      shaderCallback: (Rect bounds) {
        return LinearGradient(
          colors: [
            Colors.white.withOpacity(0.0),
            Colors.white.withOpacity(0.6),
            Colors.white.withOpacity(0.0),
          ],
          stops: [0.0, 0.5, 1.0],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(bounds);
      },
      blendMode: BlendMode.srcATop,
      child: Image.asset(
        'assets/icon.png',
        width: 180,
        height: 180,
        fit: BoxFit.contain,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: _buildShineEffect(),
          ),
        ),
      ),
    );
  }
}
