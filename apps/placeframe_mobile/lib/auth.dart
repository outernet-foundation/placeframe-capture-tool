import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

// Keycloak password-grant login with refresh, the same flow as the Unity client (Auth.cs).
class Auth {
  Auth(this.config);

  final Config config;
  String? _accessToken;
  String? _refreshToken;
  DateTime _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _refreshExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  bool get loggedIn => _refreshToken != null && DateTime.now().isBefore(_refreshExpiry);

  Future<void> login(String username, String password) async {
    await _token({'grant_type': 'password', 'username': username, 'password': password});
    config.username = username;
  }

  void logout() {
    _accessToken = _refreshToken = null;
    _accessExpiry = _refreshExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  }

  // A valid access token, refreshing it when it is about to expire.
  Future<String> token() async {
    final skew = const Duration(seconds: 30);
    if (_accessToken != null && DateTime.now().add(skew).isBefore(_accessExpiry)) return _accessToken!;
    if (_refreshToken != null && DateTime.now().add(skew).isBefore(_refreshExpiry)) {
      await _token({'grant_type': 'refresh_token', 'refresh_token': _refreshToken!});
      return _accessToken!;
    }
    throw const AuthException('Session expired: log in again');
  }

  Future<void> _token(Map<String, String> form) async {
    final r = await http.post(Uri.parse(config.tokenUrl),
        body: {...form, 'client_id': config.clientId, 'scope': 'openid'});
    if (r.statusCode != 200) {
      throw AuthException(r.statusCode == 401 ? 'Wrong username or password' : 'Login failed (${r.statusCode})');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final now = DateTime.now();
    _accessToken = j['access_token'] as String;
    _refreshToken = j['refresh_token'] as String?;
    _accessExpiry = now.add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 300));
    _refreshExpiry = now.add(Duration(seconds: (j['refresh_expires_in'] as num?)?.toInt() ?? 1800));
  }
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
