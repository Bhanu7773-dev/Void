import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tele_gallery/features/auth/providers/auth_provider.dart';
import 'package:tele_gallery/features/home/screens/home_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  
  bool _isLoading = false;
  String _currentState = 'wait_phone'; // Default to wait_phone since we show this screen when not authenticated

  @override
  void initState() {
    super.initState();
    _initTelegram();
  }

  Future<void> _initTelegram() async {
    setState(() => _isLoading = true);
    try {
      final authService = ref.read(telegramAuthServiceProvider);
      await authService.init();
      // After init, TDLib should be ready for phone - no need to change state
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _sendCode() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter phone number')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await ref.read(telegramAuthServiceProvider).sendCode(phone);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter verification code')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await ref.read(telegramAuthServiceProvider).signIn(code);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _checkPassword() async {
    final password = _passwordController.text;
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter password')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await ref.read(telegramAuthServiceProvider).checkPassword(password);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);

    // Listen to auth state changes
    ref.listen(authStateProvider, (previous, next) {
      next.whenData((state) {
        setState(() => _currentState = state);
        
        if (state == 'ready') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connected to Telegram!'),
              backgroundColor: Colors.green,
            ),
          );
          // Navigate to home screen
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const HomeScreen()),
          );
        }
      });
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Void Login'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status indicator
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _getStatusColor().withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _getStatusColor()),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isLoading)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(_getStatusIcon(), color: _getStatusColor(), size: 20),
                  const SizedBox(width: 8),
                  Text(
                    _getStatusText(),
                    style: TextStyle(color: _getStatusColor()),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 32),

            // Dynamic form based on state
            authState.when(
              data: (state) => _buildFormForState(state),
              error: (err, stack) => Text('Error: $err'),
              loading: () => const Center(child: CircularProgressIndicator()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormForState(String state) {
    switch (state) {
      case 'wait_phone':
        return _buildPhoneForm();
      case 'wait_code':
        return _buildCodeForm();
      case 'wait_password':
        return _buildPasswordForm();
      case 'ready':
        return _buildSuccessView();
      default:
        return _buildPhoneForm();
    }
  }

  Widget _buildPhoneForm() {
    return Column(
      children: [
        TextField(
          controller: _phoneController,
          decoration: const InputDecoration(
            labelText: 'Phone Number',
            hintText: '+1234567890',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone),
          ),
          keyboardType: TextInputType.phone,
          enabled: !_isLoading && _currentState == 'wait_phone',
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: (_isLoading || _currentState != 'wait_phone') 
                ? null 
                : _sendCode,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send Code'),
          ),
        ),
      ],
    );
  }

  Widget _buildCodeForm() {
    return Column(
      children: [
        Text(
          'Code sent to ${_phoneController.text}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeController,
          decoration: const InputDecoration(
            labelText: 'Verification Code',
            hintText: '12345',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
          keyboardType: TextInputType.number,
          enabled: !_isLoading,
          autofocus: true,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _verifyCode,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Verify Code'),
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordForm() {
    return Column(
      children: [
        const Text(
          'Two-factor authentication enabled.\nPlease enter your password.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _passwordController,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.password),
          ),
          obscureText: true,
          enabled: !_isLoading,
          autofocus: true,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _checkPassword,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Submit Password'),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessView() {
    return Column(
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 64),
        const SizedBox(height: 16),
        Text(
          'Connected to Telegram!',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text('Session saved. You won\'t need to login again.'),
      ],
    );
  }

  Color _getStatusColor() {
    switch (_currentState) {
      case 'ready':
        return Colors.green;
      case 'wait_code':
      case 'wait_password':
        return Colors.orange;
      case 'wait_phone':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon() {
    switch (_currentState) {
      case 'ready':
        return Icons.check_circle;
      case 'wait_code':
        return Icons.sms;
      case 'wait_password':
        return Icons.lock;
      case 'wait_phone':
        return Icons.phone_android;
      default:
        return Icons.hourglass_empty;
    }
  }

  String _getStatusText() {
    switch (_currentState) {
      case 'ready':
        return 'Connected';
      case 'wait_code':
        return 'Enter verification code';
      case 'wait_password':
        return 'Enter 2FA password';
      case 'wait_phone':
        return 'Enter phone number';
      default:
        return 'Initializing...';
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
