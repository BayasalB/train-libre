import 'dart:async';
import 'dart:convert';

import '../../../services/ai_service.dart';
import '../domain/models/smart_log_ai_models.dart';

/// Smart Log depends on this contract, not any provider-specific HTTP client.
abstract interface class SmartLogAiProvider {
  Future<bool> isConfigured();
  Future<String> interpret(SmartLogAiRequest request);
}

class SmartLogAiUnavailable implements Exception {
  final String message;
  const SmartLogAiUnavailable(this.message);
  @override
  String toString() => message;
}

/// Adapter over Train Libre's existing provider selection, Keychain-backed
/// BYOK storage, model choice, network timeouts and provider error classes.
class ConfiguredSmartLogAiProvider implements SmartLogAiProvider {
  final AiService ai;
  ConfiguredSmartLogAiProvider({AiService? ai}) : ai = ai ?? AiService.instance;

  @override
  Future<bool> isConfigured() async {
    final selected = await ai.getSelectedProvider();
    if (selected == AiProvider.ollama) return true;
    if (selected == AiProvider.custom) {
      final url = await ai.getCustomBaseUrl();
      final uri = url == null ? null : Uri.tryParse(url);
      return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    }
    final key = await ai.getApiKey(selected);
    return key != null && key.trim().isNotEmpty;
  }

  @override
  Future<String> interpret(SmartLogAiRequest request) async {
    if (!await isConfigured()) {
      throw const SmartLogAiUnavailable(
          'No usable AI provider is configured. Set one in AI Settings.');
    }
    final timeout = await ai.getAiTimeoutSeconds();
    try {
      return await ai
          .generateSmartLogStructuredText(
            systemPrompt: _systemPrompt,
            userContent: jsonEncode(request.toJson()),
          )
          .timeout(Duration(seconds: timeout));
    } on TimeoutException {
      throw const SmartLogAiUnavailable(
          'AI request timed out. Local logging remains available.');
    } on AiServiceException catch (error) {
      throw SmartLogAiUnavailable(error.message);
    }
  }

  static const _systemPrompt = '''
Interpret ONLY the unresolved food-log spans in the user JSON. The text may be Mongolian Cyrillic, romanized Mongolian, English, or mixed. Return one strict JSON object and no prose or markdown.
Schema: {"formatVersion":1,"items":[{"sourceCandidateId":"u0","sourceText":"exact input span","interpretedFoodName":"name","quantity":"decimal text or null","unit":"g|ml|serving|piece|unknown","actionState":"consumed|planned|cancelled|unknown","suggestedLocalFoodReference":"request-scoped candidate ID or null","nutritionEstimate":null,"confidence":0.0,"warnings":[]}]}
Include every field in every item. You may split one unresolved span into multiple items, retaining its exact sourceText and sourceCandidateId for each. Do not invent missing quantities or dates. Only return a quantity when its number is explicitly present in sourceText; otherwise return null. Do not silently turn planned or cancelled food into consumed. A suggestedLocalFoodReference must be one of the supplied candidateFoods IDs; never invent IDs. Such a suggestion is only a suggestion, never a final selection.
If allowEstimate is false, nutritionEstimate MUST be null. If true and a genuine estimate is possible, nutritionEstimate may be {"caloriesPer100":"decimal","proteinPer100":"decimal","carbsPer100":"decimal","fatPer100":"decimal"}; these are approximate per 100 g/ml, never exact label values. Never claim to have read a label. If a local candidate food exists, prefer its identity and leave nutritionEstimate null. If unsure, use null and explain uncertainty in warnings. No unrelated data is provided or requested.
''';
}
