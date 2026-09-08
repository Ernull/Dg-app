import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  runApp(const JetSecureApp());
}

class JetSecureApp extends StatelessWidget {
  const JetSecureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ورود به جت',
      debugShowCheckedModeBanner: false,
      // راست‌چین کردن کل اپلیکیشن
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
      // تم دیجی‌کالا با Material 3
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFEF394E),
          primary: const Color(0xFFEF394E),
        ),
        fontFamily: 'Tahoma', // یا هر فونت دلخواه دیگر
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
  final TextEditingController _linkController = TextEditingController();
  
  bool _isLoading = false;
  bool _showWebView = false;
  bool _isStorageInjected = false;
  
  WebViewController? _webViewController;
  String _jsInjectionCode = "";

  // تابع بازگشت به حالت اولیه (پاکسازی)
  void _resetApp() {
    setState(() {
      _showWebView = false;
      _isLoading = false;
      _isStorageInjected = false;
      _webViewController = null;
      _jsInjectionCode = "";
      _linkController.clear();
    });
  }

  // تابع دریافت اطلاعات از لینک ربات و تزریق
  Future<void> _processLink() async {
    final link = _linkController.text.trim();
    if (link.isEmpty || !link.startsWith("http")) {
      _showError("لطفاً یک لینک معتبر وارد کنید.");
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // ارسال درخواست به سرور پایتون شما با هدرهای امنیتی
      final response = await http.get(
        Uri.parse(link),
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
          _showError("لینک نامعتبر است یا منقضی شده.");
          setState(() { _isLoading = false; });
        }
      } else {
        _showError("خطا در ارتباط با سرور. لینک منقضی است.");
        setState(() { _isLoading = false; });
      }
    } catch (e) {
      _showError("خطا در ارتباط با شبکه.");
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _setupWebView(Map<String, dynamic> sessionData) async {
    // 1. تزریق کوکی‌ها
    final cookieManager = WebViewCookieManager();
    await cookieManager.clearCookies(); // پاک کردن سشن‌های قبلی

    if (sessionData.containsKey('cookies')) {
      for (var cookie in sessionData['cookies']) {
        await cookieManager.setCookie(
          WebViewCookie(
            name: cookie['name'],
            value: cookie['value'],
            domain: cookie['domain'],
            path: cookie['path'],
          ),
        );
      }
    }

    // 2. آماده‌سازی کدهای جاوااسکریپت برای تزریق LocalStorage
    _jsInjectionCode = "";
    if (sessionData.containsKey('origins')) {
      var origins = sessionData['origins'][0];
      if (origins.containsKey('localStorage')) {
        for (var item in origins['localStorage']) {
          String key = item['name'];
          // جلوگیری از تداخل کاراکترهای رشته‌ای در JS
          String val = item['value'].toString().replaceAll("'", "\\'").replaceAll('\n', '\\n');
          _jsInjectionCode += "window.localStorage.setItem('$key', '$val');\n";
        }
      }
    }

    // 3. پیکربندی WebViewController (نسخه 4)
    final WebViewController controller = WebViewController();
    
    // تنظیمات اختصاصی اندروید برای پشتیبانی بهتر
    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController).setMediaPlaybackRequiresUserGesture(false);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) async {
            // وقتی برای اولین بار سایت لود شد، استوریج‌ها را تزریق و ریلود کن
            if (!_isStorageInjected && url.contains("digikalajet.com")) {
              await controller.runJavaScript(_jsInjectionCode);
              setState(() {
                _isStorageInjected = true;
              });
              controller.reload(); // رفرش برای اعمال تغییرات در سایت
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.digikalajet.com/'));

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
        backgroundColor: Colors.red[800],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEF394E),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          "ورود به دیجی‌کالا جت",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          // دکمه پاکسازی و استفاده برای لینک بعدی
          if (_showWebView || _isLoading || _linkController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.cleaning_services_rounded),
              tooltip: 'پاکسازی و لینک جدید',
              onPressed: _resetApp,
            ),
        ],
      ),
      body: _showWebView
          ? WebViewWidget(controller: _webViewController!)
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.shopping_bag_rounded,
                      size: 80,
                      color: Color(0xFFEF394E),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "لینک اختصاصی را وارد کنید",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "لینک را در کادر زیر قرار دهید",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 30),
                    TextField(
                      controller: _linkController,
                      keyboardType: TextInputType.url,
                      textDirection: TextDirection.ltr,
                      onChanged: (val) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: "https://...",
                        filled: true,
                        fillColor: Colors.white,
                        prefixIcon: const Icon(Icons.link, color: Colors.grey),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFEF394E),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 2,
                        ),
                        onPressed: _isLoading ? null : _processLink,
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
                                "ورود به حساب",
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
