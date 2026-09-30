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

class JetjonApp extends StatelessWidget {
  const JetjonApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
  final _urlController = TextEditingController();
  late AnimationController _animController;
  late Animation<double> _fadeAnim;

  bool _isLoading = false;
  bool _showWebView = false;
  bool _isPageLoaded = false;
  WebViewController? _webViewController;
  File? _logFile;

  static const String _networkInterceptorJs = """
    (function() {
      if (window.__nexusLoggerInstalled) return;
      window.__nexusLoggerInstalled = true;
      function isImportant(url) {
        if (!url) return false;
        var u = url.toLowerCase();
        if (u.match(/\\.(png|jpg|jpeg|gif|webp|svg|ico|css|woff|woff2|ttf|js)(\\?.*)?\$/)) return false;
        if (u.includes('google-analytics') || u.includes('sentry') || u.includes('hotjar')) return false;
        return u.includes('digikala') || u.includes('/api/') || u.includes('user') || u.includes('auth');
      }
      function sendToFlutter(payload) {
        try { if (window.JetLogChannel) window.JetLogChannel.postMessage(JSON.stringify(payload)); } catch(e) {}
      }
      var originalFetch = window.fetch;
      window.fetch = async function() {
        var args = Array.from(arguments);
        var resource = args[0]; var config = args[1] || {};
        var url = typeof resource === 'string' ? resource : (resource ? resource.url : '');
        var method = config.method || 'GET';
        if (!isImportant(url)) return originalFetch.apply(this, args);
        try {
          var response = await originalFetch.apply(this, args);
          var clone = response.clone();
          var resBody = await clone.text().catch(()=> '[Non-readable]');
          sendToFlutter({type: 'FETCH', url: url, method: method, reqHeaders: config.headers, reqBody: config.body, status: response.status, resBody: resBody});
          return response;
        } catch(err) { sendToFlutter({type: 'FETCH_ERROR', url: url, method: method, error: err.toString()}); throw err; }
      };
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m,u){ this._url=u; this._method=m; this._headers={}; return origOpen.apply(this, arguments);};
      XMLHttpRequest.prototype.setRequestHeader = function(h,v){ this._headers[h]=v; return XMLHttpRequest.prototype.setRequestHeader.apply; };
      XMLHttpRequest.prototype.send = function(b){
        var self=this; if(isImportant(self._url)){
          self._reqBody=b;
          self.addEventListener('load', function(){ sendToFlutter({type:'XHR', url:self._url, method:self._method, reqHeaders:self._headers, reqBody:self._reqBody, status:self.status, resBody:self.responseText});});
        } return origSend.apply(this, arguments);
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
    if (!await _logFile!.exists()) await _logFile!.create(recursive: true);
  }

  Future<void> _appendLog(String jsonString) async {
    if (_logFile == null) await _initLogFile();
    try {
      final data = json.decode(jsonString);
      final buffer = StringBuffer();
      buffer.writeln("================ ${DateTime.now().toIso8601String()} ================");
      buffer.writeln("URL: ${data['url']} | ${data['method']} | ${data['status']}");
      buffer.writeln("Body: ${data['resBody'] ?? data['error']}");
      buffer.writeln("====================================================\n");
      await _logFile!.writeAsString(buffer.toString(), mode: FileMode.append);
    } catch (_) {}
  }

  void _resetApp() async {
    await WebViewCookieManager().clearCookies();
    setState(() { _showWebView = false; _isLoading = false; _isPageLoaded = false; _webViewController = null; _urlController.clear(); });
  }

  Future<void> _processUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || !url.startsWith("http")) {
      _showSnack("لینک وارد شده معتبر نیست", isError: true); return;
    }
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse(url), headers: {"X-Client-App": "JetApp-Secure-Client", "User-Agent": "JetAppClient/1.0"});
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        var sessionData = data['session'] ?? data;
        List<dynamic> cookies = [];
        if (sessionData is List) cookies = sessionData;
        else if (sessionData is Map && sessionData.containsKey('cookies')) cookies = sessionData['cookies'];
        if (cookies.isNotEmpty) await _setupWebView(cookies);
        else { _showSnack("کوکی معتبری در لینک یافت نشد", isError: true); setState(()=> _isLoading=false); }
      } else { _showSnack("لینک منقضی شده یا نامعتبر است", isError: true); setState(()=> _isLoading=false); }
    } catch (e) { _showSnack("خطا در ارتباط با سرور", isError: true); setState(()=> _isLoading=false); }
  }

  // دقیقاً همان کدهای تزریق کوکی از نسخه قدیمی شما که به درستی کار می‌کرد
  Future<void> _setupWebView(List<dynamic> cookies) async {
    final cookieManager = WebViewCookieManager(); 
    await cookieManager.clearCookies();
    
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

    final controller = WebViewController();
    await controller.clearCache(); 
    await controller.clearLocalStorage();
    
    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController).setMediaPlaybackRequiresUserGesture(false);
    }
    
    await controller.addJavaScriptChannel('JetLogChannel', onMessageReceived: (m) => _appendLog(m.message));
    
    controller..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) async => await controller.runJavaScript(_networkInterceptorJs), 
        onPageFinished: (_) async { 
          await controller.runJavaScript(_networkInterceptorJs); 
          setState(()=> _isPageLoaded=true); 
        }
      ));
      
    await controller.loadRequest(Uri.parse('https://www.digikala.com/profile/'));
    setState(() { _webViewController = controller; _showWebView = true; _isLoading = false; });
  }

  void _showSnack(String msg, {bool isError=false}){
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: isError ? const Color(0xFFEF4056) : const Color(0xFF0F0F0F), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F9F9),
      appBar: _showWebView ? AppBar(
        backgroundColor: Colors.white, elevation: 0, centerTitle: true,
        title: Text("حساب کاربری", style: GoogleFonts.vazirmatn(fontWeight: FontWeight.w700, fontSize: 16, color: const Color(0xFF0F0F0F))),
        leading: IconButton(icon: const Icon(Icons.arrow_forward_rounded, color: Colors.black), onPressed: _resetApp),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(height: 1, color: const Color(0xFFF0F0F0))),
      ) : null,
      body: _showWebView ? Stack(children: [
        WebViewWidget(controller: _webViewController!),
        if(!_isPageLoaded) Container(color: Colors.white, child: const Center(child: CircularProgressIndicator(color: Color(0xFFEF4056)))),
      ]) : FadeTransition(
        opacity: _fadeAnim,
        child: SingleChildScrollView(
          child: Column(
            children: [
              // Header
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
                  const SizedBox(height: 6),
                  Text("ورود امن و آنی به دیجی‌کالا", style: GoogleFonts.vazirmatn(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w300)),
                  const SizedBox(height: 8),
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
                        Text("لینک ورود خود را وارد کنید", style: GoogleFonts.vazirmatn(fontWeight: FontWeight.w700, fontSize: 15, color: const Color(0xFF0F0F0F))),
                      ]),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _urlController,
                        textDirection: TextDirection.ltr,
                        style: GoogleFonts.jetBrainsMono(fontSize: 13, color: const Color(0xFF0F0F0F)),
                        decoration: InputDecoration(
                          hintText: "https://...",
                          hintStyle: GoogleFonts.jetBrainsMono(color: const Color(0xFFC0C2C5), fontSize: 13),
                          filled: true, fillColor: const Color(0xFFF7F7F7),
                          prefixIcon: Icon(Icons.link_rounded, color: _urlController.text.isNotEmpty ? const Color(0xFFEF4056) : const Color(0xFFC0C2C5)),
                          suffixIcon: _urlController.text.isNotEmpty ? IconButton(icon: const Icon(Icons.clear_rounded, size: 18), onPressed: ()=> _urlController.clear()) : null,
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
                          onPressed: _isLoading ? null : _processUrl,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFEF4056),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shadowColor: const Color(0xFFEF4056).withOpacity(0.4),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: _isLoading ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
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
              // Trust badges
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
                      } catch (e) {
                        _showSnack("نمی‌توان تلگرام را باز کرد", isError: true);
                      }
                    }
                  ),
                ]),
              ),
              const SizedBox(height: 24),
              TextButton(onPressed: (){
                final path = _logFile?.path ?? "";
                showDialog(context: context, builder: (ctx)=> AlertDialog(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: Text("فایل گزارش", style: GoogleFonts.vazirmatn(fontWeight: FontWeight.bold, fontSize: 14)),
                  content: SelectableText(path, style: GoogleFonts.jetBrainsMono(fontSize: 11)),
                  actions: [TextButton(onPressed: ()=> Navigator.pop(ctx), child: const Text("بستن"))],
                ));
              }, child: Text("مشاهده مسیر لاگ‌ها", style: GoogleFonts.vazirmatn(fontSize: 11, color: const Color(0xFFC0C2C5)))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trustItem(IconData icon, String label, {VoidCallback? onTap}){
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
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10)]
          ), 
          child: Icon(icon, size: 18, color: const Color(0xFF0F0F0F))
        ),
        const SizedBox(height: 6),
        Text(label, style: GoogleFonts.vazirmatn(fontSize: 11, color: const Color(0xFF81858B), fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
