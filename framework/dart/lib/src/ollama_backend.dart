/// A [TaggingBackend] on a local (or LAN) Ollama server.
///
/// The model the reader app classifies with, by decision: qwen2.5:7b at
/// temperature 0 with Ollama's schema-constrained output. Kept the default so
/// tags from the framework are comparable with tags the app already cached.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'tagging.dart';

const defaultOllamaModel = 'qwen2.5:7b';
const defaultOllamaUrl = 'http://localhost:11434';

/// Ollama silently truncates the prompt to the model's context window, and
/// its default is small (2048 tokens on many models). A chapter runs 8-10k
/// tokens, so the theme pass needs headroom. 16k of KV cache fits beside a
/// 7B Q4 model in 8GB of VRAM.
const ollamaNumCtx = 16384;

/// Long enough for a cold model load, short enough that a wedged endpoint
/// surfaces rather than stalling every later batch behind it.
const ollamaTimeout = Duration(seconds: 45);

class OllamaBackend implements TaggingBackend {
  OllamaBackend({
    http.Client? client,
    this.baseUrl = defaultOllamaUrl,
    this.model = defaultOllamaModel,
    this.timeout = ollamaTimeout,
  }) : _http = client ?? http.Client();

  final http.Client _http;
  final String baseUrl;
  final String model;
  final Duration timeout;

  @override
  String get name => 'ollama:$model';

  @override
  Future<Map<String, dynamic>> chat({
    required String system,
    required String user,
    required Map<String, Object> schema,
  }) async {
    final body = jsonEncode({
      'model': model,
      'stream': false,
      'format': schema,
      'options': {'temperature': 0, 'num_ctx': ollamaNumCtx},
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
    });

    http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse('$baseUrl/api/chat'),
            headers: const {'content-type': 'application/json'},
            body: body,
          )
          .timeout(timeout);
    } on SocketException catch (e) {
      throw TaggingUnavailable(
          "Ollama isn't running at $baseUrl (${e.message})");
    } on http.ClientException catch (e) {
      throw TaggingUnavailable(
          "Ollama isn't running at $baseUrl (${e.message})");
    } on TimeoutException {
      throw TaggingUnavailable(
          'Ollama did not answer within ${timeout.inSeconds}s');
    }
    if (response.statusCode != 200) {
      throw TaggingUnavailable(
          'Ollama returned ${response.statusCode}: ${response.body.trim()}');
    }

    final message = jsonDecode(response.body) as Map<String, dynamic>;
    final content = (message['message'] as Map<String, dynamic>)['content'];
    return jsonDecode(content as String) as Map<String, dynamic>;
  }

  void close() => _http.close();
}
