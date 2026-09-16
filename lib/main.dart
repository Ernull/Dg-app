import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

// ---------------------------------------------------
// آدرس پایه سرور شما (بدون لایسنس آخر)
// اگر دامین شما تغییر کرد، فقط این خط را ویرایش کنید
const String apiBaseUrl = "https://dijijet.bond/auth/";
// ---------------------------------------------------

void main() {
  runApp(const JetApp());
}

class JetApp extends StatelessWidget {
  const JetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ورود به حساب',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFEF394E),
          primary: const Color(0xFFEF394E),
        ),
        fontFamily: 'Tahoma',
      ),
      home: const LoginScreen(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _licenseController = TextEditingController();
  
  bool _isLoading = false;
  bool _showWebView = false;
  bool _isStorageInjected = false;
  bool _isFullyLoaded = false;
  
  WebViewController? _webViewController;
  String _jsInjectionCode = "";

  void _resetApp() {
    setState(() {
      _showWebView = false;
      _isLoading = false;
      _isStorageInjected = false;
      _isFullyLoaded = false;
      _webViewController = null;
      _jsInjectionCode = "";
      _licenseController.clear();
    });
  }

  // استخراج هوشمند لایسنس (حتی اگر کل لینک پیست شود)
  String _extractLicense(String input) {
    String text = input.trim();
    if (text.isEmpty) return "";
    if (text.contains('/')) {
      return text.split('/').last.trim();
    }
    return text;
  }

  Future<void> _processLicense() async {
    final rawInput = _licenseController.text.trim();
    if (rawInput.isEmpty) {
      _showError("لطفاً لایسنس را وارد کنید.");
      return;
    }

    final licenseCode = _extractLicense(rawInput);
    final String targetUrl = "$apiBaseUrl$licenseCode";

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await http.get(
        Uri.parse(targetUrl),
        headers: {
          "X-Client-App": "JetApp-Secure-Client",
          "User-Agent": "JetAppClient/1.0",
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          await _setupWebView(data['session']);
        } else {
          _showError("لایسنس یافت نشد.");
          setState(() { _isLoading = false; });
        }
      } else {
        _showError("لایسنس نامعتبر است یا منقضی شده.");
        setState(() { _isLoading = false; });
      }
    } catch (e) {
      _showError("خطا در ارتباط با سرور.");
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _setupWebView(Map<String, dynamic> sessionData) async {
    final cookieManager = WebViewCookieManager();
    await cookieManager.clearCookies();

    final WebViewController controller = WebViewController();
    await controller.clearCache();
    await controller.clearLocalStorage();

    // تزریق کوکی‌ها
    if (sessionData.containsKey('cookies')) {
      for (var cookie in sessionData['cookies']) {
        String domain = cookie['domain'];
        String name = cookie['name'];
        String value = cookie['value'];
        String path = cookie['path'] ?? '/';

        await cookieManager.setCookie(
          WebViewCookie(name: name, value: value, domain: domain, path: path),
        );
        if (domain.startsWith('.')) {
          await cookieManager.setCookie(
            WebViewCookie(name: name, value: value, domain: domain.substring(1), path: path),
          );
        }
      }
    }

    // آماده‌سازی لوکال استوریج
    _jsInjectionCode = "window.localStorage.clear();\n";
    if (sessionData.containsKey('origins')) {
      var origins = sessionData['origins'][0];
      if (origins.containsKey('localStorage')) {
        for (var item in origins['localStorage']) {
          String key = item['name'];
          String rawValue = item['value'].toString();
          String encodedValue = Uri.encodeComponent(rawValue);
          _jsInjectionCode += "window.localStorage.setItem('$key', decodeURIComponent('$encodedValue'));\n";
        }
      }
    }

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController).setMediaPlaybackRequiresUserGesture(false);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) async {
            if (url.contains("favicon.ico") && !_isStorageInjected) {
              await controller.runJavaScript(_jsInjectionCode);
              _isStorageInjected = true;
              await Future.delayed(const Duration(milliseconds: 300));
              controller.loadRequest(Uri.parse('https://www.digikalajet.com/'));
            } 
            else if (_isStorageInjected && !url.contains("favicon.ico")) {
              setState(() {
                _isFullyLoaded = true;
              });
            }
          },
        ),
      );

    controller.loadRequest(Uri.parse('https://www.digikalajet.com/favicon.ico'));

    setState(() {
      _webViewController = controller;
      _showWebView = true;
      _isLoading = false;
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontFamily: 'Tahoma')),
        backgroundColor: Colors.red[700],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1E293B),
        elevation: 1,
        shadowColor: Colors.black12,
        title: const Text(
          "دیجی‌کالا جت",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          if (_showWebView || _isLoading || _licenseController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.logout_rounded, color: Color(0xFFEF394E)),
              tooltip: 'خروج',
              onPressed: _resetApp,
            ),
        ],
      ),
      body: _showWebView
          ? Stack(
              children: [
                WebViewWidget(controller: _webViewController!),
                if (!_isFullyLoaded)
                  Container(
                    color: Colors.white,
                    child: const Center(
                      child: CircularProgressIndicator(color: Color(0xFFEF394E)),
                    ),
                  ),
              ],
            )
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      "ورود به حساب کاربری",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _licenseController,
                      keyboardType: TextInputType.text,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18, 
                        fontWeight: FontWeight.bold, 
                        letterSpacing: 1.5,
                        color: Color(0xFF334155)
                      ),
                      decoration: InputDecoration(
                        hintText: "لایسنس خود را وارد کنید",
                        hintStyle: const TextStyle(
                          fontSize: 14, 
                          fontWeight: FontWeight.normal, 
                          letterSpacing: 0,
                          color: Color(0xFF94A3B8)
                        ),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFEF394E), width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 18),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFEF394E),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        onPressed: _isLoading ? null : _processLicense,
                        child: _isLoading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : const Text(
                                "تأیید و ورود",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
