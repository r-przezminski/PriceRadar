import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tracked_product.dart';
import 'scraper_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PriceRadarApp());
}

class NativeBridge {
  static const MethodChannel _channel = MethodChannel('pl.priceradar.app/native');

  static Future<String> getTrackedJson() async {
    try {
      final res = await _channel.invokeMethod<String>('getTrackedJson');
      return res ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> saveTrackedJson(String json) async {
    try {
      await _channel.invokeMethod('saveTrackedJson', {'json': json});
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> getAgentConfig() async {
    try {
      final raw = await _channel.invokeMethod<String>('getAgentConfig');
      if (raw != null && raw.isNotEmpty) {
        return Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
    } catch (_) {}
    return {'geminiApiKey': '', 'alwaysUseAgent': false};
  }

  static Future<void> saveAgentConfig({
    required String geminiApiKey,
    required bool alwaysUseAgent,
  }) async {
    try {
      await _channel.invokeMethod('saveAgentConfig', {
        'geminiApiKey': geminiApiKey,
        'alwaysUseAgent': alwaysUseAgent,
      });
    } catch (_) {}
  }

  static Future<void> sendNotification(String title, String message) async {
    try {
      await _channel.invokeMethod('sendNotification', {
        'title': title,
        'message': message,
      });
    } catch (_) {}
  }

  static Future<void> openUrl(String url) async {
    try {
      await _channel.invokeMethod('openUrl', {'url': url});
    } catch (_) {}
  }
}

class PriceRadarApp extends StatelessWidget {
  const PriceRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PriceRadar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          surface: const Color(0xFFF1F5F9),
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
      ),
      home: const WatchListScreen(),
    );
  }
}

class WatchListScreen extends StatefulWidget {
  const WatchListScreen({super.key});

  @override
  State<WatchListScreen> createState() => _WatchListScreenState();
}

class _WatchListScreenState extends State<WatchListScreen>
    with WidgetsBindingObserver {
  final TextEditingController _urlController = TextEditingController();
  List<TrackedItem> _items = [];
  bool _isAdding = false;
  bool _isRefreshing = false;
  String _geminiApiKey = '';
  bool _alwaysUseAgent = false;
  Timer? _periodicTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitialData();
    _periodicTimer = Timer.periodic(const Duration(hours: 2), (_) {
      _refreshAllPrices(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodicTimer?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadTrackedItems(checkIfStale: true);
    }
  }

  Future<void> _loadInitialData() async {
    final cfg = await NativeBridge.getAgentConfig();
    if (mounted) {
      setState(() {
        _geminiApiKey = (cfg['geminiApiKey'] ?? '').toString();
        _alwaysUseAgent = cfg['alwaysUseAgent'] == true;
      });
    }
    await _loadTrackedItems();
  }

  Future<void> _loadTrackedItems({bool checkIfStale = false}) async {
    final raw = await NativeBridge.getTrackedJson();
    if (raw.trim().startsWith('[')) {
      try {
        final decoded = jsonDecode(raw) as List;
        setState(() {
          _items = decoded
              .map((e) => TrackedItem.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
        });
      } catch (_) {}
    }
    if (checkIfStale && _shouldAutoCheck()) {
      _refreshAllPrices(silent: true);
    }
  }

  bool _shouldAutoCheck() {
    if (_items.isEmpty) return false;
    DateTime latest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final item in _items) {
      final dt = DateTime.tryParse(item.product.checkedAt);
      if (dt != null && dt.isAfter(latest)) {
        latest = dt;
      }
    }
    return DateTime.now().difference(latest) >= const Duration(hours: 2);
  }

  Future<void> _saveTrackedItems() async {
    final jsonStr = jsonEncode(_items.map((e) => e.toJson()).toList());
    await NativeBridge.saveTrackedJson(jsonStr);
  }

  void _showSnack(String msg, {bool isAlert = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: isAlert ? const Color(0xFF16A34A) : const Color(0xFF0F172A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _openAgentSettingsDialog() async {
    final keyCtrl = TextEditingController(text: _geminiApiKey);
    bool forceAgent = _alwaysUseAgent;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 18,
                right: 18,
                top: 18,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '🤖 Konfiguracja Agenta AI (Screen + WebView)',
                        style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Gdy sklep blokuje zwykłe zapytania (np. Cloudflare) lub wymaga przeglądarki, aplikacja otwiera stronę w WebView na telefonie, zamyka baner cookies, robi zrzut ekranu (screenshot) i przekazuje go do analizy.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF64748B), height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'KLUCZ GEMINI API (OPCJONALNIE - DO ODCZYTU ZE SCREENA PRZEZ AI)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF475569),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: keyCtrl,
                    obscureText: false,
                    style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: 'AIzaSy... (darmowy klucz z Google AI Studio)',
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: () => NativeBridge.openUrl('https://aistudio.google.com/apikey'),
                    child: const Text(
                      '🔑 Pobierz darmowy klucz Gemini API z Google AI Studio ↗',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF2563EB),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Zawsze używaj trybu Agenta (WebView + Screenshot)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Jeśli wyłączone: najpierw szybki odczyt (0,3s), a WebView + Screenshot uruchamia się automatycznie dla trudnych sklepów.',
                      style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                    ),
                    value: forceAgent,
                    onChanged: (val) => setModalState(() => forceAgent = val),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        final newKey = keyCtrl.text.trim();
                        await NativeBridge.saveAgentConfig(
                          geminiApiKey: newKey,
                          alwaysUseAgent: forceAgent,
                        );
                        if (mounted) {
                          setState(() {
                            _geminiApiKey = newKey;
                            _alwaysUseAgent = forceAgent;
                          });
                        }
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        _showSnack('Zapisano ustawienia Agenta!');
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Zapisz ustawienia',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _addProduct({bool forceAgentMode = false}) async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _isAdding) return;

    FocusScope.of(context).unfocus();
    setState(() => _isAdding = true);

    try {
      final useAgent = forceAgentMode || _alwaysUseAgent;
      if (useAgent) {
        _showSnack('🤖 Agent otwiera stronę w WebView i robi zrzut ekranu...');
      }

      final product = await ScraperService.scrapeProduct(
        url,
        geminiApiKey: _geminiApiKey,
        forceAgent: useAgent,
      );
      final offers = await ScraperService.findInOtherStores(
        product.ean,
        product,
        geminiApiKey: _geminiApiKey,
      );

      final newItem = TrackedItem(product: product, offers: offers);
      setState(() {
        _items.insert(0, newItem);
        _urlController.clear();
      });
      await _saveTrackedItems();

      if (offers.isNotEmpty && offers.first.price < product.currentPrice) {
        final msg =
            'Znaleziono taniej w ${offers.first.store}: ${offers.first.price.toStringAsFixed(2)} zł (zamiast ${product.currentPrice.toStringAsFixed(2)} zł)';
        _showSnack('🔔 $msg', isAlert: true);
        await NativeBridge.sendNotification('PriceRadar – Taniej w innym sklepie!', msg);
      } else {
        _showSnack(
          'Dodano (${product.extractionMethod ?? "Scraper"}): ${product.fullName}',
        );
      }
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  Future<void> _rescanWithAgent(int index) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    _showSnack('🤖 Agent otwiera ${item.product.store} w WebView i robi zrzut ekranu...');
    try {
      final updatedProd = await ScraperService.scrapeProduct(
        item.product.url,
        geminiApiKey: _geminiApiKey,
        forceAgent: true,
      );
      final updatedOffers = await ScraperService.findInOtherStores(
        updatedProd.ean,
        updatedProd,
        geminiApiKey: _geminiApiKey,
      );
      setState(() {
        item.product = updatedProd;
        item.offers = updatedOffers;
      });
      await _saveTrackedItems();
      _showSnack(
        '✅ Zaktualizowano przez: ${updatedProd.extractionMethod ?? "WebView Agent"}',
        isAlert: true,
      );
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _refreshAllPrices({bool silent = false}) async {
    if (_items.isEmpty || _isRefreshing) return;
    setState(() => _isRefreshing = true);
    int drops = 0;

    for (final item in _items) {
      try {
        final oldBest = item.bestOffer.price;
        final updatedProd = await ScraperService.scrapeProduct(
          item.product.url,
          geminiApiKey: _geminiApiKey,
          forceAgent: _alwaysUseAgent,
        );
        final updatedOffers = await ScraperService.findInOtherStores(
          updatedProd.ean,
          updatedProd,
          geminiApiKey: _geminiApiKey,
        );
        final newBest = updatedOffers.first.price;

        item.product = updatedProd;
        item.offers = updatedOffers;

        if (newBest < oldBest - 0.005) {
          drops++;
          final msg =
              '${updatedProd.fullName} kosztuje teraz ${newBest.toStringAsFixed(2)} zł w ${updatedOffers.first.store} (spadek z ${oldBest.toStringAsFixed(2)} zł)!';
          _showSnack('📉 $msg', isAlert: true);
          await NativeBridge.sendNotification('📉 Spadek ceny!', msg);
        }
      } catch (_) {}
    }

    await _saveTrackedItems();
    if (mounted) {
      setState(() => _isRefreshing = false);
      if (!silent && drops == 0) {
        _showSnack('Ceny wszystkich obserwowanych produktów są aktualne.');
      }
    }
  }

  Future<void> _deleteItem(int index) async {
    setState(() {
      _items.removeAt(index);
    });
    await _saveTrackedItems();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: const Row(
          children: [
            Text('📡 ', style: TextStyle(fontSize: 20)),
            Text(
              'PriceRadar',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: Color(0xFF0F172A),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _openAgentSettingsDialog,
            tooltip: 'Ustawienia Agenta AI (WebView + Screenshot)',
            icon: Badge(
              isLabelVisible: _geminiApiKey.isNotEmpty || _alwaysUseAgent,
              backgroundColor: const Color(0xFF16A34A),
              child: const Text('🤖', style: TextStyle(fontSize: 18)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton.tonalIcon(
              onPressed: _isRefreshing ? null : () => _refreshAllPrices(silent: false),
              icon: _isRefreshing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync, size: 16),
              label: Text(
                _isRefreshing ? 'Sprawdzam...' : 'Sprawdź ceny',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refreshAllPrices(silent: false),
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            // Karta wklejania linku + przycisk lupki
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'DODAJ PRODUKT Z DOWOLNEGO SKLEPU (LINK URL)',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      if (_alwaysUseAgent)
                        const _Badge(
                          text: '🤖 Tryb Agenta Screen',
                          bg: Color(0xFFDCFCE7),
                          fg: Color(0xFF15803D),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _urlController,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _addProduct(),
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Wklej link do produktu...',
                            isDense: true,
                            filled: true,
                            fillColor: const Color(0xFFF8FAFC),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: FilledButton(
                          onPressed: _isAdding ? null : () => _addProduct(),
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFF2563EB),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: _isAdding
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.search, size: 20, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Nagłówek listy obserwowanych
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'OBSERWOWANE PRODUKTY (${_items.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const Text(
                    'NAJNIŻSZA CENA',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            if (_items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48, horizontal: 16),
                child: Text(
                  'Twoja lista obserwowanych jest pusta.\nWklej link do produktu powyżej i kliknij lupkę.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 13, height: 1.5),
                ),
              )
            else
              ...List.generate(_items.length, (idx) {
                final item = _items[idx];
                final p = item.product;
                final best = item.bestOffer;
                final cheaperOther = item.cheaperInOtherStore;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    elevation: 0.5,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ProductDetailScreen(
                              item: item,
                              onDelete: () => _deleteItem(idx),
                              onRescanWithAgent: () async {
                                await _rescanWithAgent(idx);
                              },
                            ),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            // Miniaturka produktu
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFF1F5F9)),
                              ),
                              child: p.image != null && p.image!.isNotEmpty
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(9),
                                      child: Image.network(
                                        p.image!,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, __, ___) =>
                                            const Icon(Icons.shopping_bag_outlined, color: Colors.grey),
                                      ),
                                    )
                                  : const Icon(Icons.shopping_bag_outlined, color: Colors.grey),
                            ),
                            const SizedBox(width: 12),

                            // Środkowa kolumna
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 5,
                                    runSpacing: 4,
                                    children: [
                                      _Badge(
                                        text: p.category,
                                        bg: const Color(0xFFEFF6FF),
                                        fg: const Color(0xFF2563EB),
                                      ),
                                      if (p.isPromo)
                                        const _Badge(
                                          text: 'PROMOCJA',
                                          bg: Color(0xFFFFE4E6),
                                          fg: Color(0xFFE11D48),
                                        ),
                                      if (cheaperOther)
                                        _Badge(
                                          text: 'Taniej w ${best.store}!',
                                          bg: const Color(0xFFDCFCE7),
                                          fg: const Color(0xFF16A34A),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    p.fullName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Wklejono z: ${p.store} (${p.currentPrice.toStringAsFixed(2)} zł)',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),

                            // Prawa kolumna
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${best.price.toStringAsFixed(2)} zł',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: (cheaperOther || p.isPromo)
                                        ? const Color(0xFF16A34A)
                                        : const Color(0xFF0F172A),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${item.offers.length} ${item.offers.length == 1 ? "sklep" : "sklepy"} ›',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class ProductDetailScreen extends StatefulWidget {
  final TrackedItem item;
  final VoidCallback onDelete;
  final Future<void> Function() onRescanWithAgent;

  const ProductDetailScreen({
    super.key,
    required this.item,
    required this.onDelete,
    required this.onRescanWithAgent,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  bool _isRescanning = false;
  bool _showScreenshot = false;

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return 'Brak danych';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return 'Brak danych';
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }

  String _formatTime(String? iso) {
    if (iso == null || iso.isEmpty) return '-';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '-';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.item.product;
    final offers = widget.item.offers;
    final hasScreenshot =
        p.screenshotBase64 != null && p.screenshotBase64!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Karta Produktu',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          // Główna karta produktu
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                if (p.image != null && p.image!.isNotEmpty)
                  SizedBox(
                    height: 130,
                    child: Image.network(
                      p.image!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.shopping_bag_outlined, size: 64, color: Colors.grey),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  p.fullName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    Material(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: (p.ean != null && p.ean!.isNotEmpty)
                            ? () async {
                                await Clipboard.setData(ClipboardData(text: p.ean!));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '📋 Skopiowano kod EAN: ${p.ean}',
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                      ),
                                      behavior: SnackBarBehavior.floating,
                                      duration: const Duration(seconds: 2),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                  );
                                }
                              }
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'EAN/GTIN: ${p.ean ?? "Nie wykryto"}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  color: Color(0xFF475569),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (p.ean != null && p.ean!.isNotEmpty) ...[
                                const SizedBox(width: 5),
                                const Icon(
                                  Icons.copy_rounded,
                                  size: 12,
                                  color: Color(0xFF475569),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (p.extractionMethod != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          p.extractionMethod!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF2563EB),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Karta porównania cen w sklepach
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PORÓWNANIE CEN W SKLEPACH (${offers.length})',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF475569),
                  ),
                ),
                const SizedBox(height: 10),
                ...List.generate(offers.length, (i) {
                  final o = offers[i];
                  final isCheapest = i == 0;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isCheapest
                          ? const Color(0xFFF0FDF4)
                          : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isCheapest
                            ? const Color(0xFF86EFAC)
                            : const Color(0xFFE2E8F0),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    '${isCheapest ? "🏆" : "🏪"} ${o.store}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                    ),
                                  ),
                                  if (o.isOrigin) ...[
                                    const SizedBox(width: 6),
                                    const _Badge(
                                      text: 'Twój link',
                                      bg: Color(0xFFE2E8F0),
                                      fg: Color(0xFF334155),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              GestureDetector(
                                onTap: () => NativeBridge.openUrl(o.url),
                                child: Text(
                                  '${o.availability} • Otwórz sklep ↗',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: Color(0xFF2563EB),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${o.price.toStringAsFixed(2)} zł',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: isCheapest
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFF0F172A),
                              ),
                            ),
                            if (o.regularPrice > o.price)
                              Text(
                                '${o.regularPrice.toStringAsFixed(2)} zł',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF94A3B8),
                                  decoration: TextDecoration.lineThrough,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Kafelki z informacjami Omnibus / jednostką / końcem promocji
          Row(
            children: [
              Expanded(
                child: _MetaTile(
                  label: 'Najniższa z 30 dni (Omnibus)',
                  value:
                      '${(p.lowestOmnibusPrice ?? p.regularPrice).toStringAsFixed(2)} zł',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetaTile(
                  label: 'Cena za jednostkę',
                  value: p.pricePerUnit ?? 'Brak',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _MetaTile(
                  label: 'Koniec obecnej promocji',
                  value: _formatDate(p.promotionTo),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetaTile(
                  label: 'Ostatnie sprawdzenie',
                  value: _formatTime(p.checkedAt),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Przycisk wymuszenia odczytu przez Agenta WebView + Screenshot
          FilledButton.tonalIcon(
            onPressed: _isRescanning
                ? null
                : () async {
                    setState(() => _isRescanning = true);
                    await widget.onRescanWithAgent();
                    if (mounted) {
                      setState(() {
                        _isRescanning = false;
                        _showScreenshot = true;
                      });
                    }
                  },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEFF6FF),
              foregroundColor: const Color(0xFF1D4ED8),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: _isRescanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('🤖', style: TextStyle(fontSize: 16)),
            label: Text(
              _isRescanning
                  ? 'Agent robi zrzut ekranu w WebView...'
                  : 'Zrób zrzut ekranu i odczytaj przez Agenta',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),

          if (hasScreenshot) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => setState(() => _showScreenshot = !_showScreenshot),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '📸 Zrzut ekranu strony wykonany przez Agenta',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        Icon(
                          _showScreenshot
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                        ),
                      ],
                    ),
                  ),
                  if (_showScreenshot) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(
                        base64Decode(p.screenshotBase64!),
                        fit: BoxFit.contain,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],

          const SizedBox(height: 10),

          // Przycisk usuwania z obserwowanych
          FilledButton.tonalIcon(
            onPressed: () {
              widget.onDelete();
              Navigator.of(context).pop();
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFEE2E2),
              foregroundColor: const Color(0xFFB91C1C),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text(
              'Przestań obserwować produkt',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;

  const _Badge({required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

class _MetaTile extends StatelessWidget {
  final String label;
  final String value;

  const _MetaTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
        ],
      ),
    );
  }
}
