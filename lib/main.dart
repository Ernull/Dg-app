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
          "X-Client-App": "JetApp-Secure-Client",
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
    final cookieManager = WebViewCookieManager();
    await cookieManager.clearCookies();

    final WebViewController controller = WebViewController();
    await controller.clearCache();
    await controller.clearLocalStorage();

    // ۱. تزریق دقیق کوکی‌ها (هم برای دامین با نقطه و هم بدون نقطه)
    if (sessionData.containsKey('cookies')) {
      for (var cookie in sessionData['cookies']) {
        String domain = cookie['domain'];
        String name = cookie['name'];
        String value = cookie['value'];
        String path = cookie['path'] ?? '/';

        await cookieManager.setCookie(
          WebViewCookie(name: name, value: value, domain: domain, path: path),
        );
        
        // اطمینان از اعمال کوکی در فرمت‌های مختلف دامین
        if (domain.startsWith('.')) {
          await cookieManager.setCookie(
            WebViewCookie(name: name, value: value, domain: domain.substring(1), path: path),
          );
        }
      }
    }

    // ۲. آماده‌سازی دستورات جاوااسکریپت برای حافظه مرورگر
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
            // ۳. ترفند اصلی: اول یک صفحه خالی (favicon) باز می‌شود
            // اینجا سایت واکنشی نشان نمی‌دهد، پس بهترین زمان برای تزریق است!
            if (url.contains("favicon.ico") && !_isStorageInjected) {
              await controller.runJavaScript(_jsInjectionCode);
              
              _isStorageInjected = true;
              
              // یک مکث کوتاه برای نوشته شدن کامل روی حافظه گوشی
              await Future.delayed(const Duration(milliseconds: 300));
              
              // حالا که اطلاعات نشست امن شد، سایت اصلی دیجی‌کالا را لود می‌کنیم
              controller.loadRequest(Uri.parse('https://www.digikalajet.com/'));
            } 
            // وقتی سایت اصلی لود شد، لودینگ پوششی را حذف می‌کنیم
            else if (_isStorageInjected && !url.contains("favicon.ico")) {
              setState(() {
                _isFullyLoaded = true;
              });
            }
          },
        ),
      );

    // شروع فرآیند: لود کردن یک فایل استاتیک از دامین دیجی‌کالا جت (برای دور زدن کدهای ریکت)
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
          // تغییر آیکون به خروج از حساب (طبق درخواست شما)
          if (_showWebView || _isLoading || _linkController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.logout_rounded),
              tooltip: 'خروج و اکانت جدید',
              onPressed: _resetApp,
            ),
        ],
      ),
      body: _showWebView
          ? Stack(
              children: [
                WebViewWidget(controller: _webViewController!),
                
                // این لودینگ فقط تا زمانی نشان داده می‌شود که تزریق با موفقیت تمام شده باشد
                if (!_isFullyLoaded)
                  Container(
                    color: const Color(0xFFF8FAFC),
                    child: const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(color: Color(0xFFEF394E)),
                          SizedBox(height: 16),
                          Text("در حال تأیید ورود...", style: TextStyle(color: Colors.grey)),
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
