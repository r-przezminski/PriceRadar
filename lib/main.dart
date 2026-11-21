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

/// Czyści wpisany przez użytkownika tag (spacje, '#', limit długości).
String normalizeTagInput(String raw) {
  var t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.startsWith('#')) t = t.substring(1).trim();
  if (t.length > 24) t = t.substring(0, 24).trim();
  return t;
}

class NativeBridge {
  static const MethodChannel _channel = MethodChannel('pl.priceradar.app/native');
  static void Function(String url)? onSharedUrlCallback;

  static String? extractOnlyUrl(String input) {
    if (input.trim().isEmpty) return null;
    final match = RegExp(r'https?://[^\s<>"]+').firstMatch(input);
    if (match != null) {
      var url = match.group(0)!;
      while (url.endsWith('.') ||
          url.endsWith(',') ||
          url.endsWith(')') ||
          url.endsWith(']') ||
          url.endsWith(';') ||
          url.endsWith('!') ||
          url.endsWith('?')) {
        url = url.substring(0, url.length - 1);
      }
      return url;
    }
    return null;
  }

  static void initSharedUrlListener() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedUrlReceived') {
        final url = call.arguments?.toString();
        if (url != null && url.isNotEmpty) {
          onSharedUrlCallback?.call(url);
        }
      }
    });
  }

  static Future<String?> getInitialSharedUrl() async {
    try {
      final res = await _channel.invokeMethod<String>('getInitialSharedUrl');
      return (res != null && res.isNotEmpty) ? res : null;
    } catch (_) {
      return null;
    }
  }

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
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _isEndDrawerOpen = false;
  final Set<String> _selectedStores = {};
  final Set<String> _selectedAutoTags = {};
  final Set<String> _selectedCustomTags = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NativeBridge.initSharedUrlListener();
    NativeBridge.onSharedUrlCallback = (sharedUrl) {
      _handleIncomingUrl(sharedUrl);
    };
    _loadInitialData();
    _periodicTimer = Timer.periodic(const Duration(hours: 2), (_) {
      _refreshAllPrices(silent: true);
    });
  }

  void _handleIncomingUrl(String text) {
    final cleanUrl = NativeBridge.extractOnlyUrl(text) ?? text.trim();
    if (cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://')) {
      _urlController.text = cleanUrl;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _addProduct();
      });
    }
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
    final initialUrl = await NativeBridge.getInitialSharedUrl();
    if (initialUrl != null && initialUrl.isNotEmpty) {
      _handleIncomingUrl(initialUrl);
    }
  }

  Future<void> _loadTrackedItems({bool checkIfStale = false}) async {
    final raw = await NativeBridge.getTrackedJson();
    bool upgradedCategories = false;
    if (raw.trim().startsWith('[')) {
      try {
        final decoded = jsonDecode(raw) as List;
        final loaded = decoded
            .map((e) => TrackedItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        const genericCats = {
          'Elektronika', 'Drogeria', 'Marketplace', 'Sklep', 'Apteka', 'Perfumeria', 'Inny'
        };
        for (final item in loaded) {
          if (genericCats.contains(item.product.category)) {
            final better = ScraperService.detectSmartCategory(
              fullName: item.product.fullName,
              url: item.product.url,
              storeFallbackCategory: item.product.category,
            );
            if (better != item.product.category) {
              item.product.category = better;
              upgradedCategories = true;
            }
          }
        }
        setState(() {
          _items = loaded;
        });
      } catch (_) {}
    }
    if (upgradedCategories) {
      await _saveTrackedItems();
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
    final rawInput = _urlController.text.trim();
    final url = NativeBridge.extractOnlyUrl(rawInput) ?? rawInput;
    if (url.isEmpty || _isAdding) return;
    _urlController.text = url;

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

  // ---------- Filtrowanie (panel boczny) ----------

  static List<String> _sortedCaseInsensitive(Iterable<String> values) {
    final byLower = <String, String>{};
    for (final v in values) {
      byLower.putIfAbsent(v.toLowerCase(), () => v);
    }
    return byLower.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Sklepy występujące aktualnie na liście produktów.
  List<String> _availableStores() {
    final all = <String>{};
    for (final item in _items) {
      all.addAll(item.stores);
    }
    return _sortedCaseInsensitive(all);
  }

  /// Tagi automatyczne (kategoria, PROMOCJA, Taniej w innym sklepie) obecne na liście.
  List<String> _availableAutoTags() =>
      _sortedCaseInsensitive(_items.expand((i) => i.autoTags));

  /// Własne tagi użytkownika obecne na liście.
  List<String> _availableCustomTags() =>
      _sortedCaseInsensitive(_items.expand((i) => i.tags));

  bool _hasAny(Iterable<String> have, Set<String> wanted) {
    final lower = have.map((t) => t.toLowerCase()).toSet();
    return wanted.any((t) => lower.contains(t.toLowerCase()));
  }

  /// W obrębie jednej grupy wystarczy dowolny z wybranych (LUB);
  /// grupy (sklepy / tagi / własne tagi) łączą się razem (I).
  bool _matchesFilters(TrackedItem item) {
    if (_selectedStores.isNotEmpty && !item.stores.any(_selectedStores.contains)) {
      return false;
    }
    if (_selectedAutoTags.isNotEmpty && !_hasAny(item.autoTags, _selectedAutoTags)) {
      return false;
    }
    if (_selectedCustomTags.isNotEmpty && !_hasAny(item.tags, _selectedCustomTags)) {
      return false;
    }
    return true;
  }

  int get _activeFilterCount =>
      _selectedStores.length + _selectedAutoTags.length + _selectedCustomTags.length;

  void _clearFilters() {
    setState(() {
      _selectedStores.clear();
      _selectedAutoTags.clear();
      _selectedCustomTags.clear();
    });
  }

  /// Usuwa z wybranych filtrów pozycje, których nie ma już na liście produktów.
  void _pruneFilters() {
    final stores = _availableStores().toSet();
    _selectedStores.removeWhere((s) => !stores.contains(s));
    final auto = _availableAutoTags().map((t) => t.toLowerCase()).toSet();
    _selectedAutoTags.removeWhere((t) => !auto.contains(t.toLowerCase()));
    final custom = _availableCustomTags().map((t) => t.toLowerCase()).toSet();
    _selectedCustomTags.removeWhere((t) => !custom.contains(t.toLowerCase()));
  }

  Widget _buildFilterDrawer(int visibleCount) {
    final stores = _availableStores();
    final autoTags = _availableAutoTags();
    final customTags = _availableCustomTags();

    int countForStore(String store) =>
        _items.where((i) => i.stores.contains(store)).length;
    int countForAutoTag(String tag) => _items
        .where((i) => i.autoTags.any((t) => t.toLowerCase() == tag.toLowerCase()))
        .length;
    int countForCustomTag(String tag) => _items
        .where((i) => i.tags.any((t) => t.toLowerCase() == tag.toLowerCase()))
        .length;

    void toggleSelection(Set<String> target, String value) {
      HapticFeedback.selectionClick();
      setState(() {
        final exists = target.any((t) => t.toLowerCase() == value.toLowerCase());
        if (exists) {
          target.removeWhere((t) => t.toLowerCase() == value.toLowerCase());
        } else {
          target.add(value);
        }
      });
    }

    return Drawer(
      width: 320,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(left: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Gradientowy nagłówek panelu filtrów
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1D4ED8), Color(0xFF2563EB), Color(0xFF3B82F6)],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 10, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.tune_rounded,
                            color: Colors.white,
                            size: 19,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Filtry',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          transitionBuilder: (child, anim) => ScaleTransition(
                            scale: anim,
                            child: FadeTransition(opacity: anim, child: child),
                          ),
                          child: _activeFilterCount > 0
                              ? TextButton(
                                  key: const ValueKey('clear_btn'),
                                  onPressed: () {
                                    HapticFeedback.lightImpact();
                                    _clearFilters();
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    minimumSize: const Size(0, 32),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                  ),
                                  child: const Text(
                                    'Wyczyść',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                                  ),
                                )
                              : const SizedBox.shrink(key: ValueKey('no_clear')),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close_rounded, color: Colors.white),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.14),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Row(
                        key: ValueKey('$visibleCount-${_items.length}-$_activeFilterCount'),
                        children: [
                          Icon(
                            _activeFilterCount > 0
                                ? Icons.filter_alt_rounded
                                : Icons.inventory_2_outlined,
                            size: 14,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _activeFilterCount > 0
                                ? 'Pasuje $visibleCount z ${_items.length} produktów (aktywnych: $_activeFilterCount)'
                                : 'Wszystkie produkty na liście: ${_items.length}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Rozwijane karty kategorii filtrów
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
              children: [
                _FilterSectionCard(
                  title: 'Sklepy',
                  icon: Icons.storefront_rounded,
                  accent: const Color(0xFF16A34A),
                  values: stores,
                  selected: _selectedStores,
                  countFor: countForStore,
                  emptyText: 'Brak sklepów na liście.',
                  onToggle: (v) => toggleSelection(_selectedStores, v),
                ),
                const SizedBox(height: 12),
                _FilterSectionCard(
                  title: 'Tagi',
                  icon: Icons.auto_awesome_rounded,
                  accent: const Color(0xFF2563EB),
                  values: autoTags,
                  selected: _selectedAutoTags,
                  countFor: countForAutoTag,
                  emptyText: 'Brak tagów automatycznych.',
                  onToggle: (v) => toggleSelection(_selectedAutoTags, v),
                ),
                const SizedBox(height: 12),
                _FilterSectionCard(
                  title: 'Własne tagi',
                  icon: Icons.label_rounded,
                  accent: const Color(0xFF7E22CE),
                  prefix: '#',
                  values: customTags,
                  selected: _selectedCustomTags,
                  countFor: countForCustomTag,
                  emptyText: 'Brak własnych tagów – dodasz je na karcie produktu.',
                  onToggle: (v) => toggleSelection(_selectedCustomTags, v),
                ),
              ],
            ),
          ),

          // Dolny pasek akcji
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    Navigator.of(context).maybePop();
                  },
                  icon: const Icon(Icons.check_rounded, size: 18),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  label: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      'Pokaż produkty ($visibleCount z ${_items.length})',
                      key: ValueKey('cta_$visibleCount'),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Wołane z karty produktu po zmianie własnych tagów.
  Future<void> _onTagsChanged() async {
    if (mounted) setState(() {});
    await _saveTrackedItems();
  }

  List<String> _knownCustomTags() => _availableCustomTags();

  Future<void> _deleteItem(int index) async {
    setState(() {
      _items.removeAt(index);
    });
    await _saveTrackedItems();
  }

  @override
  Widget build(BuildContext context) {
    // Usuń z filtrów tagi/sklepy, których nie ma już na liście produktów.
    _pruneFilters();
    final visibleItems = _items.where(_matchesFilters).toList();
    final filtersActive = _activeFilterCount > 0;

    return PopScope(
      canPop: !_isEndDrawerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && (_scaffoldKey.currentState?.isEndDrawerOpen ?? false)) {
          _scaffoldKey.currentState?.closeEndDrawer();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        onEndDrawerChanged: (isOpen) {
          if (_isEndDrawerOpen != isOpen) {
            setState(() => _isEndDrawerOpen = isOpen);
          }
        },
        endDrawer: _buildFilterDrawer(visibleItems.length),
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
                    filtersActive
                        ? 'OBSERWOWANE PRODUKTY (${visibleItems.length} z ${_items.length})'
                        : 'OBSERWOWANE PRODUKTY (${_items.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  if (_items.isNotEmpty)
                    Tooltip(
                      message: 'Filtry',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _scaffoldKey.currentState?.openEndDrawer();
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          padding: EdgeInsets.symmetric(
                            horizontal: filtersActive ? 9 : 7,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: filtersActive
                                ? const Color(0xFF2563EB)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: filtersActive
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFFCBD5E1),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (filtersActive
                                        ? const Color(0xFF2563EB)
                                        : Colors.black)
                                    .withValues(alpha: filtersActive ? 0.22 : 0.04),
                                blurRadius: filtersActive ? 8 : 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.tune_rounded,
                                size: 16,
                                color: filtersActive
                                    ? Colors.white
                                    : const Color(0xFF475569),
                              ),
                              AnimatedSize(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOutCubic,
                                child: filtersActive
                                    ? Padding(
                                        padding: const EdgeInsets.only(left: 5),
                                        child: Text(
                                          '$_activeFilterCount',
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.white,
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
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
            else if (visibleItems.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
                child: Column(
                  children: [
                    const Text(
                      'Brak produktów pasujących do wybranych filtrów.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _clearFilters,
                      child: const Text('Wyczyść filtry'),
                    ),
                  ],
                ),
              )
            else
              ...List.generate(visibleItems.length, (vIdx) {
                final item = visibleItems[vIdx];
                final p = item.product;
                final best = item.bestOffer;
                final cheaperOther = item.cheaperInOtherStore;

                return TweenAnimationBuilder<double>(
                  key: ValueKey('prod_${p.url}_${vIdx}_$_activeFilterCount'),
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: Duration(milliseconds: 240 + (vIdx.clamp(0, 6) * 45)),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) => Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, (1 - t) * 14),
                      child: child,
                    ),
                  ),
                  child: Padding(
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
                                knownTags: _knownCustomTags,
                                onTagsChanged: _onTagsChanged,
                                onDelete: () => _deleteItem(_items.indexOf(item)),
                                onRescanWithAgent: () async {
                                  await _rescanWithAgent(_items.indexOf(item));
                                },
                              ),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
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
                                              headers: const {
                                                'User-Agent':
                                                    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36',
                                              },
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
                                            for (final t in item.tags)
                                              _Badge(
                                                text: '#$t',
                                                bg: const Color(0xFFF3E8FF),
                                                fg: const Color(0xFF7E22CE),
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
                                          'Wklejono z: ${p.store}',
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
                              if (cheaperOther) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDCFCE7),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.trending_down_rounded,
                                        size: 14,
                                        color: Color(0xFF15803D),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'Taniej w ${best.store}!',
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF15803D),
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '-${(p.currentPrice - best.price).toStringAsFixed(2)} zł',
                                        style: const TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF15803D),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
      ),
    );
  }
}

class ProductDetailScreen extends StatefulWidget {
  final TrackedItem item;
  final VoidCallback onDelete;
  final Future<void> Function() onRescanWithAgent;
  final List<String> Function() knownTags;
  final Future<void> Function() onTagsChanged;

  const ProductDetailScreen({
    super.key,
    required this.item,
    required this.onDelete,
    required this.onRescanWithAgent,
    required this.knownTags,
    required this.onTagsChanged,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  bool _isRescanning = false;
  final TextEditingController _tagController = TextEditingController();
  final FocusNode _tagFocusNode = FocusNode();
  bool _tagDropdownOpen = false;

  @override
  void initState() {
    super.initState();
    _tagFocusNode.addListener(() {
      if (mounted && _tagDropdownOpen != _tagFocusNode.hasFocus) {
        setState(() => _tagDropdownOpen = _tagFocusNode.hasFocus);
      }
    });
  }

  @override
  void dispose() {
    _tagFocusNode.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _addTag(String raw) async {
    final t = normalizeTagInput(raw);
    _tagController.clear();
    if (t.isEmpty) return;
    final tags = widget.item.tags;
    if (tags.any((e) => e.toLowerCase() == t.toLowerCase())) {
      setState(() {});
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => tags.add(t));
    await widget.onTagsChanged();
  }

  Future<void> _removeTag(String t) async {
    HapticFeedback.selectionClick();
    setState(() => widget.item.tags.removeWhere((e) => e == t));
    await widget.onTagsChanged();
  }

  Widget _buildTagsCard() {
    final tags = widget.item.tags;
    final current = tags.map((t) => t.toLowerCase()).toSet();
    final query = normalizeTagInput(_tagController.text);
    final queryLower = query.toLowerCase();

    final allAvailable = widget.knownTags()
        .where((t) => !current.contains(t.toLowerCase()))
        .toList();
    final filtered = queryLower.isEmpty
        ? allAvailable
        : allAvailable
            .where((t) => t.toLowerCase().contains(queryLower))
            .toList();

    final exactExists = queryLower.isNotEmpty &&
        (current.contains(queryLower) ||
            allAvailable.any((t) => t.toLowerCase() == queryLower));
    final showCreateOption = query.isNotEmpty && !exactExists;
    final showDropdown = _tagDropdownOpen && (filtered.isNotEmpty || showCreateOption);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '🏷️ TAGI PRODUKTU',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Color(0xFF64748B),
            ),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final t in tags)
                  InputChip(
                    label: Text(
                      '#$t',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF7E22CE),
                      ),
                    ),
                    backgroundColor: const Color(0xFFF3E8FF),
                    deleteIconColor: const Color(0xFF7E22CE),
                    side: BorderSide.none,
                    onDeleted: () => _removeTag(t),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          TapRegion(
            onTapOutside: (_) {
              if (_tagFocusNode.hasFocus) _tagFocusNode.unfocus();
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 200),
                  sizeCurve: Curves.easeOutCubic,
                  crossFadeState: showDropdown
                      ? CrossFadeState.showFirst
                      : CrossFadeState.showSecond,
                  secondChild: const SizedBox(width: double.infinity, height: 0),
                  firstChild: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    constraints: const BoxConstraints(maxHeight: 200),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.07),
                          blurRadius: 12,
                          offset: const Offset(0, -3),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      children: [
                        if (showCreateOption)
                          InkWell(
                            onTap: () async {
                              await _addTag(query);
                              _tagFocusNode.unfocus();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.add_circle_outline_rounded,
                                    size: 16,
                                    color: Color(0xFF2563EB),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Dodaj nowy tag „#$query”',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF2563EB),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        for (final t in filtered)
                          InkWell(
                            onTap: () => _addTag(t),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.label_outline_rounded,
                                    size: 16,
                                    color: Color(0xFF7E22CE),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '#$t',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF0F172A),
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.add_rounded,
                                    size: 16,
                                    color: Color(0xFF94A3B8),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                TextField(
                  controller: _tagController,
                  focusNode: _tagFocusNode,
                  textInputAction: TextInputAction.done,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (val) async {
                    await _addTag(val);
                    _tagFocusNode.unfocus();
                  },
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Nowy tag (np. Twarz, Prezent)...',
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.add_circle, color: Color(0xFF2563EB)),
                      onPressed: () async {
                        await _addTag(_tagController.text);
                        _tagFocusNode.unfocus();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
                      headers: const {
                        'User-Agent':
                            'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36',
                      },
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

          // Kafelki z informacjami (wyrównane na wysokość)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _MetaTile(
                    label: 'Najniższa z 30 dni',
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
          ),
          const SizedBox(height: 8),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
          ),

          const SizedBox(height: 12),

          // Tagi produktu (własne)
          _buildTagsCard(),

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
                  ? 'Agent odczytuje stronę w WebView...'
                  : 'Odczytaj ponownie przez Agenta',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),

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

class _FilterSectionCard extends StatefulWidget {
  final String title;
  final IconData icon;
  final Color accent;
  final String prefix;
  final List<String> values;
  final Set<String> selected;
  final int Function(String) countFor;
  final String emptyText;
  final ValueChanged<String> onToggle;

  const _FilterSectionCard({
    required this.title,
    required this.icon,
    required this.accent,
    this.prefix = '',
    required this.values,
    required this.selected,
    required this.countFor,
    required this.emptyText,
    required this.onToggle,
  });

  @override
  State<_FilterSectionCard> createState() => _FilterSectionCardState();
}

class _FilterSectionCardState extends State<_FilterSectionCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final activeCount = widget.selected.length;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: activeCount > 0
              ? widget.accent.withValues(alpha: 0.35)
              : const Color(0xFFE2E8F0),
        ),
        boxShadow: [
          BoxShadow(
            color: (activeCount > 0 ? widget.accent : Colors.black)
                .withValues(alpha: activeCount > 0 ? 0.08 : 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _expanded = !_expanded);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: widget.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(widget.icon, size: 16, color: widget.accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                    child: activeCount > 0
                        ? Container(
                            key: ValueKey('cnt_$activeCount'),
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: widget.accent,
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              '$activeCount',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('cnt_0')),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: widget.values.isEmpty
                  ? Text(
                      widget.emptyText,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF94A3B8),
                        height: 1.35,
                      ),
                    )
                  : Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final v in widget.values)
                          _AnimatedFilterChip(
                            label: '${widget.prefix}$v',
                            count: widget.countFor(v),
                            selected: widget.selected
                                .any((t) => t.toLowerCase() == v.toLowerCase()),
                            accent: widget.accent,
                            onTap: () => widget.onToggle(v),
                          ),
                      ],
                    ),
            ),
            secondChild: const SizedBox(width: double.infinity, height: 0),
            crossFadeState:
                _expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 240),
            sizeCurve: Curves.easeOutCubic,
          ),
        ],
      ),
    );
  }
}

class _AnimatedFilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _AnimatedFilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? accent : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected ? accent : const Color(0xFFE2E8F0),
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.28),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : const [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: selected
                  ? const Padding(
                      padding: EdgeInsets.only(right: 5),
                      child: Icon(Icons.check_rounded, size: 14, color: Colors.white),
                    )
                  : const SizedBox.shrink(),
            ),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? Colors.white : const Color(0xFF334155),
                ),
              ),
            ),
            const SizedBox(width: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.24)
                    : const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : const Color(0xFF64748B),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
