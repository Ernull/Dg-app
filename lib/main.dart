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
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
      theme: ThemeData(
        useMaterial3: true,
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
  final TextEditingController _linkController = TextEditingController();
  
  bool _isLoading = false;
  bool _showWebView = false;
  bool _isStorageInjected = false;
  bool _isFullyLoaded = false; // برای مدیریت صفحه لودینگِ روی وب‌ویو
  
  WebViewController? _webViewController;
  String _jsInjectionCode = "";

  void _resetApp() {
    setState(() {
      ŵfalse;
      _isStorageInjected = false;
      _isFullyLoaded = false;
      _webViewController = null;
      _jsInjectionCode = "";
      _linkController.clear();
    });
  }

  Future<void> _processLink() async {
    final link = _linkController.text.trim();
    if (link.isEmpty || !link.startsWith("http")) {
      _showError("لطفاً پیوند معتبر وارد کنید.");
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await http.get(
        Uri.parse(link),
        headers: {
          "X-Client-App": "JetApp-Secure-Client", // هدر امنیتی برای دریافت JSON
          "User-Agent": "JetAppClient/1.0",
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          await _setupWebView(data['session']);
        } else {
          _showError("پیوند نامعتبر یا منقضی است.");
          setState(() { _isLoading = false; });
        }
      } else {
        _showError("خطا در ارتباط با سرور. (HTTP ${response.statusCode})");
        setState(() { _isLoading = false; });
      }
    } catch (e) {
      _showError("خطا در شبکه. لطفاً اینترنت خود را بررسی کنید.");
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _setupWebView(Map<String, dynamic> sessionData) async {
    // 1. پاکسازی کامل نشست‌های قبلی مرورگر
    final cookieManager = WebViewCookieManager();
    await cookieManager.clearCookies();

    final WebViewController controller = WebViewController();
    await controller.clearCache();
    await controller.clearLocalStorage();

    // 2. تزریق کوکی‌ها
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

    // 3. آماده‌سازی امنِ تزریق LocalStorage (حل مشکل کاراکترهای غیرمجاز)
    _jsInjectionCode = "";
    if (sessionData.containsKey('origins')) {
      var origins = sessionData['origins'][0];
      if (origins.containsKey('localStorage')) {
        for (var item in origins['localStorage']) {
          String key = item['name'];
          String rawValue = item['value'].toString();
          // کدگذاری کامل مقدار برای جلوگیری از تداخل نقل‌قول‌ها (Quotes) در JS
          String encodedValue = Uri.encodeComponent(rawValue);
          _jsInjectionCode += "window.localStorage.setItem('$key', decodeURIComponent('$encodedValue'));\n";
        }
      }
    }

    // 4. تنظیمات WebViewController و اجرای مراحل (لود -> تزریق -> رفرش)
    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController).setMediaPlaybackRequiresUserGesture(false);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) async {
            // مرحله اول: سایت لود شده، حالا اطلاعات را تزریق می‌کنیم
            if (!_isStorageInjected && url.contains("digikalajet.com")) {
              
              // علامت‌گذاری به عنوان تزریق‌شده تا در رفرش بعدی حلقه تکرار نشود
              _isStorageInjected = true; 
              
              // اجرای کدهای جاوااسکریپت و ساخت LocalStorage
              await controller.runJavaScript(_jsInjectionCode);
              
              // مکث حیاتی 500 میلی‌ثانیه‌ای برای اطمینان از ذخیره در دیتابیس مرورگر
              await Future.delayed(const Duration(milliseconds: 500));
              
              // مرحله دوم: رفرش صفحه تا دیجی‌کالا متوجه لاگین شود
              await controller.runJavaScript("window.location.href = 'https://www.digikalajet.com/';");
            } 
            // اگر تزریق انجام شده و صفحه در حال لود مجدد است:
            else if (_isStorageInjected) {
              setState(() {
                _isFullyLoaded = true; // لودینگ روی صفحه را محو می‌کنیم
              });
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
          "دیجی‌کالا جت",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_showWebView || _isLoading || _linkController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.logout_rounded),

              tooltip: 'پاکسازی نشست و ورود جدید',
              onPressed: _resetApp,
            ),
        ],
      ),
      body: _showWebView
          ? Stack(
              children: [
                // مرورگر اصلی
                WebViewWidget(controller: _webViewController!),
                
                // لودینگ پوششی (تا زمانی که کوکی‌ها ست نشده‌اند سایت خالی را نشان نمی‌دهد)
                if (!_isFullyLoaded)
                  Container(
                    color: const Color(0xFFF8FAFC),
                    child: const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(color: Color(0xFFEF394E)),
                          SizedBox(height: 16),
                          Text("در حال بارگذاری حساب...", style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),
              ],
            )
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
                      "پیوندی که از ربات دریافت کرده‌اید را در کادر زیر قرار دهید",
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
                   ⅔I ³  ),
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
