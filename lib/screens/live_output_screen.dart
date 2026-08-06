// live_output_screen.dart
import 'dart:convert';
import 'package:asr_live_translator/constants.dart';
import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class LiveOutputScreen extends StatefulWidget {
  final String videoKey;
  final String jobId;

  const LiveOutputScreen({
    super.key,
    required this.videoKey,
    required this.jobId,
  });

  @override
  State<LiveOutputScreen> createState() => _LiveOutputScreenState();
}

class _LiveOutputScreenState extends State<LiveOutputScreen> {
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic>? _outputData;

  @override
  void initState() {
    super.initState();
    _fetchStatus();
  }

  Future<void> _fetchStatus() async {
    setState(() => _isLoading = true);
    try {
      // Try to get a valid internal token (OAuth2)
      final internalToken = await InternalAuthService.getValidAccessToken();
      String baseUrl;
      String token;

      if (internalToken != null) {
        // Use internal server with OAuth token
        baseUrl = internalServerUrl;
        token = internalToken;
      } else {
        // Fall back to public server with main auth token
        final prefs = await SharedPreferences.getInstance();
        final publicToken = prefs.getString('auth_token') ?? '';
        if (publicToken.isEmpty) throw Exception('Not logged in.');
        baseUrl = authBaseUrl;
        token = publicToken;
      }

      final response = await http.get(
        Uri.parse('$baseUrl/job_status/${widget.jobId}'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _outputData = data;
          _isLoading = false;
        });
      } else {
        throw Exception('Failed to load job status (HTTP ${response.statusCode})');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Output'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchStatus,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Error: $_error', style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _fetchStatus,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    final data = _outputData!;
    final status = data['status'] ?? 'processing';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status
          Row(
            children: [
              Icon(
                status == 'completed'
                    ? Icons.check_circle
                    : status == 'processing'
                        ? Icons.hourglass_top
                        : Icons.error,
                color: status == 'completed'
                    ? Colors.green
                    : status == 'processing'
                        ? Colors.orange
                        : Colors.red,
              ),
              const SizedBox(width: 8),
              Text(
                'Status: $status',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Progress bar
          if (status != 'completed') ...[
            LinearProgressIndicator(
              value: data['progress'] ?? 0.0,
              backgroundColor: Colors.grey.shade300,
              valueColor: const AlwaysStoppedAnimation(Colors.blue),
            ),
            const SizedBox(height: 8),
            Text(
              '${((data['progress'] ?? 0.0) * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
          ],

          // Transcript
          if (data['transcript'] != null) ...[
            const Text(
              'Transcript',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                data['transcript'],
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Segments
          if (data['segments'] != null && data['segments'] is List) ...[
            const Text(
              'Segments',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...(data['segments'] as List).map((seg) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text(seg['text'] ?? ''),
                  subtitle: Text(
                    '${seg['start']?.toStringAsFixed(2) ?? '0'}s - ${seg['end']?.toStringAsFixed(2) ?? '0'}s'),
                  trailing: seg['language'] != null
                      ? Chip(label: Text(seg['language']))
                      : null,
                ),
              );
            }),
            const SizedBox(height: 16),
          ],

          // Complete message
          if (status == 'completed')
            const Center(
              child: Text(
                '✅ Processing complete!',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green),
              ),
            ),
        ],
      ),
    );
  }
}
