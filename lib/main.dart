import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const JetjonApp());

// کلاس جدید برای نگهداری اطلاعات هر اکانت به‌صورت مجزا
class UserAccount {
  final String title;
  final List<dynamic> cookies;

  UserAccount({required this.title, required this.cookies});
}

class JetjonApp extends StatelessWidget {
  const JetjonApp({super.key});

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
        scaffoldBackgroundColor: const Color(0xFFF9F9F9),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFEF4056),
          secondary: Color(0xFF0F0F0F),
        ),
        textTheme: GoogleFonts.vazirmatnTextTheme(),
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

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _urlController = TextEditingController();
  late AnimationController _animController;
  late Animation<double> _fadeAnim;

  bool _isLoading = false;
  bool _showWebView = false;
  bool _isFullyLoaded = false;

  WebViewController? _webViewController;
  File? _logFile;

  // لیست اکانت‌های استخراج شده
  List<UserAccount> _accounts = [];
  UserAccount? _currentAccount;

  static const String _networkInterceptorJs = """
    (function() {
      if (window.__nexusLoggerInstalled) return;
      window.__nexusLoggerInstalled = true;

      function isImportant(url) {
        if (!url) return false;
        var u = url.toLowerCase();
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
    _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _animController.forward();
    _urlController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _animController.dispose();
    _urlController.dispose();
    super.dispose();
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
      _accounts.clear();
      _currentAccount = null;
      _urlController.clear();
    });
  }

  // متد جدید برای پردازش گروهی لینک‌ها
  Future<void> _processUrls() async {
    final text = _urlController.text.trim();
    if (text.isEmpty) {
      _showError("لطفاً حداقل یک لینک وارد کنید.");
      return;
    }

    // استخراج تمام لینک‌ها بر اساس فاصله یا خط جدید
    final urls = text.split(RegExp(r'\s+')).where((u) => u.startsWith("http")).toList();
    
    if (urls.isEmpty) {
      _showError("لینک معتبری یافت نشد.");
      return;
    }

    setState(() {
      _isLoading = true;
      _accounts.clear();
    });

    int accountCounter = 1;

    for (String url in urls) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: {
            "X-Client-App": "JetApp-Secure-Client",
            "User-Agent": "JetAppClient/1.0",
          },
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          List<dynamic> cookies = [];
          var sessionData = data['session'] ?? data;

          if (sessionData is List) {
            cookies = sessionData;
          } else if (sessionData is Map && sessionData.containsKey('cookies')) {
            cookies = sessionData['cookies'];
          }

          if (cookies.isNotEmpty) {
            _accounts.add(UserAccount(title: "اکانت $accountCounter", cookies: cookies));
            accountCounter++;
          }
        }
      } catch (e) {
        // نادیده گرفتن لینک‌های خراب و ادامه دادن به لینک‌های بعدی
      }
    }

    if (_accounts.isEmpty) {
      _showError("کوکی معتبری در لینک‌های وارد شده یافت نشد.");
      setState(() {
        _isLoading = false;
      });
      return;
    }

    // لود کردن اولین اکانت به‌صورت پیش‌فرض
    await _switchToAccount(_accounts.first);
  }

  // متد کاملاً ایزوله برای جابجایی بین اکانت‌ها بدون تداخل
  Future<void> _switchToAccount(UserAccount account) async {
    setState(() {
      _isLoading = true;
      _isFullyLoaded = false;
      _currentAccount = account;
    });

    final cookieManager = WebViewCookieManager();
    
    // ۱. پاکسازی کامل کوکی‌های قبلی برای جلوگیری از تداخل
    await cookieManager.clearCookies();

    // ۲. تزریق کوکی‌های اکانت جدید
    for (var cookie in account.cookies) {
      String domain = (cookie['domain'] ?? '').toString();
      String name = cookie['name'].toString();
      String value = cookie['value'].toString();
      String path = (cookie['path'] ?? '/').toString();

      if (domain.startsWith('.')) {
        domain = domain.substring(1);
      }

      await cookieManager.setCookie(
        WebViewCookie(name: name, value: value, domain: domain, path: path),
      );
    }

    // ۳. آماده‌سازی و پاکسازی دیتای لوکال کنترلر مرورگر
    if (_webViewController == null) {
      final WebViewController controller = WebViewController();
      
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
        
      _webViewController = controller;
    } else {
      // اگر کنترلر از قبل وجود دارد، کش و حافظه لوکال را خالی می‌کنیم تا سشن‌ها ترکیب نشوند
      await _webViewController!.clearCache();
      try {
        await _webViewController!.runJavaScript("localStorage.clear(); sessionStorage.clear();");
      } catch (_) {}
    }

    // ۴. بارگذاری مجدد صفحه برای اعمال اکانت جدید
    _webViewController!.loadRequest(Uri.parse('https://www.digikala.com/profile/'));

    setState(() {
      _showWebView = true;
      _isLoading = false;
    });
  }

  // نمایش منوی کشویی پایین صفحه برای انتخاب اکانت
  void _showAccountSwitcher() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("سوئیچ بین اکانت‌ها", style: GoogleFonts.vazirmatn(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 10),
              const Divider(color: Color(0xFFF0F0F0)),
              ..._accounts.map((acc) {
                final isSelected = acc == _currentAccount;
                return ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFFEF4056).withOpacity(0.1) : const Color(0xFFF0F0F0),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.person_rounded, color: isSelected ? const Color(0xFFEF4056) : Colors.grey.shade600),
                  ),
                  title: Text(acc.title, style: GoogleFonts.vazirmatn(color: isSelected ? const Color(0xFFEF4056) : Colors.black, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                  trailing: isSelected ? const Icon(Icons.check_circle_rounded, color: Color(0xFFEF4056)) : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    if (!isSelected) {
                      _switchToAccount(acc);
                    }
                  },
                );
              }).toList(),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.vazirmatn()),
        backgroundColor: const Color(0xFFEF4056),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _showLogInfo() {
    final path = _logFile?.path ?? "مسیر نامشخص";
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text("فایل گزارش", style: GoogleFonts.vazirmatn(fontWeight: FontWeight.bold, fontSize: 14)),
        content: SelectableText(path, style: GoogleFonts.jetBrainsMono(fontSize: 11)),
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
      backgroundColor: const Color(0xFFF9F9F9),
      appBar: _showWebView
          ? AppBar(
              backgroundColor: Colors.white,
              elevation: 0,
              centerTitle: true,
              title: Text(_currentAccount?.title ?? "حساب کاربری", style: GoogleFonts.vazirmatn(fontWeight: FontWeight.w700, fontSize: 16, color: const Color(0xFF0F0F0F))),
              leading: IconButton(icon: const Icon(Icons.arrow_forward_rounded, color: Colors.black), onPressed: _resetApp),
              actions: [
                if (_accounts.length > 1) // دکمه سوئیچ فقط وقتی بیش از ۱ اکانت باشد نمایش داده می‌شود
                  IconButton(
                    icon: const Icon(Icons.switch_account_rounded, color: Color(0xFFEF4056)),
                    tooltip: "تغییر اکانت",
                    onPressed: _showAccountSwitcher,
                  ),
              ],
              bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(height: 1, color: const Color(0xFFF0F0F0))),
            )
          : null,
      body: _showWebView
          ? Stack(
              children: [
                WebViewWidget(controller: _webViewController!),
                if (!_isFullyLoaded)
                  Container(
                    color: Colors.white,
                    child: const Center(
                      child: CircularProgressIndicator(color: Color(0xFFEF4056)),
                    ),
                  ),
              ],
            )
          : FadeTransition(
              opacity: _fadeAnim,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(24, 60, 24, 40),
                      decoration: const BoxDecoration(
                        color: Color(0xFF0F0F0F),
                        borderRadius: BorderRadius.only(bottomLeft: Radius.circular(36), bottomRight: Radius.circular(36)),
                      ),
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white10)),
                          child: const Icon(Icons.shopping_bag_outlined, color: Color(0xFFEF4056), size: 36),
                        ),
                        const SizedBox(height: 16),
                        Text("JETJON", style: GoogleFonts.vazirmatn(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 4)),
                        const SizedBox(height: 16),
                        Container(height: 3, width: 32, decoration: BoxDecoration(color: const Color(0xFFEF4056), borderRadius: BorderRadius.circular(10))),
                      ]),
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 30, offset: const Offset(0, 10))],
                          border: Border.all(color: const Color(0xFFF0F0F0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(children: [
                              Container(width: 4, height: 20, decoration: BoxDecoration(color: const Color(0xFFEF4056), borderRadius: BorderRadius.circular(10))),
                              const SizedBox(width: 8),
                              Text("لینک‌های ورود خود را وارد کنید", style: GoogleFonts.vazirmatn(fontWeight: FontWeight.w700, fontSize: 15, color: const Color(0xFF0F0F0F))),
                            ]),
                            const SizedBox(height: 20),
                            TextField(
                              controller: _urlController,
                              textDirection: TextDirection.ltr,
                              maxLines: 5, // تغییر به ۵ خط برای دریافت گروهی لینک‌ها
                              minLines: 1,
                              keyboardType: TextInputType.multiline,
                              style: GoogleFonts.jetBrainsMono(fontSize: 13, color: const Color(0xFF0F0F0F)),
                              decoration: InputDecoration(
                                hintText: "لینک‌ها را با فاصله یا خط جدید وارد کنید...",
                                hintStyle: GoogleFonts.jetBrainsMono(color: const Color(0xFFC0C2C5), fontSize: 12),
                                filled: true,
                                fillColor: const Color(0xFFF7F7F7),
                                prefixIcon: Icon(Icons.link_rounded, color: _urlController.text.isNotEmpty ? const Color(0xFFEF4056) : const Color(0xFFC0C2C5)),
                                suffixIcon: _urlController.text.isNotEmpty ? IconButton(icon: const Icon(Icons.clear_rounded, size: 18), onPressed: () => _urlController.clear()) : null,
                                contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFEEEEEE))),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFEF4056), width: 1.4)),
                              ),
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              height: 54,
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : _processUrls,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFEF4056),
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shadowColor: const Color(0xFFEF4056).withOpacity(0.4),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                ),
                                child: _isLoading
                                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                                    : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                        Text("تایید و ورود", style: GoogleFonts.vazirmatn(fontWeight: FontWeight.w800, fontSize: 15)),
                                        const SizedBox(width: 8),
                                        const Icon(Icons.arrow_back_rounded, size: 18),
                                      ]),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                        _trustItem(Icons.verified_user_outlined, "ورود آنی"),
                        _trustItem(Icons.bolt_rounded, "بدون رمز عبور"),
                        _trustItem(
                          Icons.support_agent_rounded,
                          "پشتیبانی",
                          onTap: () async {
                            final Uri url = Uri.parse('https://t.me/DiGkaalaa');
                            try {
                              await launchUrl(url, mode: LaunchMode.externalApplication);
                            } catch (_) {
                              _showError("نمی‌توان تلگرام را باز کرد");
                            }
                          },
                        ),
                      ]),
                    ),
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: _showLogInfo,
                      child: Text("مشاهده مسیر لاگ‌ها", style: GoogleFonts.vazirmatn(fontSize: 11, color: const Color(0xFFC0C2C5))),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _trustItem(IconData icon, String label, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFF0F0F0)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10)],
          ),
          child: Icon(icon, size: 18, color: const Color(0xFF0F0F0F)),
        ),
        const SizedBox(height: 6),
        Text(label, style: GoogleFonts.vazirmatn(fontSize: 11, color: const Color(0xFF81858B), fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
