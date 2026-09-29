import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  runApp(const NexusApp());
}

class NexusApp extends StatelessWidget {
  const NexusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ورود خودکار دیجی‌کالا',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
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
  final TextEditingController _urlController = TextEditingController();

  bool _isLoading = false;
  bool _showWebView = false;
  bool _isFullyLoaded = false;

  WebViewController? _webViewController;
  File? _logFile;

  // اسکریپت JS برای هوک کردن درخواست‌های شبکه (تنظیم شده برای دیجی‌کالا)
  static const String _networkInterceptorJs = """
    (function() {
      if (window.__nexusLoggerInstalled) return;
      window.__nexusLoggerInstalled = true;

      function isImportant(url) {
        if (!url) return false;
        var u = url.toLowerCase();
        // فیلتر فایل‌های استاتیک
        if (u.match(/\\.(png|jpg|jpeg|gif|webp|svg|ico|css|woff|woff2|ttf|js)(\\?.*)?\$/)) return false;
        if (u.includes('google-analytics') || u.includes('sentry') || u.includes('hotjar')) return false;
        
        return u.includes('digikala') || u.includes('/api/') || u.includes('/v1/') || u.includes('/v2/') || u.includes('user') || u.includes('auth');
      }

      function sendToFlutter(payload) {
        try {
          if (window.JetLogChannel) {
            window.JetLogChannel.postMessage(JSON.stringify(payload));
          }
        } catch(e) {}
      }

      var originalFetch = window.fetch;
      window.fetch = async function() {
        var args = Array.from(arguments);
        var resource = args[0];
        var config = args[1] || {};
        var url = typeof resource === 'string' ? resource : (resource ? resource.url : '');
        var method = config.method || (resource && resource.method) || 'GET';

        if (!isImportant(url)) {
          return originalFetch.apply(this, args);
        }

        var reqHeaders = config.headers || (resource && resource.headers) || {};
        var reqBody = config.body || null;

        try {
          var response = await originalFetch.apply(this, args);
          var clone = response.clone();
          var resBody = '';
          try {
            resBody = await clone.text();
          } catch(e) {
            resBody = '[Non-readable body]';
          }

          sendToFlutter({
            type: 'FETCH',
            url: url,
            method: method,
            reqHeaders: reqHeaders,
            reqBody: reqBody,
            status: response.status,
            resBody: resBody
          });

          return response;
        } catch(err) {
          sendToFlutter({
            type: 'FETCH_ERROR',
            url: url,
            method: method,
            error: err.toString()
          });
          throw err;
        }
      };

      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;

      XMLHttpRequest.prototype.open = function(method, url) {
        this._url = url;
        this._method = method;
        this._headers = {};
        return origOpen.apply(this, arguments);
      };

      XMLHttpRequest.prototype.setRequestHeader = function(header, value) {
        if (this._headers) {
          this._headers[header] = value;
        }
        return origSetHeader.apply(this, arguments);
      };

      XMLHttpRequest.prototype.send = function(body) {
        var self = this;
        var url = self._url;

        if (isImportant(url)) {
          self._reqBody = body;
          self.addEventListener('load', function() {
            sendToFlutter({
              type: 'XHR',
              url: url,
              method: self._method,
              reqHeaders: self._headers,
              reqBody: self._reqBody,
              status: self.status,
              resBody: self.responseText
            });
          });
        }
        return origSend.apply(this, arguments);
      };
    })();
  """;

  @override
  void initState() {
    super.initState();
    _initLogFile();
  }

  Future<void> _initLogFile() async {
    final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/digikala_network_logs.txt');
    if (!await _logFile!.exists()) {
      await _logFile!.create(recursive: true);
    }
  }

  Future<void> _appendLog(String jsonString) async {
    if (_logFile == null) await _initLogFile();

    try {
      final Map<String, dynamic> data = json.decode(jsonString);
      final timestamp = DateTime.now().toIso8601String();

      final buffer = StringBuffer();
      buffer.writeln("================================================================================");
      buffer.writeln("زمان ثبت: $timestamp");
      buffer.writeln("نوع درخواست: ${data['type']} | متد: ${data['method']} | وضعیت: ${data['status'] ?? 'نامشخص'}");
      buffer.writeln("آدرس URL: ${data['url']}");
      buffer.writeln("--- هدرهای درخواست ---");
      buffer.writeln(data['reqHeaders'] != null ? const JsonEncoder.withIndent('  ').convert(data['reqHeaders']) : "ندارد");
      buffer.writeln("--- بدنه ارسالی ---");
      buffer.writeln(data['reqBody'] ?? "خالی");
      buffer.writeln("--- پاسخ سرور ---");
      buffer.writeln(data['resBody'] ?? data['error'] ?? "خالی");
      buffer.writeln("================================================================================\n");

      await _logFile!.writeAsString(buffer.toString(), mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  void _resetApp() async {
    await WebViewCookieManager().clearCookies();
    setState(() {
      _showWebView = false;
      _isLoading = false;
      _isFullyLoaded = false;
      _webViewController = null;
      _urlController.clear();
    });
  }

  Future<void> _processUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || !url.startsWith("http")) {
      _showError("لطفاً یک لینک معتبر وارد کنید.");
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // ارسال درخواست به سرور پایتون برای گرفتن کوکی‌ها
      final response = await http.get(
        Uri.parse(url),
        headers: {
          "X-Client-App": "JetApp-Secure-Client",
          "User-Agent": "JetAppClient/1.0",
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        // پیدا کردن آرایه کوکی‌ها به صورت هوشمند
        List<dynamic> cookies = [];
        var sessionData = data['session'] ?? data;
        
        if (sessionData is List) {
          cookies = sessionData;
        } else if (sessionData is Map && sessionData.containsKey('cookies')) {
          cookies = sessionData['cookies'];
        }

        if (cookies.isNotEmpty) {
          await _setupWebViewAndInjectCookies(cookies);
        } else {
          _showError("کوکی معتبری در لینک یافت نشد.");
          setState(() { _isLoading = false; });
        }
      } else {
        _showError("لینک نامعتبر است یا منقضی شده.");
        setState(() { _isLoading = false; });
      }
    } catch (e) {
      _showError("خطا در ارتباط با سرور.");
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _setupWebViewAndInjectCookies(List<dynamic> cookies) async {
    final cookieManager = WebViewCookieManager();
    await cookieManager.clearCookies();

    // تزریق کوکی‌ها به مرورگر داخلی
    for (var cookie in cookies) {
      String domain = (cookie['domain'] ?? '').toString();
      String name = cookie['name'].toString();
      String value = cookie['value'].toString();
      String path = (cookie['path'] ?? '/').toString();

      // حذف نقطه ابتدای دامنه در صورت وجود برای سازگاری بهتر
      if (domain.startsWith('.')) {
        domain = domain.substring(1);
      }

      await cookieManager.setCookie(
        WebViewCookie(name: name, value: value, domain: domain, path: path),
      );
    }

    final WebViewController controller = WebViewController();
    await controller.clearCache();
    await controller.clearLocalStorage();

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController).setMediaPlaybackRequiresUserGesture(false);
    }

    await controller.addJavaScriptChannel(
      'JetLogChannel',
      onMessageReceived: (JavaScriptMessage message) {
        _appendLog(message.message);
      },
    );

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) async {
            await controller.runJavaScript(_networkInterceptorJs);
          },
          onPageFinished: (String url) async {
            await controller.runJavaScript(_networkInterceptorJs);
            setState(() {
              _isFullyLoaded = true;
            });
          },
        ),
      );

    // پس از تنظیم کوکی‌ها مستقیماً وارد پروفایل می‌شویم
    controller.loadRequest(Uri.parse('https://www.digikala.com/profile/'));

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
      ),
    );
  }

  void _showLogInfo() {
    final path = _logFile?.path ?? "مسیر نامشخص";
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("مسیر فایل لاگ‌ها", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: SelectableText(
          "فایل ذخیره‌شده:\n$path\n\nمی‌توانید با فایل منیجر گوشی یا اتصال به کامپیوتر این فایل متنی را باز کنید.",
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              if (_logFile != null && await _logFile!.exists()) {
                await _logFile!.writeAsString("");
              }
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("لاگ‌ها پاک شدند.")),
              );
            },
            child: const Text("پاک کردن لاگ‌ها", style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("بستن"),
          ),
        ],
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
          "ورود خودکار دیجی‌کالا",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.description_outlined, color: Color(0xFF334155)),
            tooltip: 'مشاهده مسیر فایل لاگ',
            onPressed: _showLogInfo,
          ),
          if (_showWebView || _isLoading || _urlController.text.isNotEmpty)
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
                    const Icon(Icons.shopping_bag_rounded, size: 80, color: Color(0xFFEF394E)),
                    const SizedBox(height: 24),
                    const Text(
                      "دریافت امن اطلاعات حساب",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _urlController,
                      keyboardType: TextInputType.url,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        fontSize: 16, 
                        color: Color(0xFF334155),
                      ),
                      decoration: InputDecoration(
                        hintText: "لینک ورود خود را وارد کنید",
                        hintStyle: const TextStyle(
                          fontSize: 14, 
                          color: Color(0xFF94A3B8),
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
                        contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
                        prefixIcon: const Icon(Icons.link, color: Color(0xFFEF394E)),
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
                        onPressed: _isLoading ? null : _processUrl,
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
                                "تأیید و ورود به دیجی‌کالا",
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
