// register_screen.dart
import 'package:asr_live_translator/constants.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  Future<void> _register() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final confirm = _confirmPasswordController.text.trim();

    if (name.isEmpty || email.isEmpty || password.isEmpty || confirm.isEmpty) {
      _showSnackBar('Please fill in all fields', Colors.orange);
      return;
    }
    if (password != confirm) {
      _showSnackBar('Passwords do not match', Colors.orange);
      return;
    }
    if (password.length < 6) {
      _showSnackBar('Password must be at least 6 characters', Colors.orange);
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Registration uses authBaseUrl (same as login)
      final response = await http.post(
        Uri.parse('$authBaseUrl/register'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'name': name,
          'email': email,
          'password': password,
        },
      );

      // --- DEBUG: print full response ---
      if (kDebugMode) {
        print('Registration status: ${response.statusCode}');
        print('Registration body: ${response.body}');
      }

      if (response.statusCode == 201 || response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // Check if token exists – if not, show a warning
        final token = data['token'] as String?;
        if (token == null) {
          // Server didn't return a token – user may not be fully created
          _showSnackBar(
            'Registration succeeded but no token returned. You may need to log in manually.',
            Colors.orange,
          );
          // Still navigate to login instead of working
          if (mounted) {
            Navigator.pushReplacementNamed(context, '/login');
          }
          return;
        }

        // Store token and auto‑login
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', token);

        if (mounted) {
          Navigator.pushReplacementNamed(context, '/working');
        }
      } else {
        // Try to parse error message from server
        String errorMsg = 'Registration failed (HTTP ${response.statusCode})';
        try {
          final errorBody = jsonDecode(response.body);
          errorMsg = errorBody['message'] ?? errorBody['error'] ?? errorMsg;
          // If there are field‑specific errors, show them
          if (errorBody['errors'] != null) {
            errorMsg = errorBody['errors'].toString();
          }
        } catch (_) {}
        _showSnackBar(errorMsg, Colors.red);
      }
    } catch (e) {
      _showSnackBar('Network error: $e', Colors.red);
      if (kDebugMode) {
        print('Registration exception: $e');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Account'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.person_add, size: 80, color: Colors.blue),
            const SizedBox(height: 16),
            const Text(
              'Join us today',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Full Name',
                prefixIcon: Icon(Icons.person),
                border: OutlineInputBorder(),
              ),
              enabled: !_isLoading,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: 'Email Address',
                prefixIcon: Icon(Icons.email),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
              enabled: !_isLoading,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
                border: const OutlineInputBorder(),
              ),
              obscureText: _obscurePassword,
              enabled: !_isLoading,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmPasswordController,
              decoration: InputDecoration(
                labelText: 'Confirm Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                ),
                border: const OutlineInputBorder(),
              ),
              obscureText: _obscureConfirm,
              enabled: !_isLoading,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _register,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Register', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Already have an account?'),
                TextButton(
                  onPressed: () {
                    Navigator.pushReplacementNamed(context, '/login');
                  },
                  child: const Text('Sign In'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }
}
