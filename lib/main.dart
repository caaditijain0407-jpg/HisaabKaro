import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:convert';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:http/http.dart' as http;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL', defaultValue: ''),
    anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: ''),
  );
  SpeechHelper.init(); // fire-and-forget, don't block app startup
  runApp(const HisaabKaroApp());
}

final supabase = Supabase.instance.client;

// ==================== HELPERS ====================
String getBusinessName() {
  final meta = supabase.auth.currentUser?.userMetadata;
  if (meta != null && meta['business_name'] != null) return meta['business_name'];
  return 'My Business';
}

String getBusinessAddress() {
  final meta = supabase.auth.currentUser?.userMetadata;
  if (meta != null && meta['business_address'] != null && meta['business_address'].toString().isNotEmpty) return meta['business_address'];
  return '';
}

String getGSTIN() {
  final meta = supabase.auth.currentUser?.userMetadata;
  if (meta != null && meta['gstin'] != null && meta['gstin'].toString().isNotEmpty) return meta['gstin'];
  return '';
}

bool isGstApplicable() {
  final meta = supabase.auth.currentUser?.userMetadata;
  if (meta != null && meta['gst_applicable'] != null) return meta['gst_applicable'] == true;
  return true; // Default: GST is ON
}

String getPhoneNumber() {
  final email = supabase.auth.currentUser?.email ?? '';
  if (email.contains('@hisaabkaro.app')) return '+91 ${email.split('@')[0]}';
  return email;
}

// ==================== CONSTANTS ====================
const kOrange = Color(0xFFFF6B00);
const kOrangeLight = Color(0xFFFFF3E0);
const kOrangeBorder = Color(0xFFFFE0B2);
const List<String> kUnits = ['piece', 'kg', 'gram', 'litre', 'ml', 'bag', 'box', 'dozen', 'metre', 'foot', 'packet', 'bundle'];

// Smart number display: 5.0 -> "5", 2.5 -> "2.5"
String fmtQty(dynamic v) {
  final d = double.tryParse(v.toString()) ?? 0;
  return d == d.toInt() ? d.toInt().toString() : d.toStringAsFixed(2);
}

String fmtPrice(dynamic v) => (double.tryParse(v.toString()) ?? 0).toStringAsFixed(0);

// ==================== SPEECH RECOGNITION HELPER ====================
class SpeechHelper {
  static final stt.SpeechToText _speech = stt.SpeechToText();
  static bool _isAvailable = false;

  static bool get isAvailable => _isAvailable;
  static bool get isListening => _speech.isListening;

  static Future<void> init() async {
    try {
      _isAvailable = await _speech.initialize(
        onError: (_) {},
        onStatus: (_) {},
      );
    } catch (e) {
      _isAvailable = false;
    }
  }

  static Future<void> startListening({
    required Function(String text, bool isFinal) onResult,
    required Function() onEnd,
    required Function(String error) onError,
  }) async {
    if (!_isAvailable) {
      onError('Speech recognition not available');
      return;
    }
    try {
      await _speech.listen(
        onResult: (result) {
          onResult(result.recognizedWords, result.finalResult);
        },
        localeId: 'hi_IN', // Hindi — also understands Hinglish
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
        onSoundLevelChange: (_) {},
      );
    } catch (e) {
      onError(e.toString());
    }
  }

  static Future<void> stopListening() async {
    try { await _speech.stop(); } catch (_) {}
  }
}

// ==================== GEMINI AI HELPER ====================
const String _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
const String _geminiModel = 'gemini-2.5-flash';

class GeminiHelper {
  static bool get isConfigured => _geminiApiKey.isNotEmpty;

  /// Build system prompt with live business context
  static Future<String> _buildSystemPrompt() async {
    // Fetch live business data for context
    String customerList = '';
    String productList = '';
    String todaySummary = '';
    try {
      final customers = await supabase.from('customers').select('name, balance, phone').order('balance', ascending: false);
      if (customers.isNotEmpty) {
        customerList = customers.map((c) => '${c['name']}: \u20B9${c['balance']} balance${c['phone'] != null ? ', phone: ${c['phone']}' : ''}').join('\n');
      }
      final products = await supabase.from('products').select('name, price, stock, unit').order('name');
      if (products.isNotEmpty) {
        productList = products.map((p) => '${p['name']}: \u20B9${p['price']}/${p['unit'] ?? 'piece'}, stock: ${p['stock']} ${p['unit'] ?? 'pcs'}').join('\n');
      }
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final txns = await supabase.from('transactions').select()
        .gte('created_at', '${today}T00:00:00').lte('created_at', '${today}T23:59:59');
      double totalSales = 0, cash = 0, credit = 0, payments = 0;
      for (final t in txns) {
        final amt = double.tryParse(t['amount'].toString()) ?? 0;
        if (t['type'] == 'cash_sale') { totalSales += amt; cash += amt; }
        else if (t['type'] == 'credit') { totalSales += amt; credit += amt; }
        else if (t['type'] == 'debit') { payments += amt; }
      }
      todaySummary = 'Aaj ki bikri: \u20B9$totalSales (Cash: \u20B9$cash, Udhari: \u20B9$credit), Payments received: \u20B9$payments, Transactions: ${txns.length}';
    } catch (_) {}

    return '''You are HisaabKaro, a voice-first business assistant for Indian small shopkeepers.
IMPORTANT RULES:
- Always reply in Hinglish (Hindi words written in English + some Hindi script). This is how shopkeepers naturally talk.
- Keep responses SHORT (2-5 lines max). Shopkeepers are busy.
- Use \u20B9 symbol for amounts.
- Be friendly, use "Aap", "Ji" respectfully.

CURRENT BUSINESS DATA:
Customers:\n${customerList.isEmpty ? 'No customers yet' : customerList}

Products:\n${productList.isEmpty ? 'No products yet' : productList}

Today's Summary: ${todaySummary.isEmpty ? 'No transactions today' : todaySummary}

ACTIONS YOU CAN SUGGEST:
When user wants to record a payment, respond with this EXACT format on a NEW LINE:
##ACTION:PAYMENT|customer_name|amount##
Example: If user says "Shah ke 200 aa gaye", respond with a confirmation message AND on a new line: ##ACTION:PAYMENT|Shah|200##

When user asks for udhari/balance list, just show from the data above.
When user asks about stock, show from products data above.
When user asks about today's sales, show from today's summary above.
When user wants to make a bill, tell them to go to Customers tab or use Quick Cash Sale button.
For anything else, be helpful and suggest what you can do.''';
  }

  static Future<String> chat(String userMessage) async {
    if (!isConfigured) return 'Gemini API key set nahi hai. Settings mein API key daalo.';
    
    try {
      final systemPrompt = await _buildSystemPrompt();
      final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$_geminiModel:generateContent?key=$_geminiApiKey');
      
      final response = await http.post(url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'system_instruction': {'parts': [{'text': systemPrompt}]},
          'contents': [{'role': 'user', 'parts': [{'text': userMessage}]}],
          'generationConfig': {
            'temperature': 0.7,
            'maxOutputTokens': 300,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text = data['candidates']?[0]?['content']?['parts']?[0]?['text'];
        return text ?? 'Koi response nahi aaya. Dobara try karo.';
      } else {
        final error = jsonDecode(response.body);
        final msg = error['error']?['message'] ?? 'Unknown error';
        if (response.statusCode == 429) return 'API limit ho gaya. Thodi der baad try karo.';
        if (response.statusCode == 403) return 'API key invalid hai. Settings mein check karo.';
        return 'Error (${response.statusCode}): $msg';
      }
    } catch (e) {
      return 'Network error: $e';
    }
  }
}
class HisaabKaroApp extends StatelessWidget {
  const HisaabKaroApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HisaabKaro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: kOrange, brightness: Brightness.light),
        useMaterial3: true,
      ),
      home: supabase.auth.currentUser != null ? const MainShell() : const LoginScreen(),
    );
  }
}

// ==================== LOGIN SCREEN ====================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isLoading = false;
  bool _showNameField = false;
  String? _error;

  Future<void> _handleLogin() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final phone = _phoneController.text.trim().replaceAll(' ', '');
      if (phone.length != 10 || int.tryParse(phone) == null) {
        setState(() { _error = 'Please enter a valid 10-digit phone number'; _isLoading = false; });
        return;
      }
      final email = '$phone@hisaabkaro.app';
      final password = 'hk_${phone}_secure';
      try {
        await supabase.auth.signInWithPassword(email: email, password: password);
        if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainShell()));
      } on AuthException catch (e) {
        if (e.message.contains('Invalid login credentials')) {
          if (!_showNameField) {
            setState(() { _showNameField = true; _isLoading = false; });
            return;
          }
          if (_nameController.text.trim().isEmpty) {
            setState(() { _error = 'Apna business name daalo'; _isLoading = false; });
            return;
          }
          await supabase.auth.signUp(email: email, password: password, data: {'business_name': _nameController.text.trim()});
          if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainShell()));
        } else {
          rethrow;
        }
      }
    } catch (e) {
      setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() { _phoneController.dispose(); _nameController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 80),
              const Icon(Icons.store, size: 80, color: Color(0xFFFF6B00)),
              const SizedBox(height: 16),
              const Text('HisaabKaro', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Color(0xFFFF6B00))),
              const SizedBox(height: 8),
              Text('Aapka Voice-First Business Assistant', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey[600])),
              const SizedBox(height: 60),
              const Text('Apna phone number daalo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              TextField(
                controller: _phoneController, keyboardType: TextInputType.phone, maxLength: 10,
                style: const TextStyle(fontSize: 22, letterSpacing: 2),
                decoration: InputDecoration(
                  prefixIcon: const Padding(padding: EdgeInsets.only(left: 16, right: 8),
                    child: Text('+91', style: TextStyle(fontSize: 22, color: Colors.black54))),
                  prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                  hintText: '98765 43210', hintStyle: TextStyle(color: Colors.grey[300], fontSize: 22, letterSpacing: 2),
                  counterText: '',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFFF6B00), width: 2)),
                ),
                onSubmitted: (_) => _showNameField ? null : _handleLogin(),
              ),
              if (_showNameField) ...[
                const SizedBox(height: 16),
                const Text('Naye ho! Apna business name daalo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                TextField(
                  controller: _nameController, style: const TextStyle(fontSize: 18),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.store_outlined),
                    hintText: 'e.g. Sharma General Store', hintStyle: TextStyle(color: Colors.grey[300]),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFFF6B00), width: 2)),
                  ),
                  onSubmitted: (_) => _handleLogin(),
                ),
              ],
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 14))),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _isLoading ? null : _handleLogin,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(_showNameField ? 'Account Banao \u2192' : 'Shuru Karein \u2192', style: const TextStyle(fontSize: 18)),
              ),
              const SizedBox(height: 24),
              Text('Aapka data safe hai \u{1F512}\nHum aapka number sirf login ke liye use karte hain.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey[500])),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== MAIN SHELL ====================
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final List<Widget> _screens = [const HomeScreen(), const CustomersScreen(), const ProductsScreen(), const DashboardScreen(), const SettingsScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        backgroundColor: Colors.white, indicatorColor: const Color(0xFFFFE0B2),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_outlined), selectedIcon: Icon(Icons.chat, color: Color(0xFFFF6B00)), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people, color: Color(0xFFFF6B00)), label: 'Customers'),
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2, color: Color(0xFFFF6B00)), label: 'Products'),
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard, color: Color(0xFFFF6B00)), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings, color: Color(0xFFFF6B00)), label: 'Settings'),
        ],
      ),
    );
  }
}

// ==================== CHAT MESSAGE MODEL ====================
class ChatMessage {
  final String text;
  final bool isUser;
  ChatMessage({required this.text, required this.isUser});
}

// ==================== SCREEN 1: HOME (CHAT) ====================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<ChatMessage> _messages = [
    ChatMessage(text: 'Namaste! \u{1F64F} Main aapka business assistant hoon. Mic dabao ya type karo.', isUser: false),
  ];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _textController = TextEditingController();
  bool _isTyping = false;
  bool _isListening = false;

  void _addMessage(String text, bool isUser) {
    setState(() => _messages.add(ChatMessage(text: text, isUser: isUser)));
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _handleUserMessage(String text) async {
    _addMessage(text, true);
    _addMessage('...', false);
    try {
      String reply;

      if (GeminiHelper.isConfigured) {
        // ===== AI MODE: Use Gemini =====
        reply = await GeminiHelper.chat(text);
        
        // Parse ACTION commands from Gemini's response
        final actionMatch = RegExp(r'##ACTION:PAYMENT\|(.+?)\|(\d+\.?\d*)##').firstMatch(reply);
        if (actionMatch != null) {
          final payName = actionMatch.group(1)!.trim();
          final payAmount = double.tryParse(actionMatch.group(2)!) ?? 0;
          // Remove the action tag from visible reply
          reply = reply.replaceAll(RegExp(r'##ACTION:.*?##'), '').trim();
          
          if (payAmount > 0) {
            // Find customer and record payment
            final customers = await supabase.from('customers').select();
            Map<String, dynamic>? matched;
            for (final c in customers) {
              if (c['name'].toString().toLowerCase().contains(payName.toLowerCase())) { matched = c; break; }
            }
            if (matched != null) {
              await supabase.from('transactions').insert({
                'user_id': supabase.auth.currentUser?.id, 'customer_id': matched['id'],
                'type': 'debit', 'amount': payAmount, 'notes': 'Payment received (AI Voice)',
              });
              final newBal = (double.tryParse(matched['balance'].toString()) ?? 0) - payAmount;
              await supabase.from('customers').update({'balance': newBal}).eq('id', matched['id']);
              reply = '\u2705 ${matched['name']} se \u20B9${fmtPrice(payAmount)} payment record ho gaya!\nNaya balance: \u20B9${fmtPrice(newBal)}';
            } else {
              reply = '"$payName" naam ka customer nahi mila. Pehle Customers tab mein add karo.';
            }
          }
        }
      } else {
        // ===== KEYWORD MODE: Fallback when no API key =====
        reply = await _keywordChat(text);
      }

      setState(() => _messages.removeLast());
      _addMessage(reply, false);
    } catch (e) {
      setState(() => _messages.removeLast());
      _addMessage('Error ho gaya: ${e.toString()}', false);
    }
  }

  // Helper: check if text contains any of the keywords
  bool _matchesAny(String text, List<String> keywords) {
    return keywords.any((k) => text.contains(k));
  }

  /// Keyword-based fallback chat (used when Gemini API key not configured)
  Future<String> _keywordChat(String text) async {
    final lower = text.toLowerCase();
    final normalized = lower.replaceAll('\u20B9', '').replaceAll('  ', ' ').trim();

    // --- Payment pattern ---
    final paymentPattern = RegExp(r'(.+?)(?:\s+(?:ke|ne|se|ka|ki|से|के|ने|का|की|of|from))\s+(?:₹|rs\.?|rupees?|रुपये?)?\s*(\d+)\s*(?:aa?\s*ga?ye|diye|diya|mila|mile|jama|received|paid|आ\s*गए|दिए|दिया|मिला|मिले|जमा)', caseSensitive: false);
    final paymentPattern2 = RegExp(r'(?:₹|rs\.?|rupees?|रुपये?)?\s*(\d+)\s+(?:aa?\s*ga?ye|diye|diya|mila|mile|received|आ\s*गए|दिए|दिया|मिला|मिले)\s+(.+?)(?:\s+(?:ke|ne|se|ka|ki|से|के|ने|का|की|of|from))?\s*$', caseSensitive: false);
    final m1 = paymentPattern.firstMatch(normalized);
    final m2 = m1 == null ? paymentPattern2.firstMatch(normalized) : null;
    String? payName; double? payAmount;
    if (m1 != null) { payName = m1.group(1)?.trim(); payAmount = double.tryParse(m1.group(2) ?? ''); }
    else if (m2 != null) { payName = m2.group(2)?.trim(); payAmount = double.tryParse(m2.group(1) ?? ''); }

    if (payName != null && payAmount != null && payAmount > 0) {
      final customers = await supabase.from('customers').select();
      Map<String, dynamic>? matchedCustomer;
      for (final c in customers) {
        if (c['name'].toString().toLowerCase().contains(payName.toLowerCase())) { matchedCustomer = c; break; }
      }
      if (matchedCustomer != null) {
        await supabase.from('transactions').insert({
          'user_id': supabase.auth.currentUser?.id, 'customer_id': matchedCustomer['id'],
          'type': 'debit', 'amount': payAmount, 'notes': 'Payment received (Voice)',
        });
        final newBal = (double.tryParse(matchedCustomer['balance'].toString()) ?? 0) - payAmount;
        await supabase.from('customers').update({'balance': newBal}).eq('id', matchedCustomer['id']);
        return '\u2705 ${matchedCustomer['name']} se \u20B9${fmtPrice(payAmount)} payment record ho gaya!\nNaya balance: \u20B9${fmtPrice(newBal)}';
      } else {
        return '"$payName" naam ka customer nahi mila.\nCustomers tab mein pehle add karo.';
      }
    } else if (_matchesAny(normalized, ['baaki', 'udhar', 'pending', 'balance', 'बाकी', 'उधार', 'उधारी', 'बकाया', 'khata', 'hisaab', 'हिसाब', 'खाता', 'list'])) {
      final customers = await supabase.from('customers').select().order('balance', ascending: false);
      if (customers.isEmpty) return 'Abhi koi customer nahi hai. Customers tab mein add karo.';
      final buffer = StringBuffer('Udhari list:\n');
      double total = 0;
      for (final c in customers) {
        final bal = double.tryParse(c['balance'].toString()) ?? 0;
        if (bal > 0) { buffer.writeln('\u2022 ${c['name']}: \u20B9${fmtPrice(bal)}'); total += bal; }
      }
      return total == 0 ? 'Kisi ka bhi udhari baaki nahi hai! \u{1F389}' : '${buffer.toString()}\nTotal: \u20B9${fmtPrice(total)}';
    } else if (_matchesAny(normalized, ['aaj', 'today', 'summary', 'आज', 'total', 'टोटल', 'bikri', 'बिक्री', 'kamai', 'कमाई', 'din', 'दिन'])) {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final transactions = await supabase.from('transactions').select().gte('created_at', '${today}T00:00:00').lte('created_at', '${today}T23:59:59');
      double totalSales = 0, cashSales = 0, creditSales = 0, payments = 0;
      for (final t in transactions) {
        final amount = double.tryParse(t['amount'].toString()) ?? 0;
        if (t['type'] == 'cash_sale') { totalSales += amount; cashSales += amount; }
        else if (t['type'] == 'credit') { totalSales += amount; creditSales += amount; }
        else if (t['type'] == 'debit') { payments += amount; }
      }
      return 'Aaj ka hisaab:\n\u2022 Total bikri: \u20B9${fmtPrice(totalSales)}\n\u2022 Cash: \u20B9${fmtPrice(cashSales)}\n\u2022 Udhari: \u20B9${fmtPrice(creditSales)}\n\u2022 Payments received: \u20B9${fmtPrice(payments)}\n\u2022 Transactions: ${transactions.length}';
    } else if (_matchesAny(normalized, ['stock', 'stok', 'स्टॉक', 'saman', 'सामान', 'maal', 'माल', 'kitna bacha', 'कितना बचा', 'inventory', 'item'])) {
      final products = await supabase.from('products').select().order('stock', ascending: true);
      if (products.isEmpty) return 'Koi product nahi hai. Products tab mein add karo.';
      final buffer = StringBuffer('Stock status:\n');
      for (final p in products) {
        final stock = double.tryParse(p['stock'].toString()) ?? 0;
        final threshold = double.tryParse(p['low_stock_threshold'].toString()) ?? 5;
        buffer.writeln('\u2022 ${p['name']}: ${fmtQty(stock)} ${p['unit'] ?? 'pcs'}${stock <= threshold ? ' \u26A0\uFE0F LOW!' : ''}');
      }
      return buffer.toString();
    } else if (_matchesAny(normalized, ['bill', 'बिल', 'invoice', 'इनवॉइस', 'challan', 'चालान', 'receipt', 'रसीद', 'banao', 'बनाओ', 'banana', 'बनाना'])) {
      return 'Invoice banane ke 2 tarike:\n\n1\uFE0F\u20E3 Customer ka bill: Customers tab \u2192 customer tap karo \u2192 "New Invoice"\n\n2\uFE0F\u20E3 Cash sale: Upar "Quick Cash Sale" button dabao';
    } else if (_matchesAny(normalized, ['customer', 'ग्राहक', 'grahak', 'kitne customer', 'कितने', 'log', 'लोग', 'party', 'पार्टी'])) {
      final customers = await supabase.from('customers').select();
      double totalBal = 0;
      for (final c in customers) { totalBal += double.tryParse(c['balance'].toString()) ?? 0; }
      return 'Total ${customers.length} customers hain.\nTotal udhari: \u20B9${fmtPrice(totalBal)}';
    } else if (_matchesAny(normalized, ['product', 'प्रोडक्ट', 'saman kitna', 'kitne product', 'कितने प्रोडक्ट', 'cheez', 'चीज़'])) {
      final products = await supabase.from('products').select();
      int lowStock = products.where((p) => (double.tryParse(p['stock'].toString()) ?? 0) <= (double.tryParse(p['low_stock_threshold'].toString()) ?? 5)).length;
      return 'Total ${products.length} products hain.${lowStock > 0 ? '\n\u26A0\uFE0F $lowStock items low stock mein hain!' : ''}';
    } else if (_matchesAny(normalized, ['hello', 'hi', 'hey', 'namaste', 'नमस्ते', 'namaskar', 'नमस्कार', 'kaise', 'कैसे'])) {
      return 'Namaste! \u{1F64F} Kya madad kar sakta hoon?\n\nBolo ya type karo:\n\u2022 "Udhari list dikhao"\n\u2022 "Aaj ki bikri"\n\u2022 "Stock check"\n\u2022 "Bill banana hai"';
    } else if (_matchesAny(normalized, ['help', 'madad', 'मदद', 'kya kar', 'क्या कर', 'sahayata', 'सहायता'])) {
      return 'Main ye sab kar sakta hoon:\n\n\u{1F4B0} "Udhari list"\n\u{1F4CA} "Aaj ka total"\n\u{1F4E6} "Stock check"\n\u{1F4CB} "Bill banana hai"\n\u{1F4B8} "Shah ke 500 aa gaye"';
    } else {
      // Try customer name match
      final customers = await supabase.from('customers').select();
      for (final c in customers) {
        if (normalized.contains(c['name'].toString().toLowerCase())) {
          final bal = double.tryParse(c['balance'].toString()) ?? 0;
          return '${c['name']}:\n\u2022 Balance: \u20B9${fmtPrice(bal)}${bal > 0 ? ' (baaki hai)' : ' (clear hai \u2705)'}\n\u2022 Phone: ${c['phone'] ?? 'N/A'}\n\nPayment: "${c['name']} ke \u20B9500 aa gaye"';
        }
      }
      return 'Samajh nahi aaya \u{1F914}\n\nYe try karo:\n\u2022 "Udhari list"\n\u2022 "Aaj ki bikri"\n\u2022 "Stock check"\n\u2022 "Bill banana hai"\n\u2022 "Shah ke \u20B9500 aa gaye"';
    }
  }

  void _onMicPressed() async {
    if (_isListening) {
      await SpeechHelper.stopListening();
      setState(() => _isListening = false);
      return;
    }
    if (!SpeechHelper.isAvailable) {
      // Try re-initializing once
      await SpeechHelper.init();
      if (!SpeechHelper.isAvailable) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Voice not available. Mic permission dena hoga.'), backgroundColor: Colors.red));
        return;
      }
    }
    setState(() => _isListening = true);
    await SpeechHelper.startListening(
      onResult: (text, isFinal) {
        if (mounted) {
          setState(() {
            _textController.text = text;
            _textController.selection = TextSelection.fromPosition(TextPosition(offset: text.length));
            _isTyping = text.trim().isNotEmpty;
          });
          if (isFinal) setState(() => _isListening = false);
        }
      },
      onEnd: () { if (mounted) setState(() => _isListening = false); },
      onError: (error) {
        if (mounted) {
          setState(() => _isListening = false);
          if (error != 'error_no_match' && error != 'error_speech_timeout') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Mic error: $error'), backgroundColor: Colors.red));
          }
        }
      },
    );
  }
  void _onSendPressed() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    setState(() => _isTyping = false);
    _handleUserMessage(text);
  }

  Future<void> _quickCashSale() async {
    final products = await supabase.from('products').select().order('name');
    if (!mounted) return;
    List<Map<String, dynamic>> invoiceItems = [];
    await showDialog(context: context, builder: (context) => _InvoiceDialog(
      products: List<Map<String, dynamic>>.from(products), onDone: (items) => invoiceItems = items));
    if (invoiceItems.isEmpty) return;
    final gstEnabled = isGstApplicable();
    double subtotal = 0, totalGst = 0;
    for (final item in invoiceItems) {
      final lineTotal = (item['qty'] as double) * (item['price'] as double);
      subtotal += lineTotal;
      if (gstEnabled) { totalGst += lineTotal * ((item['gst_rate'] as double?) ?? 18) / 100; }
    }
    final total = subtotal + totalGst;
    final invoices = await supabase.from('invoices').select('id');
    final invoiceNumber = 'CASH-${(invoices.length + 1).toString().padLeft(4, '0')}';
    await supabase.from('invoices').insert({
      'user_id': supabase.auth.currentUser?.id, 'customer_id': null,
      'invoice_number': invoiceNumber, 'items': jsonEncode(invoiceItems),
      'subtotal': subtotal, 'gst_amount': totalGst, 'total': total, 'payment_type': 'cash',
    });
    await supabase.from('transactions').insert({
      'user_id': supabase.auth.currentUser?.id, 'customer_id': null,
      'type': 'cash_sale', 'amount': total, 'items': jsonEncode(invoiceItems), 'notes': 'Cash Sale $invoiceNumber',
    });
    for (final item in invoiceItems) {
      if (item['product_id'] != null) {
        try {
          final product = await supabase.from('products').select().eq('id', item['product_id']).single();
          final newStock = (double.tryParse(product['stock'].toString()) ?? 0) - (item['qty'] as double);
          await supabase.from('products').update({'stock': newStock}).eq('id', item['product_id']);
        } catch (_) {}
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$invoiceNumber — \u20B9${fmtPrice(total)} cash sale done!'), backgroundColor: kOrange));
      Navigator.push(context, MaterialPageRoute(builder: (_) => InvoicePdfScreen(
        invoiceNumber: invoiceNumber, customerName: 'Cash Customer', customerPhone: '',
        items: invoiceItems, subtotal: subtotal, gst: totalGst, total: total,
        businessName: getBusinessName(), businessPhone: getPhoneNumber(),
        businessAddress: getBusinessAddress(), gstin: getGSTIN(), gstEnabled: gstEnabled)));
    }
  }

  @override
  void dispose() { SpeechHelper.stopListening(); _textController.dispose(); _scrollController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HisaabKaro', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white),
      body: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), color: const Color(0xFFFFF3E0),
          child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
            GestureDetector(
              onTap: _quickCashSale,
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: kOrange, borderRadius: BorderRadius.circular(20)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.bolt, color: Colors.white, size: 16), SizedBox(width: 4),
                  Text('Quick Cash Sale', style: TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                ]))),
            const SizedBox(width: 8),
            _buildQuickChip('\u{1F4CB} Bill banao'), const SizedBox(width: 8),
            _buildQuickChip('\u{1F4B0} Aaj ka total'), const SizedBox(width: 8),
            _buildQuickChip('\u{1F4CA} Udhari list'), const SizedBox(width: 8),
            _buildQuickChip('\u{1F4E6} Stock check'),
          ])),
        ),
        Expanded(child: ListView.builder(controller: _scrollController, padding: const EdgeInsets.all(16),
          itemCount: _messages.length, itemBuilder: (context, index) => _buildChatBubble(_messages[index]))),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: BoxDecoration(color: Colors.white,
            boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, -2))]),
          child: SafeArea(child: Row(children: [
            Expanded(child: TextField(
              controller: _textController,
              onChanged: (text) => setState(() => _isTyping = text.trim().isNotEmpty),
              onSubmitted: (_) => _onSendPressed(),
              decoration: InputDecoration(
                hintText: _isListening ? '\u{1F3A4} Sun raha hoon... bolo!' : 'Type karo ya mic dabao...',
                hintStyle: TextStyle(color: _isListening ? Colors.red[300] : Colors.grey[400]),
                filled: true, fillColor: const Color(0xFFF5F5F5),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
            )),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _isTyping ? _onSendPressed : _onMicPressed,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _isListening ? 60 : 52, height: _isListening ? 60 : 52,
                decoration: BoxDecoration(
                  color: _isListening ? Colors.red : const Color(0xFFFF6B00),
                  shape: BoxShape.circle,
                  boxShadow: _isListening ? [BoxShadow(color: Colors.red.withOpacity(0.4), blurRadius: 16, spreadRadius: 4)] : null),
                child: Icon(
                  _isTyping ? Icons.send : (_isListening ? Icons.stop : Icons.mic),
                  color: Colors.white, size: 26)),
            ),
          ])),
        ),
      ]),
    );
  }

  Widget _buildQuickChip(String label) {
    return GestureDetector(
      onTap: () => _handleUserMessage(label.substring(2).trim()),
      child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFFF6B00))),
        child: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFFFF6B00)))),
    );
  }

  Widget _buildChatBubble(ChatMessage message) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: message.isUser ? const Color(0xFFFF6B00) : const Color(0xFFF3F3F3),
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: message.isUser ? const Radius.circular(4) : null,
            bottomLeft: !message.isUser ? const Radius.circular(4) : null)),
        child: Text(message.text, style: TextStyle(
          color: message.isUser ? Colors.white : Colors.black87, fontSize: 16)),
      ),
    );
  }
}

// ==================== SCREEN 2: CUSTOMERS ====================
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});
  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  List<Map<String, dynamic>> _customers = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String _sortBy = 'recent';
  bool _onlyPending = false;

  @override
  void initState() { super.initState(); _loadCustomers(); }

  Future<void> _loadCustomers() async {
    setState(() => _isLoading = true);
    try {
      final data = await supabase.from('customers').select().order('created_at', ascending: false);
      setState(() { _customers = List<Map<String, dynamic>>.from(data); _isLoading = false; });
    } catch (e) { setState(() => _isLoading = false); }
  }

  List<Map<String, dynamic>> get _filteredCustomers {
    var list = List<Map<String, dynamic>>.from(_customers);
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((c) => (c['name'] ?? '').toString().toLowerCase().contains(q) || (c['phone'] ?? '').toString().contains(q)).toList();
    }
    if (_onlyPending) list = list.where((c) => (double.tryParse(c['balance'].toString()) ?? 0) > 0).toList();
    if (_sortBy == 'name') list.sort((a, b) => (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
    else if (_sortBy == 'balance') list.sort((a, b) => (double.tryParse(b['balance'].toString()) ?? 0).compareTo(double.tryParse(a['balance'].toString()) ?? 0));
    return list;
  }

  Future<void> _addCustomer() async {
    final nameC = TextEditingController();
    final phoneC = TextEditingController();
    final balC = TextEditingController(text: '0');
    final result = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Add Customer'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Name *', hintText: 'e.g. Sharma ji')),
        const SizedBox(height: 12),
        TextField(controller: phoneC, decoration: const InputDecoration(labelText: 'Phone', hintText: '98765 43210'), keyboardType: TextInputType.phone),
        const SizedBox(height: 12),
        TextField(controller: balC, decoration: const InputDecoration(labelText: 'Opening Balance (\u20B9)'), keyboardType: TextInputType.number),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white),
          child: const Text('Add')),
      ],
    ));
    if (result == true && nameC.text.trim().isNotEmpty) {
      try {
        await supabase.from('customers').insert({
          'user_id': supabase.auth.currentUser?.id, 'name': nameC.text.trim(),
          'phone': phoneC.text.trim().isEmpty ? null : phoneC.text.trim(),
          'balance': double.tryParse(balC.text.trim()) ?? 0,
        });
        await _loadCustomers();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${nameC.text.trim()} added!'), backgroundColor: const Color(0xFFFF6B00)));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _openCustomerDetail(Map<String, dynamic> customer) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => CustomerDetailScreen(customer: customer, onUpdate: _loadCustomers)));
  }

  double get _totalBalance => _customers.fold(0, (sum, c) => sum + (double.tryParse(c['balance'].toString()) ?? 0));

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredCustomers;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customers', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.person_add), onPressed: _addCustomer)]),
      body: _isLoading ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B00)))
        : Column(children: [
          Container(
            margin: const EdgeInsets.all(16), padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFFFF6B00), Color(0xFFFF8F00)]),
              borderRadius: BorderRadius.circular(16)),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              Column(children: [
                const Text('Total Udhari', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                Text('\u20B9${_totalBalance.toStringAsFixed(0)}',
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              ]),
              Column(children: [
                const Text('Customers', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                Text('${_customers.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              ]),
            ])),
          // Search + Sort + Filter
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(child: TextField(
                onChanged: (v) => setState(() => _searchQuery = v),
                decoration: InputDecoration(hintText: 'Search name or phone...', hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                  prefixIcon: const Icon(Icons.search, size: 20), isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFFF6B00)))),
              )),
              const SizedBox(width: 8),
              PopupMenuButton<String>(icon: const Icon(Icons.sort, color: Color(0xFFFF6B00)),
                onSelected: (v) => setState(() => _sortBy = v),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'recent', child: Text('Recent', style: TextStyle(fontWeight: _sortBy == 'recent' ? FontWeight.bold : null))),
                  PopupMenuItem(value: 'name', child: Text('Name A-Z', style: TextStyle(fontWeight: _sortBy == 'name' ? FontWeight.bold : null))),
                  PopupMenuItem(value: 'balance', child: Text('Highest Balance', style: TextStyle(fontWeight: _sortBy == 'balance' ? FontWeight.bold : null))),
                ]),
              FilterChip(label: const Text('Pending', style: TextStyle(fontSize: 12)), selected: _onlyPending,
                selectedColor: const Color(0xFFFFE0B2), onSelected: (v) => setState(() => _onlyPending = v)),
            ])),
          const SizedBox(height: 8),
          Expanded(child: filtered.isEmpty
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.people_outline, size: 64, color: Colors.grey[300]),
                const SizedBox(height: 16),
                Text(_customers.isEmpty ? 'No customers yet' : 'No results', style: TextStyle(fontSize: 18, color: Colors.grey[500])),
                if (_customers.isEmpty) ...[const SizedBox(height: 8),
                  ElevatedButton.icon(onPressed: _addCustomer, icon: const Icon(Icons.person_add),
                    label: const Text('Add First Customer'),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white))],
              ]))
            : RefreshIndicator(onRefresh: _loadCustomers,
                child: ListView.builder(itemCount: filtered.length, itemBuilder: (context, index) {
                  final c = filtered[index];
                  final balance = double.tryParse(c['balance'].toString()) ?? 0;
                  return ListTile(
                    leading: CircleAvatar(backgroundColor: const Color(0xFFFFE0B2),
                      child: Text(c['name'][0].toUpperCase(),
                        style: const TextStyle(color: Color(0xFFFF6B00), fontWeight: FontWeight.bold))),
                    title: Text(c['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(c['phone'] ?? 'No phone'),
                    trailing: Text('\u20B9${balance.toStringAsFixed(0)}',
                      style: TextStyle(color: balance > 0 ? const Color(0xFFFF6B00) : Colors.green,
                        fontWeight: FontWeight.bold, fontSize: 16)),
                    onTap: () => _openCustomerDetail(c),
                  );
                }))),
        ]),
    );
  }
}

// ==================== CUSTOMER DETAIL + INVOICE ====================
class CustomerDetailScreen extends StatefulWidget {
  final Map<String, dynamic> customer;
  final VoidCallback onUpdate;
  const CustomerDetailScreen({super.key, required this.customer, required this.onUpdate});
  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  late Map<String, dynamic> _customer;
  List<Map<String, dynamic>> _transactions = [];

  @override
  void initState() { super.initState(); _customer = Map.from(widget.customer); _loadTransactions(); }

  Future<void> _loadTransactions() async {
    try {
      final data = await supabase.from('transactions').select()
        .eq('customer_id', _customer['id']).order('created_at', ascending: false);
      setState(() => _transactions = List<Map<String, dynamic>>.from(data));
    } catch (_) {}
  }

  Future<void> _editCustomer() async {
    final nameC = TextEditingController(text: _customer['name']);
    final phoneC = TextEditingController(text: _customer['phone'] ?? '');
    final result = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Edit Customer'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Name *')),
        const SizedBox(height: 12),
        TextField(controller: phoneC, decoration: const InputDecoration(labelText: 'Phone'), keyboardType: TextInputType.phone),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white),
          child: const Text('Save')),
      ],
    ));
    if (result == true && nameC.text.trim().isNotEmpty) {
      await supabase.from('customers').update({'name': nameC.text.trim(), 'phone': phoneC.text.trim().isEmpty ? null : phoneC.text.trim()}).eq('id', _customer['id']);
      setState(() { _customer['name'] = nameC.text.trim(); _customer['phone'] = phoneC.text.trim(); });
      widget.onUpdate();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Customer updated!'), backgroundColor: Color(0xFFFF6B00)));
    }
  }

  Future<void> _recordPayment() async {
    final amountC = TextEditingController();
    final noteC = TextEditingController();
    DateTime selectedDate = DateTime.now();
    String payMode = 'Cash';
    final result = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Record Payment'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: amountC, autofocus: true,
            decoration: const InputDecoration(labelText: 'Amount (\u20B9) *', hintText: 'e.g. 5000'),
            keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(context: context, initialDate: selectedDate,
                firstDate: DateTime(2020), lastDate: DateTime.now(),
                builder: (c, child) => Theme(data: Theme.of(c).copyWith(colorScheme: Theme.of(c).colorScheme.copyWith(primary: const Color(0xFFFF6B00))), child: child!));
              if (picked != null) setDialogState(() => selectedDate = picked);
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Date', prefixIcon: Icon(Icons.calendar_today, size: 18)),
              child: Text('${selectedDate.day}/${selectedDate.month}/${selectedDate.year}'),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: ['Cash', 'UPI', 'Bank', 'Cheque'].map((m) => ChoiceChip(
            label: Text(m, style: const TextStyle(fontSize: 13)),
            selected: payMode == m, selectedColor: const Color(0xFFFFE0B2),
            onSelected: (_) => setDialogState(() => payMode = m),
          )).toList()),
          const SizedBox(height: 12),
          TextField(controller: noteC, decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. partial payment')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
            child: const Text('Record')),
        ],
      ),
    ));
    if (result == true && amountC.text.trim().isNotEmpty) {
      final amount = double.tryParse(amountC.text.trim()) ?? 0;
      if (amount <= 0) return;
      final note = noteC.text.trim().isNotEmpty ? '$payMode: ${noteC.text.trim()}' : 'Payment received ($payMode)';
      await supabase.from('transactions').insert({
        'user_id': supabase.auth.currentUser?.id, 'customer_id': _customer['id'],
        'type': 'debit', 'amount': amount, 'notes': note,
        'created_at': selectedDate.toIso8601String(),
      });
      final newBalance = (double.tryParse(_customer['balance'].toString()) ?? 0) - amount;
      await supabase.from('customers').update({'balance': newBalance}).eq('id', _customer['id']);
      setState(() => _customer['balance'] = newBalance);
      await _loadTransactions();
      widget.onUpdate();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('\u20B9${amount.toStringAsFixed(0)} payment recorded!'), backgroundColor: Colors.green));
    }
  }

  Future<void> _createInvoice() async {
    final products = await supabase.from('products').select().order('name');
    if (!mounted) return;

    List<Map<String, dynamic>> invoiceItems = [];
    await showDialog(context: context, builder: (context) => _InvoiceDialog(
      products: List<Map<String, dynamic>>.from(products),
      onDone: (items) => invoiceItems = items));

    if (invoiceItems.isEmpty) return;

    final gstEnabled = isGstApplicable();
    double subtotal = 0, totalGst = 0;
    for (final item in invoiceItems) {
      final lineTotal = (item['qty'] as double) * (item['price'] as double);
      subtotal += lineTotal;
      if (gstEnabled) { totalGst += lineTotal * ((item['gst_rate'] as double?) ?? 18) / 100; }
    }
    final total = subtotal + totalGst;

    final invoices = await supabase.from('invoices').select('id');
    final invoiceNumber = 'INV-${(invoices.length + 1).toString().padLeft(4, '0')}';

    await supabase.from('invoices').insert({
      'user_id': supabase.auth.currentUser?.id, 'customer_id': _customer['id'],
      'invoice_number': invoiceNumber, 'items': jsonEncode(invoiceItems),
      'subtotal': subtotal, 'gst_amount': totalGst, 'total': total, 'payment_type': 'credit',
    });

    await supabase.from('transactions').insert({
      'user_id': supabase.auth.currentUser?.id, 'customer_id': _customer['id'],
      'type': 'credit', 'amount': total, 'items': jsonEncode(invoiceItems),
      'notes': 'Invoice $invoiceNumber',
    });

    final newBalance = (double.tryParse(_customer['balance'].toString()) ?? 0) + total;
    await supabase.from('customers').update({'balance': newBalance}).eq('id', _customer['id']);

    for (final item in invoiceItems) {
      if (item['product_id'] != null) {
        try {
          final product = await supabase.from('products').select().eq('id', item['product_id']).single();
          final newStock = (double.tryParse(product['stock'].toString()) ?? 0) - (item['qty'] as double);
          await supabase.from('products').update({'stock': newStock}).eq('id', item['product_id']);
        } catch (_) {}
      }
    }

    setState(() => _customer['balance'] = newBalance);
    await _loadTransactions();
    widget.onUpdate();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$invoiceNumber created! Total: \u20B9${total.toStringAsFixed(0)}'),
        backgroundColor: const Color(0xFFFF6B00)));
      Navigator.push(context, MaterialPageRoute(builder: (_) => InvoicePdfScreen(
        invoiceNumber: invoiceNumber, customerName: _customer['name'],
        customerPhone: _customer['phone'] ?? '', items: invoiceItems,
        subtotal: subtotal, gst: totalGst, total: total,
        businessName: getBusinessName(), businessPhone: getPhoneNumber(),
        businessAddress: getBusinessAddress(), gstin: getGSTIN(), gstEnabled: gstEnabled)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = double.tryParse(_customer['balance'].toString()) ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text(_customer['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.edit), onPressed: _editCustomer)]),
      body: Column(children: [
        Container(padding: const EdgeInsets.all(20), color: const Color(0xFFFFF3E0), width: double.infinity,
          child: Column(children: [
            const Text('Balance', style: TextStyle(fontSize: 14, color: Colors.grey)),
            Text('\u20B9${balance.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold,
                color: balance > 0 ? const Color(0xFFFF6B00) : Colors.green)),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ElevatedButton.icon(onPressed: _createInvoice, icon: const Icon(Icons.receipt),
                label: const Text('Create Invoice'),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white)),
              const SizedBox(width: 12),
              ElevatedButton.icon(onPressed: _recordPayment, icon: const Icon(Icons.payments),
                label: const Text('Record Payment'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white)),
            ]),
          ])),
        const Padding(padding: EdgeInsets.all(16),
          child: Align(alignment: Alignment.centerLeft,
            child: Text('Transaction History', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)))),
        Expanded(child: _transactions.isEmpty
          ? Center(child: Text('No transactions yet', style: TextStyle(color: Colors.grey[400])))
          : ListView.builder(itemCount: _transactions.length, itemBuilder: (context, index) {
              final t = _transactions[index];
              final amount = double.tryParse(t['amount'].toString()) ?? 0;
              final isCredit = t['type'] == 'credit';
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: isCredit ? const Color(0xFFFFE0B2) : const Color(0xFFE8F5E9),
                  child: Icon(isCredit ? Icons.arrow_upward : Icons.arrow_downward,
                    color: isCredit ? const Color(0xFFFF6B00) : Colors.green)),
                title: Text(t['notes'] ?? (isCredit ? 'Invoice' : 'Payment'),
                  style: const TextStyle(fontWeight: FontWeight.w500)),
                subtitle: Text(() {
                  final dt = DateTime.tryParse(t['created_at'] ?? '')?.toLocal();
                  return dt != null ? '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}' : '';
                }()),
                trailing: Text('${isCredit ? '+' : '-'}\u20B9${amount.toStringAsFixed(0)}',
                  style: TextStyle(color: isCredit ? const Color(0xFFFF6B00) : Colors.green,
                    fontWeight: FontWeight.bold, fontSize: 16)),
              );
            })),
      ]),
    );
  }
}

// ==================== INVOICE ITEM DIALOG ====================
class _InvoiceDialog extends StatefulWidget {
  final List<Map<String, dynamic>> products;
  final Function(List<Map<String, dynamic>>) onDone;
  const _InvoiceDialog({required this.products, required this.onDone});
  @override
  State<_InvoiceDialog> createState() => _InvoiceDialogState();
}

class _InvoiceDialogState extends State<_InvoiceDialog> {
  final List<Map<String, dynamic>> _items = [];
  final _nameC = TextEditingController();
  final _qtyC = TextEditingController(text: '1');
  final _priceC = TextEditingController();
  final _gstRateC = TextEditingController(text: '18');
  String _selectedUnit = 'piece';
  String? _selectedProductId;

  void _addItem() {
    if (_nameC.text.trim().isEmpty || _priceC.text.trim().isEmpty) return;
    final qty = double.tryParse(_qtyC.text) ?? 1;
    final price = double.tryParse(_priceC.text) ?? 0;
    final existingIndex = _items.indexWhere((i) => i['name'] == _nameC.text.trim() && i['price'] == price);
    if (existingIndex != -1) {
      setState(() { _items[existingIndex]['qty'] = (_items[existingIndex]['qty'] as double) + qty; });
    } else {
      setState(() { _items.add({
        'name': _nameC.text.trim(), 'qty': qty, 'price': price,
        'product_id': _selectedProductId, 'unit': _selectedUnit,
        'gst_rate': double.tryParse(_gstRateC.text) ?? 18,
      }); });
    }
    _nameC.clear(); _qtyC.text = '1'; _priceC.clear(); _gstRateC.text = '18';
    _selectedProductId = null; _selectedUnit = 'piece';
  }

  void _selectProduct(Map<String, dynamic> p) {
    setState(() {
      _nameC.text = p['name'];
      _priceC.text = (double.tryParse(p['price'].toString()) ?? 0).toStringAsFixed(0);
      _gstRateC.text = (double.tryParse(p['gst_rate']?.toString() ?? '18') ?? 18).toStringAsFixed(0);
      _qtyC.text = '1';
      _selectedProductId = p['id'];
      _selectedUnit = p['unit'] ?? 'piece';
    });
  }

  @override
  Widget build(BuildContext context) {
    final gstEnabled = isGstApplicable();
    double itemTotal = 0;
    double totalGst = 0;
    for (final i in _items) {
      final lineTotal = (i['qty'] as double) * (i['price'] as double);
      itemTotal += lineTotal;
      if (gstEnabled) {
        final rate = (i['gst_rate'] as double?) ?? 18;
        totalGst += lineTotal * rate / 100;
      }
    }
    final grandTotal = itemTotal + totalGst;
    return AlertDialog(
      title: const Text('Create Invoice'), insetPadding: const EdgeInsets.all(16),
      content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.products.isNotEmpty) ...[
            const Align(alignment: Alignment.centerLeft,
              child: Text('Tap product to fill, then adjust qty & add:', style: TextStyle(fontSize: 12, color: Colors.grey))),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: widget.products.map((p) => ActionChip(
              label: Text('${p['name']} \u20B9${(double.tryParse(p['price'].toString()) ?? 0).toStringAsFixed(0)}'),
              backgroundColor: _nameC.text == p['name'] ? const Color(0xFFFFE0B2) : null,
              onPressed: () => _selectProduct(p),
            )).toList()),
            const Divider(height: 24),
          ],
          // Selected product indicator
          if (_nameC.text.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: const Color(0xFFFFF3E0), borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(Icons.edit, size: 16, color: Color(0xFFFF6B00)),
                const SizedBox(width: 8),
                Expanded(child: Text('${_nameC.text} — set qty & tap Add', style: const TextStyle(fontSize: 13, color: Color(0xFFFF6B00), fontWeight: FontWeight.w500))),
              ]),
            ),
            const SizedBox(height: 8),
          ],
          TextField(controller: _nameC, decoration: const InputDecoration(labelText: 'Item Name', hintText: 'e.g. Cement'),
            onChanged: (_) => setState(() => _selectedProductId = null)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _qtyC, decoration: const InputDecoration(labelText: 'Qty'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true))),
            const SizedBox(width: 8),
            SizedBox(width: 85, child: DropdownButtonFormField<String>(
              value: _selectedUnit, isDense: true,
              decoration: const InputDecoration(labelText: 'Unit', contentPadding: EdgeInsets.symmetric(horizontal: 4)),
              items: kUnits.map((u) => DropdownMenuItem(value: u, child: Text(u, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) => setState(() => _selectedUnit = v ?? 'piece'),
            )),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: TextField(controller: _priceC, decoration: const InputDecoration(labelText: 'Price (\u20B9)'), keyboardType: TextInputType.number)),
            if (gstEnabled) ...[
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _gstRateC, decoration: const InputDecoration(labelText: 'GST %'), keyboardType: TextInputType.number)),
            ],
          ]),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(onPressed: _addItem, icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Item'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white))),
          if (_items.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Align(alignment: Alignment.centerLeft,
              child: Text('Invoice Items:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
            const SizedBox(height: 4),
          ],
          ..._items.asMap().entries.map((e) {
            final item = e.value;
            final qty = item['qty'] as double;
            final price = item['price'] as double;
            final unit = item['unit'] ?? 'piece';
            final lineAmt = qty * price;
            final gstRate = (item['gst_rate'] as double?) ?? 18;
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                // Item name and GST info
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item['name'], style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  Text('\u20B9${price.toStringAsFixed(0)} /$unit${gstEnabled ? ' • GST ${gstRate.toStringAsFixed(0)}%' : ''}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                ])),
                // Qty controls: - qty +
                IconButton(icon: const Icon(Icons.remove_circle_outline, size: 22, color: Color(0xFFFF6B00)),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () => setState(() {
                    if (qty > 1) { item['qty'] = qty - 1; }
                    else { _items.removeAt(e.key); }
                  })),
                Text('${fmtQty(qty)} $unit', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                IconButton(icon: const Icon(Icons.add_circle_outline, size: 22, color: Color(0xFFFF6B00)),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () => setState(() => item['qty'] = qty + 1)),
                // Amount
                const SizedBox(width: 4),
                SizedBox(width: 55, child: Text('\u20B9${lineAmt.toStringAsFixed(0)}',
                  textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
                // Delete
                IconButton(icon: const Icon(Icons.close, size: 16, color: Colors.red),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => setState(() => _items.removeAt(e.key))),
              ]),
            );
          }),
          if (_items.isNotEmpty) ...[
            const Divider(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Subtotal:', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('\u20B9${itemTotal.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            if (gstEnabled)
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('GST (item-wise):'), Text('\u20B9${totalGst.toStringAsFixed(0)}'),
              ]),
            if (!gstEnabled)
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('GST: Off', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                Text('\u20B90', style: TextStyle(color: Colors.grey[500])),
              ]),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Total:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              Text('\u20B9${grandTotal.toStringAsFixed(0)}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFFFF6B00))),
            ]),
          ],
        ]))),
      actions: [
        TextButton(onPressed: () { widget.onDone([]); Navigator.pop(context); }, child: const Text('Cancel')),
        ElevatedButton(onPressed: _items.isEmpty ? null : () { widget.onDone(_items); Navigator.pop(context); },
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white),
          child: const Text('Generate Invoice')),
      ],
    );
  }
}

// ==================== INVOICE PDF SCREEN ====================
class InvoicePdfScreen extends StatelessWidget {
  final String invoiceNumber, customerName, customerPhone, businessName, businessPhone, businessAddress, gstin;
  final List<Map<String, dynamic>> items;
  final double subtotal, gst, total;
  final bool gstEnabled;

  const InvoicePdfScreen({super.key, required this.invoiceNumber, required this.customerName,
    required this.customerPhone, required this.items, required this.subtotal,
    required this.gst, required this.total, required this.businessName, required this.businessPhone,
    this.businessAddress = '', this.gstin = '', this.gstEnabled = true});

  Future<pw.Document> _buildPdf() async {
    final pdf = pw.Document();
    final font = await PdfGoogleFonts.notoSansRegular();
    final fontBold = await PdfGoogleFonts.notoSansBold();

    pdf.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      theme: pw.ThemeData.withFont(base: font, bold: fontBold),
      build: (pw.Context context) {
        return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          // Header with business name on left and invoice info on right
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(businessName, style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#FF6B00'))),
              pw.SizedBox(height: 4),
              pw.Text(businessPhone, style: const pw.TextStyle(color: PdfColors.grey700)),
              if (businessAddress.isNotEmpty) pw.Text(businessAddress, style: const pw.TextStyle(color: PdfColors.grey700)),
              if (gstin.isNotEmpty) pw.Text('GSTIN: $gstin', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.grey800)),
            ]),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text('INVOICE', style: pw.TextStyle(fontSize: 28, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#FF6B00'))),
              pw.Text(invoiceNumber, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.Text('Date: ${DateTime.now().toString().substring(0, 10)}'),
            ]),
          ]),
          pw.SizedBox(height: 20),
          pw.Divider(color: PdfColor.fromHex('#FF6B00'), thickness: 2),
          pw.SizedBox(height: 16),

          // Bill To section
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(color: PdfColor.fromHex('#FFF3E0'), borderRadius: pw.BorderRadius.circular(4)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('Bill To:', style: const pw.TextStyle(color: PdfColors.grey600)),
              pw.Text(customerName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              if (customerPhone.isNotEmpty) pw.Text('Phone: $customerPhone'),
            ]),
          ),
          pw.SizedBox(height: 20),

          // Items table — include GST column if GST is enabled
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#FF6B00')),
            cellPadding: const pw.EdgeInsets.all(8),
            cellAlignments: gstEnabled
              ? {0: pw.Alignment.centerLeft, 1: pw.Alignment.center, 2: pw.Alignment.centerRight, 3: pw.Alignment.center, 4: pw.Alignment.centerRight}
              : {0: pw.Alignment.centerLeft, 1: pw.Alignment.center, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
            headers: gstEnabled ? ['Item', 'Qty', 'Price', 'GST%', 'Amount'] : ['Item', 'Qty', 'Price', 'Amount'],
            data: items.map((item) {
              final qty = double.tryParse(item['qty'].toString()) ?? 0;
              final price = double.tryParse(item['price'].toString()) ?? 0;
              final unit = item['unit'] ?? 'piece';
              final lineTotal = qty * price;
              final gstRate = (double.tryParse(item['gst_rate']?.toString() ?? '18') ?? 18);
              final lineWithGst = gstEnabled ? lineTotal + (lineTotal * gstRate / 100) : lineTotal;
              final qtyStr = '${fmtQty(qty)} $unit';
              return gstEnabled
                ? [item['name'].toString(), qtyStr,
                   '\u20B9${(item['price'] as double).toStringAsFixed(0)}',
                   '${gstRate.toStringAsFixed(0)}%',
                   '\u20B9${lineWithGst.toStringAsFixed(0)}']
                : [item['name'].toString(), qtyStr,
                   '\u20B9${(item['price'] as double).toStringAsFixed(0)}',
                   '\u20B9${lineTotal.toStringAsFixed(0)}'];
            }).toList(),
          ),
          pw.SizedBox(height: 16),

          // Totals section
          pw.Align(alignment: pw.Alignment.centerRight,
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
                pw.SizedBox(width: 120, child: pw.Text('Subtotal:')),
                pw.Text('\u20B9${subtotal.toStringAsFixed(0)}'),
              ]),
              pw.SizedBox(height: 4),
              if (gstEnabled) ...[
                pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
                  pw.SizedBox(width: 120, child: pw.Text('GST (item-wise):')),
                  pw.Text('\u20B9${gst.toStringAsFixed(0)}'),
                ]),
                pw.SizedBox(height: 4),
              ],
              pw.Divider(),
              pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
                pw.SizedBox(width: 120, child: pw.Text('TOTAL:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16))),
                pw.Text('\u20B9${total.toStringAsFixed(0)}',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16, color: PdfColor.fromHex('#FF6B00'))),
              ]),
            ])),
          pw.SizedBox(height: 40),
          pw.Divider(color: PdfColors.grey300),
          pw.SizedBox(height: 8),
          pw.Text('Thank you for your business!', style: const pw.TextStyle(color: PdfColors.grey600)),
          pw.Text('Generated by HisaabKaro', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey400)),
        ]);
      },
    ));
    return pdf;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(invoiceNumber, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white),
      body: PdfPreview(
        build: (format) async => (await _buildPdf()).save(),
        canChangeOrientation: false, canChangePageFormat: false, pdfFileName: '$invoiceNumber.pdf',
      ),
    );
  }
}

// ==================== SCREEN 3: PRODUCTS ====================
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});
  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  List<Map<String, dynamic>> _products = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() { super.initState(); _loadProducts(); }

  Future<void> _loadProducts() async {
    setState(() => _isLoading = true);
    try {
      final data = await supabase.from('products').select().order('name');
      setState(() { _products = List<Map<String, dynamic>>.from(data); _isLoading = false; });
    } catch (e) { setState(() => _isLoading = false); }
  }

  List<Map<String, dynamic>> get _filteredProducts {
    if (_searchQuery.isEmpty) return _products;
    final q = _searchQuery.toLowerCase();
    return _products.where((p) => (p['name'] ?? '').toString().toLowerCase().contains(q)).toList();
  }

  Future<void> _addProduct() async {
    final nameC = TextEditingController();
    final priceC = TextEditingController();
    final stockC = TextEditingController(text: '0');
    String selectedUnit = 'piece';
    final thresholdC = TextEditingController(text: '5');
    final gstRateC = TextEditingController(text: '18');
    final result = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
      title: const Text('Add Product'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Product Name *', hintText: 'e.g. Cement OPC')),
        const SizedBox(height: 12),
        TextField(controller: priceC, decoration: const InputDecoration(labelText: 'Price (\u20B9) *', hintText: 'e.g. 400'), keyboardType: TextInputType.number),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: stockC, decoration: const InputDecoration(labelText: 'Stock'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true))),
          const SizedBox(width: 12),
          Expanded(child: DropdownButtonFormField<String>(
            value: selectedUnit, decoration: const InputDecoration(labelText: 'Unit'),
            items: kUnits.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
            onChanged: (v) => setDialogState(() => selectedUnit = v ?? 'piece'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: thresholdC, decoration: const InputDecoration(labelText: 'Low Stock Alert'), keyboardType: TextInputType.number)),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: gstRateC, decoration: const InputDecoration(labelText: 'GST Rate (%)', suffixText: '%'), keyboardType: TextInputType.number)),
        ]),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white),
          child: const Text('Add')),
      ],
    )));
    if (result == true && nameC.text.trim().isNotEmpty && priceC.text.trim().isNotEmpty) {
      try {
        await supabase.from('products').insert({
          'user_id': supabase.auth.currentUser?.id, 'name': nameC.text.trim(),
          'price': double.tryParse(priceC.text.trim()) ?? 0,
          'stock': double.tryParse(stockC.text.trim()) ?? 0,
          'unit': selectedUnit, 'low_stock_threshold': int.tryParse(thresholdC.text.trim()) ?? 5,
          'gst_rate': double.tryParse(gstRateC.text.trim()) ?? 18,
        });
        await _loadProducts();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${nameC.text.trim()} added!'), backgroundColor: const Color(0xFFFF6B00)));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _editProduct(Map<String, dynamic> product) async {
    final stockC = TextEditingController(text: fmtQty(product['stock'] ?? 0));
    final priceC = TextEditingController(text: fmtPrice(product['price']));
    final gstRateC = TextEditingController(text: (double.tryParse(product['gst_rate']?.toString() ?? '18') ?? 18).toStringAsFixed(0));
    String selectedUnit = product['unit'] ?? 'piece';
    if (!kUnits.contains(selectedUnit)) selectedUnit = 'piece';
    final result = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
      title: Text(product['name']),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: priceC, decoration: const InputDecoration(labelText: 'Price (\u20B9)'), keyboardType: TextInputType.number),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: stockC, decoration: const InputDecoration(labelText: 'Stock'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true))),
          const SizedBox(width: 12),
          Expanded(child: DropdownButtonFormField<String>(
            value: selectedUnit, decoration: const InputDecoration(labelText: 'Unit'),
            items: kUnits.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
            onChanged: (v) => setDialogState(() => selectedUnit = v ?? 'piece'),
          )),
        ]),
        const SizedBox(height: 12),
        TextField(controller: gstRateC, decoration: const InputDecoration(labelText: 'GST Rate (%)', suffixText: '%'), keyboardType: TextInputType.number),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white),
          child: const Text('Update')),
      ],
    )));
    if (result == true) {
      await supabase.from('products').update({
        'price': double.tryParse(priceC.text) ?? 0, 'stock': double.tryParse(stockC.text) ?? 0,
        'unit': selectedUnit, 'gst_rate': double.tryParse(gstRateC.text) ?? 18,
      }).eq('id', product['id']);
      await _loadProducts();
    }
  }

  Future<void> _deleteProduct(Map<String, dynamic> product) async {
    final result = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Delete Product?'), content: Text('Delete ${product['name']}?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
          child: const Text('Delete')),
      ],
    ));
    if (result == true) { await supabase.from('products').delete().eq('id', product['id']); await _loadProducts(); }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredProducts;
    int lowStockCount = _products.where((p) => (double.tryParse(p['stock'].toString()) ?? 0) <= (double.tryParse(p['low_stock_threshold'].toString()) ?? 5)).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Products', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.add), onPressed: _addProduct)]),
      body: _isLoading ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B00)))
        : Column(children: [
          Container(
            margin: const EdgeInsets.all(16), padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFFFF6B00), Color(0xFFFF8F00)]),
              borderRadius: BorderRadius.circular(16)),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              Column(children: [
                const Text('Total Products', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                Text('${_products.length}', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              ]),
              Column(children: [
                const Text('Low Stock \u26A0\uFE0F', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                Text('$lowStockCount', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              ]),
            ])),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(hintText: 'Search products...', hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                prefixIcon: const Icon(Icons.search, size: 20), isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFFF6B00)))),
            )),
          const SizedBox(height: 8),
          Expanded(child: filtered.isEmpty
            ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.inventory_2_outlined, size: 64, color: Colors.grey[300]),
                const SizedBox(height: 16),
                Text(_products.isEmpty ? 'No products yet' : 'No results', style: TextStyle(fontSize: 18, color: Colors.grey[500])),
                if (_products.isEmpty) ...[const SizedBox(height: 8),
                  ElevatedButton.icon(onPressed: _addProduct, icon: const Icon(Icons.add),
                    label: const Text('Add First Product'),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white))],
              ]))
            : RefreshIndicator(onRefresh: _loadProducts,
                child: ListView.builder(itemCount: filtered.length, itemBuilder: (context, index) {
                  final p = filtered[index];
                  final stock = double.tryParse(p['stock'].toString()) ?? 0;
                  final threshold = double.tryParse(p['low_stock_threshold'].toString()) ?? 5;
                  final isLow = stock <= threshold;
                  return Dismissible(key: Key(p['id']), direction: DismissDirection.endToStart,
                    background: Container(color: Colors.red, alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
                    confirmDismiss: (_) async { await _deleteProduct(p); return false; },
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isLow ? const Color(0xFFFFCDD2) : const Color(0xFFE8F5E9),
                        child: Icon(Icons.inventory, color: isLow ? Colors.red : Colors.green)),
                      title: Text(p['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('\u20B9${(double.tryParse(p['price'].toString()) ?? 0).toStringAsFixed(0)} per ${p['unit'] ?? 'piece'} • GST ${(double.tryParse(p['gst_rate']?.toString() ?? '18') ?? 18).toStringAsFixed(0)}%'),
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text(fmtQty(stock), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isLow ? Colors.red : Colors.green)),
                        Text(p['unit'] ?? 'pcs', style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                      ]),
                      onTap: () => _editProduct(p),
                    ));
                }))),
        ]),
    );
  }
}

// ==================== SCREEN 4: DASHBOARD ====================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  double _totalUdhari = 0;
  int _customerCount = 0, _productCount = 0, _invoiceCount = 0;
  List<Map<String, dynamic>> _recentInvoices = [];
  bool _isLoading = true;

  @override
  void initState() { super.initState(); _loadDashboard(); }

  Future<void> _loadDashboard() async {
    try {
      final customers = await supabase.from('customers').select();
      final products = await supabase.from('products').select();
      final invoices = await supabase.from('invoices').select().order('created_at', ascending: false);
      double totalUdhari = 0;
      for (final c in customers) { totalUdhari += double.tryParse(c['balance'].toString()) ?? 0; }
      final customerMap = <String, String>{};
      for (final c in customers) { customerMap[c['id']] = c['name']; }
      final enrichedInvoices = invoices.map((inv) {
        final m = Map<String, dynamic>.from(inv);
        m['customer_name'] = customerMap[m['customer_id']] ?? 'Cash Customer';
        return m;
      }).toList();
      setState(() {
        _totalUdhari = totalUdhari; _customerCount = customers.length;
        _productCount = products.length; _invoiceCount = invoices.length;
        _recentInvoices = enrichedInvoices; _isLoading = false;
      });
    } catch (e) { setState(() => _isLoading = false); }
  }

  void _openInvoicePdf(Map<String, dynamic> invoice) {
    List<Map<String, dynamic>> items = [];
    try {
      final decoded = invoice['items'] is String ? jsonDecode(invoice['items']) : invoice['items'];
      items = List<Map<String, dynamic>>.from(decoded);
    } catch (_) {}
    Navigator.push(context, MaterialPageRoute(builder: (_) => InvoicePdfScreen(
      invoiceNumber: invoice['invoice_number'] ?? '', customerName: invoice['customer_name'] ?? 'Customer',
      customerPhone: '', items: items,
      subtotal: double.tryParse(invoice['subtotal'].toString()) ?? 0,
      gst: double.tryParse(invoice['gst_amount'].toString()) ?? 0,
      total: double.tryParse(invoice['total'].toString()) ?? 0,
      businessName: getBusinessName(), businessPhone: getPhoneNumber(),
      businessAddress: getBusinessAddress(), gstin: getGSTIN(),
      gstEnabled: (double.tryParse(invoice['gst_amount'].toString()) ?? 0) > 0,
    )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loadDashboard)]),
      body: _isLoading ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B00)))
        : SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Business Overview', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _buildStatCard('Total Udhari', '\u20B9${_totalUdhari.toStringAsFixed(0)}', Icons.account_balance_wallet, const Color(0xFFFF6B00))),
              const SizedBox(width: 12),
              Expanded(child: _buildStatCard('Customers', '$_customerCount', Icons.people, Colors.blue)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _buildStatCard('Products', '$_productCount', Icons.inventory, Colors.green)),
              const SizedBox(width: 12),
              Expanded(child: _buildStatCard('Invoices', '$_invoiceCount', Icons.receipt_long, Colors.purple)),
            ]),
            const SizedBox(height: 24),
            const Text('Top Udhari Customers', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            FutureBuilder(
              future: supabase.from('customers').select().order('balance', ascending: false).limit(5),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox();
                final customers = snapshot.data as List;
                if (customers.isEmpty) return Text('No customers yet', style: TextStyle(color: Colors.grey[500]));
                final maxBal = double.tryParse(customers[0]['balance'].toString()) ?? 1;
                return Column(children: customers.map<Widget>((c) {
                  final bal = double.tryParse(c['balance'].toString()) ?? 0;
                  return Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text(c['name'], style: const TextStyle(fontWeight: FontWeight.w500)),
                      Text('\u20B9${bal.toStringAsFixed(0)}', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                    ]),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: maxBal > 0 ? bal / maxBal : 0,
                      backgroundColor: const Color(0xFFF5F5F5), color: const Color(0xFFFF6B00),
                      borderRadius: BorderRadius.circular(4), minHeight: 8),
                  ]));
                }).toList());
              }),
            // Invoice History
            const SizedBox(height: 24),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Invoice History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text('${_recentInvoices.length} total', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
            ]),
            const SizedBox(height: 12),
            if (_recentInvoices.isEmpty) Text('No invoices yet', style: TextStyle(color: Colors.grey[500]))
            else ...(_recentInvoices.take(20).map((inv) {
              final dt = DateTime.tryParse(inv['created_at'] ?? '')?.toLocal();
              final dateStr = dt != null ? '${dt.day}/${dt.month}/${dt.year}' : '';
              final total = double.tryParse(inv['total'].toString()) ?? 0;
              final isCash = inv['payment_type'] == 'cash';
              return ListTile(dense: true, contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(radius: 18,
                  backgroundColor: isCash ? const Color(0xFFE8F5E9) : const Color(0xFFFFE0B2),
                  child: Icon(isCash ? Icons.payments : Icons.receipt, size: 18, color: isCash ? Colors.green : const Color(0xFFFF6B00))),
                title: Text(inv['invoice_number'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: Text('${inv['customer_name']} \u2022 $dateStr', style: const TextStyle(fontSize: 12)),
                trailing: Text('\u20B9${fmtPrice(total)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                onTap: () => _openInvoicePdf(inv),
              );
            }).toList()),
          ])),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Container(padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 2))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 28), const SizedBox(height: 8),
        Text(title, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
      ]));
  }
}


// ==================== SCREEN 5: SETTINGS ====================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _gstApplicable = true;
  String _businessName = '';
  String _businessAddress = '';
  String _gstin = '';
  String _phone = '';
  String _defaultPayment = 'credit';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    final meta = supabase.auth.currentUser?.userMetadata ?? {};
    setState(() {
      _gstApplicable = meta['gst_applicable'] == true || meta['gst_applicable'] == null;
      _businessName = meta['business_name'] ?? 'My Business';
      _businessAddress = meta['business_address'] ?? '';
      _gstin = meta['gstin'] ?? '';
      _phone = getPhoneNumber();
      _defaultPayment = meta['default_payment'] ?? 'credit';
    });
  }

  Future<void> _saveToMeta(Map<String, dynamic> data) async {
    try {
      await supabase.auth.updateUser(UserAttributes(data: data));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _editBusinessProfile() async {
    final nameC = TextEditingController(text: _businessName);
    final addressC = TextEditingController(text: _businessAddress);
    final gstinC = TextEditingController(text: _gstin);

    final result = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Business Profile'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameC, decoration: const InputDecoration(
          labelText: 'Business Name *', hintText: 'e.g. Sharma General Store',
          prefixIcon: Icon(Icons.store_outlined))),
        const SizedBox(height: 16),
        TextField(controller: addressC, maxLines: 2, decoration: const InputDecoration(
          labelText: 'Address', hintText: 'e.g. 12, Main Road, Indore',
          prefixIcon: Icon(Icons.location_on_outlined))),
        const SizedBox(height: 16),
        TextField(controller: gstinC, textCapitalization: TextCapitalization.characters, maxLength: 15,
          decoration: const InputDecoration(
            labelText: 'GSTIN', hintText: 'e.g. 22AAAAA0000A1Z5', counterText: '',
            prefixIcon: Icon(Icons.receipt_long_outlined),
            helperText: '15-digit GST number (optional)')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white),
          child: const Text('Save')),
      ],
    ));

    if (result == true && nameC.text.trim().isNotEmpty) {
      await _saveToMeta({
        'business_name': nameC.text.trim(),
        'business_address': addressC.text.trim(),
        'gstin': gstinC.text.trim(),
      });
      setState(() {
        _businessName = nameC.text.trim();
        _businessAddress = addressC.text.trim();
        _gstin = gstinC.text.trim();
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated!'), backgroundColor: Color(0xFFFF6B00)));
    }
  }

  Future<void> _toggleGst(bool value) async {
    setState(() => _gstApplicable = value);
    await _saveToMeta({'gst_applicable': value});
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value ? 'GST enabled' : 'GST disabled — no tax on invoices'),
        backgroundColor: const Color(0xFFFF6B00)));
  }

  Future<void> _changeDefaultPayment() async {
    final selected = await showDialog<String>(context: context, builder: (context) => SimpleDialog(
      title: const Text('Default Payment Type'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'credit'),
          child: Row(children: [
            Icon(Icons.access_time, color: _defaultPayment == 'credit' ? const Color(0xFFFF6B00) : Colors.grey),
            const SizedBox(width: 12),
            const Text('Udhari (Credit)'),
            const Spacer(),
            if (_defaultPayment == 'credit') const Icon(Icons.check_circle, color: Color(0xFFFF6B00), size: 20),
          ]),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'cash'),
          child: Row(children: [
            Icon(Icons.payments, color: _defaultPayment == 'cash' ? const Color(0xFFFF6B00) : Colors.grey),
            const SizedBox(width: 12),
            const Text('Cash Sale'),
            const Spacer(),
            if (_defaultPayment == 'cash') const Icon(Icons.check_circle, color: Color(0xFFFF6B00), size: 20),
          ]),
        ),
      ],
    ));
    if (selected != null && selected != _defaultPayment) {
      setState(() => _defaultPayment = selected);
      await _saveToMeta({'default_payment': selected});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Default: ${selected == 'credit' ? 'Udhari' : 'Cash Sale'}'), backgroundColor: const Color(0xFFFF6B00)));
    }
  }

  void _showAbout() {
    showDialog(context: context, builder: (context) => AlertDialog(
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.store, size: 60, color: Color(0xFFFF6B00)),
        const SizedBox(height: 12),
        const Text('HisaabKaro', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFFFF6B00))),
        const SizedBox(height: 4),
        Text('Version 1.0.0', style: TextStyle(color: Colors.grey[600])),
        const SizedBox(height: 16),
        Text('Aapka Voice-First Business Assistant', style: TextStyle(color: Colors.grey[500], fontSize: 13), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text('Made with \u2764\uFE0F for Indian small businesses', style: TextStyle(color: Colors.grey[400], fontSize: 12), textAlign: TextAlign.center),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
          child: const Text('Theek hai', style: TextStyle(color: Color(0xFFFF6B00)))),
      ],
    ));
  }

  Future<void> _clearAllData() async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Sab data delete karein?', style: TextStyle(color: Colors.red)),
      content: const Text('Ye sab customers, products, invoices, aur transactions delete karega. Ye wapas nahi hoga!'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
          child: const Text('Haan, Delete Karo')),
      ],
    ));
    if (confirmed == true) {
      final reallyConfirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('Pakka sure ho?', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        content: const Text('Sab kuch permanently delete hoga. Wapas nahi aayega.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Nahi, Rehne Do')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('HAAN, SAB DELETE KARO')),
        ],
      ));
      if (reallyConfirmed == true) {
        try {
          final uid = supabase.auth.currentUser?.id;
          if (uid == null) return;
          await supabase.from('transactions').delete().eq('user_id', uid);
          await supabase.from('invoices').delete().eq('user_id', uid);
          await supabase.from('products').delete().eq('user_id', uid);
          await supabase.from('customers').delete().eq('user_id', uid);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sab data delete ho gaya!'), backgroundColor: Colors.red));
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.white),
      body: ListView(children: [
        // ---- Business header (tappable) ----
        InkWell(
          onTap: _editBusinessProfile,
          child: Container(padding: const EdgeInsets.all(24), color: const Color(0xFFFFF3E0),
            child: Row(children: [
              const CircleAvatar(radius: 30, backgroundColor: Color(0xFFFF6B00),
                child: Icon(Icons.store, color: Colors.white, size: 30)),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_businessName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text(_phone, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                if (_businessAddress.isNotEmpty) Text(_businessAddress, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                if (_gstin.isNotEmpty) Text('GSTIN: $_gstin', style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w500)),
              ])),
              const Icon(Icons.edit, color: Color(0xFFFF6B00), size: 20),
            ])),
        ),

        const SizedBox(height: 8),
        _sectionHeader('BUSINESS SETTINGS'),

        ListTile(
          leading: const Icon(Icons.person, color: Color(0xFFFF6B00)),
          title: const Text('Business Profile'),
          subtitle: const Text('Name, address, GSTIN', style: TextStyle(fontSize: 12, color: Colors.grey)),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: _editBusinessProfile,
        ),

        SwitchListTile(
          secondary: const Icon(Icons.receipt_long, color: Color(0xFFFF6B00)),
          title: const Text('GST Applicable'),
          subtitle: Text(_gstApplicable ? 'GST on invoices (item-wise)' : 'No tax on invoices',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
          value: _gstApplicable,
          activeColor: const Color(0xFFFF6B00),
          onChanged: _toggleGst,
        ),

        ListTile(
          leading: const Icon(Icons.payments, color: Color(0xFFFF6B00)),
          title: const Text('Default Payment Type'),
          subtitle: Text(_defaultPayment == 'credit' ? 'Udhari (Credit)' : 'Cash Sale',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: _changeDefaultPayment,
        ),

        const Divider(height: 1),
        _sectionHeader('APP SETTINGS'),

        ListTile(
          leading: const Icon(Icons.notifications, color: Color(0xFFFF6B00)),
          title: const Text('Payment Reminders'),
          subtitle: const Text('WhatsApp pe yaad dilao', style: TextStyle(fontSize: 12, color: Colors.grey)),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xFFFFF3E0), borderRadius: BorderRadius.circular(12)),
            child: const Text('Jaldi Aayega', style: TextStyle(fontSize: 11, color: Color(0xFFFF6B00), fontWeight: FontWeight.w600)),
          ),
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('WhatsApp reminders jaldi aa rahe hain! \u{1F680}'), backgroundColor: Color(0xFFFF6B00))),
        ),

        const Divider(height: 1),
        _sectionHeader('OTHER'),

        ListTile(
          leading: const Icon(Icons.info_outline, color: Color(0xFFFF6B00)),
          title: const Text('About HisaabKaro'),
          subtitle: const Text('Version 1.0.0', style: TextStyle(fontSize: 12, color: Colors.grey)),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: _showAbout,
        ),

        ListTile(
          leading: const Icon(Icons.delete_forever, color: Colors.red),
          title: const Text('Delete All Data', style: TextStyle(color: Colors.red)),
          subtitle: const Text('Sab customers, products, invoices hatao', style: TextStyle(fontSize: 12, color: Colors.grey)),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: _clearAllData,
        ),

        const SizedBox(height: 16),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('Logout'),
            onPressed: () async {
              await supabase.auth.signOut();
              if (context.mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red),
              padding: const EdgeInsets.symmetric(vertical: 14)),
          )),
        const SizedBox(height: 32),
      ]),
    );
  }

  static Widget _sectionHeader(String text) => Padding(
    padding: const EdgeInsets.only(left: 16, top: 12, bottom: 4),
    child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey[500], letterSpacing: 1)));
}
