import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const String apiBaseUrl = "https://dijijet.bond/auth/";

void main() {
  runApp(const JetApp());
}

class JetApp extends StatelessWidget {
  const JetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'دیجی‌کالا جت',
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
  final TextEditingController _licenseController = TextEditingController();

  bool _isLoading = false;
  bool _showWebView = false;
  bool _isStorageInjected = false;
  bool _isFullyLoaded = false;

  WebViewController? _webViewController;
  String _jsInjectionCode = "";
  File? _logFile;

  // اسکریپت JS برای هوک کردن Fetch و XMLHttpRequest و فیلتر کردن درخواست‌های بیهوده
  static const String _networkInterceptorJs = """
    (function() {
      if (window.__jetLoggerInstalled) return;
      window.__jetLoggerInstalled = true;

      function isImportant(url) {
        if (!url) return false;
        var u = url.toLowerCase();
        // فیلتر فایل‌های استاتیک و آیکون‌ها و اسکریپت‌ها
        if (u.match(/\\.(png|jpg|jpeg|gif|webp|svg|ico|css|woff|woff2|ttf|js)(\\?.*)?\$/)) return false;
        if (u.includes('google-analytics') || u.includes('sentry') || u.includes('hotjar') || u.includes('favicon.ico')) return false;
        
        // صرفاً مسیرهای API و سرویس‌های مرتبط با جت و کاربر
        return u.includes('digikala') || u.includes('jet') || u.includes('/api/') || u.includes('/v1/') || u.includes('/v2/') || u.includes('user') || u.includes('auth');
      }

      function sendToFlutter(payload) {
        try {
          if (window.JetLogChannel) {
            window.JetLogChannel.postMessage(JSON.stringify(payload));
          }
        } catch(e) {}
      }

      // رهگیری Fetch API
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

      // رهگیری XMLHttpRequest (XHR)
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
    _logFile = File('${dir.path}/jet_network_logs.txt');
    if (!await _logFile!.exists()) {
      await _logFile!.create(recursive: true);
    }
  }

  // ذخیره لاگ مرتب‌شده در فایل متنی
  Future<void> _appendLog(String jsonString) async {
    if (_logFile == null) await _initLogFile();

    try {
      final Map<String, dynamic> data = json.decode(jsonString);
      final timestamp = DateTime.now().toIso8601String();

      final buffer = StringBuffer();
      buffer.writeln("================================================================================");
      buffer.writeln("زمان ثبت: $timestamp");
      buffer.writeln("نوع درخواست: ${data['type']} | متد: ${data['method']} | وضعیت (Status): ${data['status'] ?? 'نامشخص'}");
      buffer.writeln("آدرس URL: ${data['url']}");
      buffer.writeln("--- هدرهای درخواست (Request Headers) ---");
      buffer.writeln(data['reqHeaders'] != null ? const JsonEncoder.withIndent('  ').convert(data['reqHeaders']) : "ندارد");
      buffer.writeln("--- بدنه ارسالی (Request Body) ---");
      buffer.writeln(data['reqBody'] ?? "خالی");
      buffer.writeln("--- بدنه پاسخ سرور (Response Body) ---");
      buffer.writeln(data['resBody'] ?? data['error'] ?? "خالی");
      buffer.writeln("================================================================================\n");

      await _logFile!.writeAsString(buffer.toString(), mode: FileMode.append, flush: true);
    } catch (_) {}
  }

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

    // تنظیم LocalStorage
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

    // اضافه کردن کانال ارتباطی لاگ به وب‌ویو
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
            // تزریق مداوم اسکریپت اسنیفر در شروع هر صفحه برای از دست نرفتن ریکوئست‌ها
            await controller.runJavaScript(_networkInterceptorJs);
          },
          onPageFinished: (String url) async {
            await controller.runJavaScript(_networkInterceptorJs);

            if (url.contains("favicon.ico") && !_isStorageInjected) {
              await controller.runJavaScript(_jsInjectionCode);
              _isStorageInjected = true;
              await Future.delayed(const Duration(milliseconds: 300));
              controller.loadRequest(Uri.parse('https://www.digikalajet.com/'));
            } else if (_isStorageInjected && !url.contains("favicon.ico")) {
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
          "دیجی‌کالا جت",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.description_outlined, color: Color(0xFF334155)),
            tooltip: 'مشاهده مسیر فایل لاگ',
            onPressed: _showLogInfo,
          ),
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
                        color: Color(0xFF334155),
                      ),
                      decoration: InputDecoration(
                        hintText: "لایسنس خود را وارد کنید",
                        hintStyle: const TextStyle(
                          fontSize: 14, 
                          fontWeight: FontWeight.normal, 
                          letterSpacing: 0,
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
