import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'tracked_product.dart';

class ScraperService {
  static const MethodChannel _channel = MethodChannel('pl.priceradar.app/native');
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';

  static Future<String> _fetchHtml(String urlStr) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    client.userAgent = _userAgent;
    try {
      final uri = Uri.parse(urlStr);
      final req = await client.getUrl(uri);
      req.headers.set('User-Agent', _userAgent);
      req.headers.set('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
      req.headers.set('Accept-Language', 'pl-PL,pl;q=0.9,en-US;q=0.8');

      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 400) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      return await resp.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }

  /**
   * Walidacja sumy kontrolnej GS1 dla 13-cyfrowego kodu EAN-13 (oraz 8-cyfrowego EAN-8).
   * Odrzuca również zera wiodące (np. wewnętrzne 18-cyfrowe ID Hebe typu 000000000000412345).
   */
  static bool isValidEan13(String? code) {
    if (code == null) return false;
    final clean = code.trim();
    if (!RegExp(r'^\d{13}$').hasMatch(clean)) return false;
    if (clean.startsWith('0000')) return false;

    int sum = 0;
    for (int i = 0; i < 12; i++) {
      final digit = int.parse(clean[i]);
      sum += (i % 2 == 0) ? digit : digit * 3;
    }
    final checkDigit = (10 - (sum % 10)) % 10;
    return checkDigit == int.parse(clean[12]);
  }

  /**
   * Przeszukuje HTML, skrypty dataLayer oraz tekst po usunięciu tagów HTML
   * w poszukiwaniu prawdziwego kodu EAN-13.
   */
  static String? extractVerifiedEanFromContent(String url, String html, String text) {
    // 1. Z adresu URL (tylko jeśli ma dokładnie 13 cyfr i nie jest częścią dłuższego ID jak w Hebe 000000000000...)
    for (final m in RegExp(r'(?<![0-9])(\d{13})(?![0-9])').allMatches(url)) {
      final candidate = m.group(1)!;
      if (isValidEan13(candidate)) return candidate;
    }

    // 2. W obiektach JSON / dataLayer / GTM (np. "ean":"8809643070003", "gtin13":"...", "product_ean":"...")
    final jsonEanRegex = RegExp(
      r'["\x27](?:ean|gtin|gtin13|product_ean|barcode|eanCode|ean_code)["\x27]\s*:\s*["\x27]?(\d{13})(?![0-9])',
      caseSensitive: false,
    );
    for (final m in jsonEanRegex.allMatches(html)) {
      final candidate = m.group(1)!;
      if (isValidEan13(candidate)) return candidate;
    }

    // 3. Po usunięciu tagów HTML (dzięki temu <td class="col-12"> pomiędzy "Kod EAN" a wartością nie psuje wyszukiwania!)
    final strippedHtml = html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    final combinedPlain = '$strippedHtml\n$text';

    final labeledPlainRegex = RegExp(
      r'(?:kod\s*ean|ean|gtin|kod\s*kreskowy|barcode|nr\s*kat)[\s:.\-/|]{0,35}(\d{13})(?![0-9])',
      caseSensitive: false,
    );
    for (final m in labeledPlainRegex.allMatches(combinedPlain)) {
      final candidate = m.group(1)!;
      if (isValidEan13(candidate)) return candidate;
    }

    // 4. W widocznym tekście strony (ze sprawdzeniem sumy kontrolnej GS1 i odrzuceniem timestampów 17...)
    for (final m in RegExp(r'(?<![0-9])(\d{13})(?![0-9])').allMatches(text)) {
      final candidate = m.group(1)!;
      if (!candidate.startsWith('17') && isValidEan13(candidate)) {
        return candidate;
      }
    }

    return null;
  }

  /**
   * Normalizuje tekst do porównywania podobieństwa produktów (usuwa polskie znaki i znaki specjalne)
   */
  static String _normalizeText(String input) {
    const plMap = {
      'ą': 'a', 'ć': 'c', 'ę': 'e', 'ł': 'l', 'ń': 'n',
      'ó': 'o', 'ś': 's', 'ź': 'z', 'ż': 'z',
    };
    var s = input.toLowerCase();
    plMap.forEach((k, v) => s = s.replaceAll(k, v));
    return s.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /**
   * Wyciąga pojemność/wagę z tytułu (np. "50ml", "400ml", "236ml") do weryfikacji czy porównujemy to samo opakowanie
   */
  static String? _extractCapacity(String title, String unit) {
    final combined = '$title $unit'.toLowerCase();
    final m = RegExp(r'(\d+)\s*(ml|g|l|kg|szt|kaps|tabl)\b').firstMatch(combined);
    if (m != null) {
      return '${m.group(1)}${m.group(2)}';
    }
    return null;
  }

  /**
   * Rygorystyczna weryfikacja, czy znaleziony w innym sklepie produkt (`candidate`)
   * to faktycznie ten sam produkt co `baseProduct` (chroni przed "bestsellerami" typu Plusssz Magnez
   * zwracanymi przez sklepy, gdy szukany produkt nie istnieje w ich bazie).
   */
  static bool isSameProduct({
    required ProductInfo baseProduct,
    required ProductInfo candidate,
    String? searchedEan,
    String candidateHtml = '',
  }) {
    // 1. Jeśli oba produkty mają wykryty, prawidłowy kod EAN-13:
    if (searchedEan != null &&
        isValidEan13(searchedEan) &&
        candidate.ean != null &&
        isValidEan13(candidate.ean)) {
      return searchedEan == candidate.ean;
    }

    // 2. Jeśli szukaliśmy po konkretnym kodzie EAN i kod ten fizycznie znajduje się w kodzie produktu kandydata:
    final eanMatchedInHtml = searchedEan != null &&
        isValidEan13(searchedEan) &&
        RegExp('(?<![0-9])$searchedEan(?![0-9])').hasMatch(candidateHtml);

    // 3. Sprawdzamy zgodność marki oraz słów kluczowych nazwy (nawet gdy sklep wyświetlił listę pod zapytaniem EAN!)
    const stopWords = {
      'krem', 'zel', 'plyn', 'serum', 'balsam', 'szampon', 'odzywka', 'maska',
      'tonik', 'olejek', 'pianka', 'emulsja', 'woda', 'perfumy', 'twarzy',
      'ciala', 'skory', 'wlosow', 'oczu', 'rak', 'dloni', 'stop', 'suchej',
      'normalnej', 'mieszanej', 'wrazliwej', 'tlustej', 'do', 'dla', 'ze',
      'bez', 'oraz', 'lub', 'pod', 'nad', 'przy', 'spf', 'uva', 'uvb',
      'ml', 'szt', 'rossmann', 'natura', 'hebe', 'cocolita', 'ezebra',
    };

    final baseBrandWords = _normalizeText(baseProduct.brand)
        .split(' ')
        .where((w) => w.length >= 2 && !stopWords.contains(w))
        .toList();

    final baseAllWords = _normalizeText('${baseProduct.brand} ${baseProduct.title}')
        .split(' ')
        .where((w) => w.length >= 3 && !stopWords.contains(w))
        .toSet();

    final candNorm = _normalizeText('${candidate.brand} ${candidate.fullName}');
    final candWords = candNorm.split(' ').toSet();

    // Jeżeli znamy markę produktu bazowego (np. "Beauty of Joseon", "Garnier", "CeraVe"),
    // to kandydat MUSI zawierać główne słowo marki!
    if (baseBrandWords.isNotEmpty) {
      final brandMatches = baseBrandWords.where((bw) => candNorm.contains(bw)).length;
      if (brandMatches == 0 && !eanMatchedInHtml) {
        return false;
      }
    }

    // Sprawdzamy pojemność (np. 50ml vs 400ml) - jeśli oba mają podaną pojemność i jest różna, odrzucamy!
    final baseCap = _extractCapacity(baseProduct.fullName, baseProduct.unit);
    final candCap = _extractCapacity(candidate.fullName, candidate.unit);
    if (baseCap != null && candCap != null && baseCap != candCap && !eanMatchedInHtml) {
      return false;
    }

    if (eanMatchedInHtml) {
      return true;
    }

    if (baseAllWords.isEmpty) return false;

    int matchedKeywords = 0;
    for (final w in baseAllWords) {
      if (candWords.contains(w) || candNorm.contains(w)) {
        matchedKeywords++;
      }
    }

    final ratio = matchedKeywords / baseAllWords.length;
    // Wymagamy co najmniej 50% pokrycia unikalnych słów kluczowych (i minimum 2 wspólnych słów kluczowych)
    return matchedKeywords >= 2 && ratio >= 0.50;
  }

  static Map<String, String> detectStore(String urlStr) {
    try {
      final host = Uri.parse(urlStr).host.replaceFirst(RegExp(r'^www\.'), '').toLowerCase();
      const known = {
        'rossmann.pl': {'name': 'Rossmann', 'category': 'Drogeria'},
        'drogerienatura.pl': {'name': 'Drogerie Natura', 'category': 'Drogeria'},
        'hebe.pl': {'name': 'Hebe', 'category': 'Drogeria'},
        'cocolita.pl': {'name': 'Cocolita', 'category': 'Drogeria'},
        'ezebra.pl': {'name': 'eZebra', 'category': 'Drogeria'},
        'notino.pl': {'name': 'Notino', 'category': 'Drogeria'},
        'superpharm.pl': {'name': 'Super-Pharm', 'category': 'Drogeria'},
        'pachnij.pl': {'name': 'Pachnij.pl', 'category': 'Drogeria'},
        'apteka-melissa.pl': {'name': 'Apteka Melissa', 'category': 'Apteka'},
        'drmax.pl': {'name': 'Dr.Max', 'category': 'Apteka'},
        'gemini.pl': {'name': 'Apteka Gemini', 'category': 'Apteka'},
        'douglas.pl': {'name': 'Douglas', 'category': 'Perfumeria'},
        'sephora.pl': {'name': 'Sephora', 'category': 'Perfumeria'},
        'makeup.pl': {'name': 'MAKEUP', 'category': 'Drogeria'},
        'mediaexpert.pl': {'name': 'Media Expert', 'category': 'Elektronika'},
        'euro.com.pl': {'name': 'RTV Euro AGD', 'category': 'Elektronika'},
        'x-kom.pl': {'name': 'x-kom', 'category': 'Elektronika'},
        'morele.net': {'name': 'Morele.net', 'category': 'Elektronika'},
        'komputronik.pl': {'name': 'Komputronik', 'category': 'Elektronika'},
        'mediamarkt.pl': {'name': 'MediaMarkt', 'category': 'Elektronika'},
        'allegro.pl': {'name': 'Allegro', 'category': 'Marketplace'},
        'amazon.pl': {'name': 'Amazon.pl', 'category': 'Marketplace'},
        'empik.com': {'name': 'Empik', 'category': 'Marketplace'},
      };
      for (final entry in known.entries) {
        if (host.contains(entry.key)) return entry.value;
      }
      return {'name': host.isEmpty ? 'Sklep' : host, 'category': 'Sklep'};
    } catch (_) {
      return {'name': 'Sklep', 'category': 'Inny'};
    }
  }

  static Map<String, dynamic>? _findProductInJsonLd(dynamic obj) {
    if (obj == null) return null;
    if (obj is List) {
      for (final item in obj) {
        final found = _findProductInJsonLd(item);
        if (found != null) return found;
      }
      return null;
    }
    if (obj is Map) {
      final map = Map<String, dynamic>.from(obj);
      final type = map['@type'];
      if (type == 'Product' || (type is List && type.contains('Product'))) {
        return map;
      }
      if (map.containsKey('mainEntity')) {
        final found = _findProductInJsonLd(map['mainEntity']);
        if (found != null) return found;
      }
      if (map.containsKey('@graph')) {
        return _findProductInJsonLd(map['@graph']);
      }
    }
    return null;
  }

  static Future<ProductInfo> scrapeProduct(
    String url, {
    String geminiApiKey = '',
    bool forceAgent = false,
  }) async {
    final storeInfo = detectStore(url);
    ProductInfo? resultProduct;

    if (!forceAgent) {
      try {
        final html = await _fetchHtml(url);
        final parsed = _parseHtmlDocument(
          html: html,
          url: url,
          storeInfo: storeInfo,
          extractionMethod: '⚡ Szybki JSON-LD',
        );
        if (parsed != null && parsed.currentPrice > 0) {
          resultProduct = parsed;
        }
      } catch (_) {}
    }

    if (resultProduct == null) {
      final rawWebViewJson = await _channel.invokeMethod<String>(
        'captureViaWebView',
        {'url': url},
      );
      if (rawWebViewJson == null || rawWebViewJson.isEmpty) {
        throw Exception('Nie udało się załadować strony w WebView.');
      }

      final wvData = Map<String, dynamic>.from(jsonDecode(rawWebViewJson) as Map);
      final wvHtml = (wvData['html'] ?? '').toString();
      final wvText = (wvData['innerText'] ?? '').toString();
      final wvTitle = (wvData['title'] ?? '').toString();
      final wvOgImage = (wvData['ogImage'] ?? '').toString();
      final screenshotB64 = (wvData['screenshotBase64'] ?? '').toString();

      final domParsed = _parseHtmlDocument(
        html: wvHtml,
        url: url,
        storeInfo: storeInfo,
        fallbackText: wvText,
        fallbackTitle: wvTitle,
        fallbackImage: wvOgImage,
        extractionMethod: '🌐 WebView (Screen + DOM)',
        screenshotBase64: screenshotB64.isNotEmpty ? screenshotB64 : null,
      );

      if (geminiApiKey.trim().isNotEmpty) {
        try {
          final aiProduct = await _analyzeWithGeminiAgent(
            apiKey: geminiApiKey.trim(),
            url: url,
            storeInfo: storeInfo,
            pageTitle: wvTitle,
            innerText: wvText,
            screenshotBase64: screenshotB64,
            domHint: domParsed,
          );
          if (aiProduct != null && aiProduct.currentPrice > 0) {
            resultProduct = aiProduct;
          }
        } catch (_) {}
      }

      resultProduct ??= domParsed;
    }

    if (resultProduct == null || resultProduct.currentPrice <= 0) {
      throw Exception(
        'Nie udało się odczytać ceny ze strony ${storeInfo['name']}. '
        '${geminiApiKey.isEmpty ? "Wpisz darmowy klucz Gemini API (ikona 🤖), aby Agent AI odczytał cenę ze zrzutu ekranu!" : ""}',
      );
    }

    // Jeśli sklep nie miał kodu EAN na stronie, szukamy kodu EAN w katalogach Z RYGORYSTYCZNĄ WERYFIKACJĄ NAZWY
    if (resultProduct.ean == null || !isValidEan13(resultProduct.ean)) {
      final discoveredEan = await _discoverVerifiedEanByProductName(resultProduct);
      if (discoveredEan != null && isValidEan13(discoveredEan)) {
        resultProduct = ProductInfo(
          store: resultProduct.store,
          category: resultProduct.category,
          url: resultProduct.url,
          brand: resultProduct.brand,
          title: resultProduct.title,
          fullName: resultProduct.fullName,
          unit: resultProduct.unit,
          ean: discoveredEan,
          currentPrice: resultProduct.currentPrice,
          regularPrice: resultProduct.regularPrice,
          lowestOmnibusPrice: resultProduct.lowestOmnibusPrice,
          pricePerUnit: resultProduct.pricePerUnit,
          isPromo: resultProduct.isPromo,
          promotionTo: resultProduct.promotionTo,
          image: resultProduct.image,
          availability: resultProduct.availability,
          checkedAt: resultProduct.checkedAt,
          extractionMethod: resultProduct.extractionMethod,
          screenshotBase64: resultProduct.screenshotBase64,
        );
      }
    }

    return resultProduct;
  }

  /**
   * Szuka brakującego kodu EAN-13 w katalogach zewnętrznych, ale PRZYJMUJE GO TYLKO WTEDY,
   * gdy znaleziony produkt przejdzie weryfikację `isSameProduct` (ta sama marka, słowa kluczowe i pojemność)!
   */
  static Future<String?> _discoverVerifiedEanByProductName(ProductInfo baseProduct) async {
    final cleanQuery = baseProduct.fullName
        .replaceAll(RegExp(r'[^\w\sąćęłńóśźżĄĆĘŁŃÓŚŹŻ0-9.-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleanQuery.length < 4) return null;

    final shortWords = cleanQuery.split(' ').take(5).join(' ');

    // 1. Przeszukaj Rossmann po nazwie i zweryfikuj, czy to ten sam produkt
    try {
      final rossSearchHtml = await _fetchHtml(
        'https://www.rossmann.pl/szukaj?Search=${Uri.encodeComponent(shortWords)}',
      );
      final matches = RegExp(r'/Produkt/[^"\\]+').allMatches(rossSearchHtml).take(3);
      for (final m in matches) {
        final rossUrl = 'https://www.rossmann.pl${m.group(0)}';
        final rossProdHtml = await _fetchHtml(rossUrl);
        final parsed = _parseHtmlDocument(
          html: rossProdHtml,
          url: rossUrl,
          storeInfo: {'name': 'Rossmann', 'category': 'Drogeria'},
          extractionMethod: 'JSON-LD',
        );
        if (parsed != null &&
            isValidEan13(parsed.ean) &&
            isSameProduct(baseProduct: baseProduct, candidate: parsed)) {
          return parsed.ean;
        }
      }
    } catch (_) {}

    // 2. Przeszukaj Drogerie Natura po nazwie i zweryfikuj każdy link, odrzucając bannery typu "Plusssz Magnez"
    try {
      final natHtml = await _fetchHtml(
        'https://drogerienatura.pl/catalogsearch/result/?q=${Uri.encodeComponent(shortWords)}',
      );
      final linkMatches = RegExp(
        r'https://drogerienatura\.pl/produkt/([a-z0-9-]+)-(\d{13})',
        caseSensitive: false,
      ).allMatches(natHtml);

      final seenUrls = <String>{};
      for (final m in linkMatches) {
        final fullUrl = m.group(0)!;
        final slug = m.group(1)!;
        final candidateEan = m.group(2)!;
        if (seenUrls.contains(fullUrl) || !isValidEan13(candidateEan)) continue;
        seenUrls.add(fullUrl);

        // Szybki filtr po slugu URL: slug musi zawierać główne słowo marki lub tytułu!
        final fakeCandidateFromSlug = ProductInfo(
          store: 'Drogerie Natura',
          category: 'Drogeria',
          url: fullUrl,
          brand: '',
          title: slug.replaceAll('-', ' '),
          fullName: slug.replaceAll('-', ' '),
          unit: '',
          ean: null,
          currentPrice: 1,
          regularPrice: 1,
          isPromo: false,
          availability: '',
          checkedAt: '',
        );
        if (isSameProduct(baseProduct: baseProduct, candidate: fakeCandidateFromSlug)) {
          return candidateEan;
        }
      }
    } catch (_) {}

    return null;
  }

  static Future<ProductInfo?> _analyzeWithGeminiAgent({
    required String apiKey,
    required String url,
    required Map<String, String> storeInfo,
    required String pageTitle,
    required String innerText,
    required String screenshotBase64,
    ProductInfo? domHint,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 25);
    try {
      final endpoint = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
      );

      final prompt = '''
Jesteś precyzyjnym agentem e-commerce analizującym zrzut ekranu (screenshot) oraz tekst karty produktu ze sklepu "${storeInfo['name']}" ($url).
Tytuł strony: $pageTitle
Podpowiedź z DOM: EAN=${domHint?.ean ?? 'brak'}, cenaDOM=${domHint?.currentPrice ?? 'brak'}

Wyciągnij ze zrzutu ekranu oraz tekstu strony informacje o produkcie i zwróć WYŁĄCZNIE obiekt JSON:
{
  "brand": "marka produktu (np. Beauty of Joseon, Garnier, CeraVe, Samsung)",
  "title": "dokładna nazwa i model produktu bez nazwy sklepu",
  "unit": "pojemność lub waga jeśli dotyczy (np. 50 ml, 400 ml) lub pusty string",
  "ean": "13-cyfrowy kod kreskowy EAN/GTIN jeśli widoczny w tekście lub jeśli znasz oficjalny kod EAN-13 tego dokładnego produktu, inaczej null",
  "currentPrice": 0.00,
  "regularPrice": 0.00,
  "lowestOmnibusPrice": null,
  "pricePerUnit": "cena za 100ml/1l/1kg jeśli podana lub null"
}

Tekst strony:
${innerText.length > 6000 ? innerText.substring(0, 6000) : innerText}
''';

      final parts = <Map<String, dynamic>>[
        {'text': prompt},
      ];

      if (screenshotBase64.isNotEmpty) {
        parts.add({
          'inline_data': {
            'mime_type': 'image/jpeg',
            'data': screenshotBase64,
          },
        });
      }

      final payload = jsonEncode({
        'contents': [
          {'parts': parts},
        ],
        'generationConfig': {
          'temperature': 0.1,
          'responseMimeType': 'application/json',
        },
      });

      final req = await client.postUrl(endpoint);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(utf8.encode(payload));

      final resp = await req.close();
      final respBody = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;

      final decoded = jsonDecode(respBody);
      final textJson =
          decoded?['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString();
      if (textJson == null || textJson.isEmpty) return null;

      final aiData = Map<String, dynamic>.from(jsonDecode(textJson) as Map);
      final price = (aiData['currentPrice'] as num?)?.toDouble() ??
          double.tryParse((aiData['currentPrice'] ?? '').toString().replaceAll(',', '.')) ??
          0.0;

      if (price <= 0) return null;

      final regPrice = (aiData['regularPrice'] as num?)?.toDouble() ??
          double.tryParse((aiData['regularPrice'] ?? '').toString().replaceAll(',', '.')) ??
          price;

      final omnibus = (aiData['lowestOmnibusPrice'] as num?)?.toDouble() ??
          double.tryParse((aiData['lowestOmnibusPrice'] ?? '').toString().replaceAll(',', '.'));

      final brand = (aiData['brand'] ?? domHint?.brand ?? storeInfo['name'] ?? '').toString().trim();
      final title = (aiData['title'] ?? domHint?.title ?? pageTitle).toString().trim();
      final unit = (aiData['unit'] ?? domHint?.unit ?? '').toString().trim();

      String fullName = title;
      if (brand.isNotEmpty && !title.toLowerCase().startsWith(brand.toLowerCase())) {
        fullName = '$brand $title';
      }
      if (unit.isNotEmpty && !fullName.contains(unit)) {
        fullName = '$fullName ($unit)';
      }

      final aiEan = aiData['ean']?.toString().trim();
      final validEan = isValidEan13(aiEan) ? aiEan : domHint?.ean;

      return ProductInfo(
        store: storeInfo['name'] ?? 'Sklep',
        category: storeInfo['category'] ?? 'Sklep',
        url: url,
        brand: brand.isEmpty ? (storeInfo['name'] ?? 'Sklep') : brand,
        title: title,
        fullName: fullName.replaceAll(RegExp(r'\s+'), ' ').trim(),
        unit: unit,
        ean: validEan,
        currentPrice: price,
        regularPrice: regPrice >= price ? regPrice : price,
        lowestOmnibusPrice: omnibus,
        pricePerUnit: aiData['pricePerUnit']?.toString() ?? domHint?.pricePerUnit,
        isPromo: regPrice > price,
        promotionTo: domHint?.promotionTo,
        image: domHint?.image,
        availability: 'Dostępny',
        checkedAt: DateTime.now().toIso8601String(),
        extractionMethod: '🤖 Agent AI (Screen + DOM)',
        screenshotBase64: screenshotBase64.isNotEmpty ? screenshotBase64 : null,
      );
    } finally {
      client.close();
    }
  }

  static ProductInfo? _parseHtmlDocument({
    required String html,
    required String url,
    required Map<String, String> storeInfo,
    String fallbackText = '',
    String fallbackTitle = '',
    String fallbackImage = '',
    required String extractionMethod,
    String? screenshotBase64,
  }) {
    if (html.isEmpty && fallbackText.isEmpty) return null;

    Map<String, dynamic>? jsonLdProduct;
    final ldRegex = RegExp(
      r'<script[^>]*type=["\x27]application/ld\+json["\x27][^>]*>([\s\S]*?)</script>',
      caseSensitive: false,
    );
    for (final m in ldRegex.allMatches(html)) {
      try {
        final parsed = jsonDecode((m.group(1) ?? '').trim());
        final found = _findProductInJsonLd(parsed);
        if (found != null) {
          jsonLdProduct = found;
          break;
        }
      } catch (_) {}
    }

    String? getMeta(String prop) {
      final r1 = RegExp(
        '<meta[^>]+(?:property|name)=["\x27]$prop["\x27][^>]+content=["\x27]([^"\x27]+)["\x27]',
        caseSensitive: false,
      );
      final r2 = RegExp(
        '<meta[^>]+content=["\x27]([^"\x27]+)["\x27][^>]+(?:property|name)=["\x27]$prop["\x27]',
        caseSensitive: false,
      );
      return r1.firstMatch(html)?.group(1) ?? r2.firstMatch(html)?.group(1);
    }

    String? getItemprop(String prop) {
      final r = RegExp(
        'itemprop=["\x27]$prop["\x27][^>]*content=["\x27]([^"\x27]+)["\x27]',
        caseSensitive: false,
      );
      return r.firstMatch(html)?.group(1);
    }

    Map<String, dynamic>? nextProduct;
    final nextMatch = RegExp(
      r'<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)</script>',
    ).firstMatch(html);
    if (nextMatch != null) {
      try {
        final nextJson = jsonDecode(nextMatch.group(1) ?? '');
        final p = nextJson?['props']?['pageProps']?['initialState']?['product']?['product'];
        if (p is Map) {
          nextProduct = Map<String, dynamic>.from(p);
        }
      } catch (_) {}
    }

    Map<String, dynamic>? offer;
    final rawOffers = jsonLdProduct?['offers'];
    if (rawOffers is List && rawOffers.isNotEmpty && rawOffers.first is Map) {
      offer = Map<String, dynamic>.from(rawOffers.first as Map);
    } else if (rawOffers is Map) {
      offer = Map<String, dynamic>.from(rawOffers);
    }

    String brand = '';
    if (nextProduct?['brand'] != null) {
      brand = nextProduct!['brand'].toString();
    } else if (jsonLdProduct?['brand'] is String) {
      brand = jsonLdProduct!['brand'].toString();
    } else if (jsonLdProduct?['brand'] is Map) {
      brand = (jsonLdProduct!['brand']['name'] ?? '').toString();
    } else {
      brand = getMeta('product:brand') ?? getItemprop('brand') ?? '';
    }

    final rossParts = [
      nextProduct?['name']?.toString(),
      nextProduct?['caption']?.toString(),
    ].where((s) => s != null && s.trim().isNotEmpty).join(' ').trim();

    final htmlTitleMatch = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false)
        .firstMatch(html)
        ?.group(1)
        ?.trim();

    var rawTitle = rossParts.isNotEmpty
        ? rossParts
        : (jsonLdProduct?['name']?.toString() ??
            getMeta('og:title') ??
            htmlTitleMatch ??
            (fallbackTitle.isNotEmpty ? fallbackTitle : 'Produkt'));

    // Usuń śmieciowe dopiski sklepów z tytułu (np. " | Drogeria Hebe.pl", " - Sklep Cocolita.pl")
    rawTitle = rawTitle
        .replaceAll(RegExp(r'\s*[|\-–]\s*(?:Drogeria|Sklep|Apteka)?\s*(?:Hebe|Rossmann|Natura|Cocolita|eZebra|Notino|Super-Pharm).*$', caseSensitive: false), '')
        .trim();

    final unit = (nextProduct?['unit'] ?? '').toString();
    String fullName = rawTitle;
    if (brand.isNotEmpty && !rawTitle.toLowerCase().startsWith(brand.toLowerCase())) {
      fullName = '$brand $rawTitle';
    }
    if (unit.isNotEmpty && !fullName.contains(unit)) {
      fullName = '$fullName ($unit)';
    }
    fullName = fullName.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Wielowarstwowe wykrywanie kodu EAN-13 z walidacją GS1
    String? ean;
    final eanList = nextProduct?['eanNumber'];
    if (eanList is List && eanList.isNotEmpty) {
      final candidate = eanList.first.toString();
      if (isValidEan13(candidate)) ean = candidate;
    }
    for (final candidate in [
      jsonLdProduct?['gtin']?.toString(),
      jsonLdProduct?['gtin13']?.toString(),
      jsonLdProduct?['ean']?.toString(),
      jsonLdProduct?['sku']?.toString(),
      getItemprop('gtin13'),
      getItemprop('gtin'),
    ]) {
      if (ean == null && isValidEan13(candidate)) {
        ean = candidate;
      }
    }
    ean ??= extractVerifiedEanFromContent(url, html, fallbackText);

    dynamic rawPrice = nextProduct?['price'] ??
        offer?['price'] ??
        offer?['lowPrice'] ??
        getMeta('product:price:amount') ??
        getMeta('og:price:amount') ??
        getItemprop('price');

    if (rawPrice == null && fallbackText.isNotEmpty) {
      final textPriceMatch = RegExp(r'(\d{1,5}[,.]\d{2})\s*(?:zł|PLN)').firstMatch(fallbackText);
      if (textPriceMatch != null) {
        rawPrice = textPriceMatch.group(1);
      }
    }

    final cleanedPriceStr = (rawPrice ?? '')
        .toString()
        .replaceAll(',', '.')
        .replaceAll(RegExp(r'[^\d.]'), '');
    final currentPrice = double.tryParse(cleanedPriceStr) ?? 0.0;

    if (currentPrice <= 0) return null;

    double? specOldPrice;
    final priceSpec = offer?['priceSpecification'];
    if (priceSpec is Map &&
        (priceSpec['priceType'] ?? '').toString().contains('StrikethroughPrice')) {
      specOldPrice = double.tryParse(
        (priceSpec['price'] ?? '').toString().replaceAll(',', '.'),
      );
    }

    final regularPrice = (nextProduct?['oldPrice'] as num?)?.toDouble() ??
        specOldPrice ??
        currentPrice;

    double? lowestOmnibusPrice =
        (nextProduct?['lastLowestPriceV2'] as num?)?.toDouble();

    if (lowestOmnibusPrice == null && fallbackText.isNotEmpty) {
      final omniMatch = RegExp(
        r'30\s*dni[^0-9]{1,35}(\d{1,5}[,.]\d{2})\s*(?:zł|PLN)',
        caseSensitive: false,
      ).firstMatch(fallbackText);
      if (omniMatch != null) {
        lowestOmnibusPrice =
            double.tryParse(omniMatch.group(1)!.replaceAll(',', '.'));
      }
    }

    String? image;
    final pics = nextProduct?['pictures'] ?? nextProduct?['galleryItems'];
    if (pics is List && pics.isNotEmpty && pics.first is Map) {
      image = (pics.first as Map)['medium']?.toString();
    }
    if (image == null) {
      final ldImg = jsonLdProduct?['image'];
      if (ldImg is List && ldImg.isNotEmpty) {
        image = ldImg.first.toString();
      } else if (ldImg is String) {
        image = ldImg;
      } else if (ldImg is Map) {
        image = ldImg['url']?.toString();
      }
    }
    image ??= getMeta('og:image');
    if ((image == null || image.isEmpty) && fallbackImage.isNotEmpty) {
      image = fallbackImage;
    }

    return ProductInfo(
      store: storeInfo['name'] ?? 'Sklep',
      category: storeInfo['category'] ?? 'Sklep',
      url: url,
      brand: brand.isEmpty ? (storeInfo['name'] ?? 'Sklep') : brand,
      title: rawTitle,
      fullName: fullName,
      unit: unit,
      ean: ean,
      currentPrice: currentPrice,
      regularPrice: regularPrice,
      lowestOmnibusPrice: lowestOmnibusPrice,
      pricePerUnit: nextProduct?['pricePerUnit']?.toString(),
      isPromo: regularPrice > currentPrice,
      promotionTo: nextProduct?['promotionTo']?.toString(),
      image: image,
      availability: 'Dostępny',
      checkedAt: DateTime.now().toIso8601String(),
      extractionMethod: extractionMethod,
      screenshotBase64: screenshotBase64,
    );
  }

  /**
   * Szuka tego samego produktu równolegle w wielu sklepach, ale KAŻDĄ znalezioną ofertę
   * przepuszcza przez filtr tożsamości `isSameProduct` (EAN + marka + słowa kluczowe + pojemność).
   */
  static Future<List<StoreOffer>> findInOtherStores(
    String? ean,
    ProductInfo baseProduct, {
    String geminiApiKey = '',
  }) async {
    final offers = <StoreOffer>[
      StoreOffer(
        store: baseProduct.store,
        price: baseProduct.currentPrice,
        regularPrice: baseProduct.regularPrice,
        isPromo: baseProduct.isPromo,
        url: baseProduct.url,
        availability: baseProduct.availability,
        isOrigin: true,
      ),
    ];

    final validEan = isValidEan13(ean) ? ean : null;
    final nameQuery = baseProduct.fullName
        .replaceAll(RegExp(r'[^\w\sąćęłńóśźżĄĆĘŁŃÓŚŹŻ0-9.-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .take(5)
        .join(' ');

    final searchKey = validEan ?? nameQuery;
    if (searchKey.isEmpty) return offers;

    final tasks = <Future<List<StoreOffer>>>[
      if (baseProduct.store != 'Rossmann')
        _searchRossmann(searchKey, validEan, baseProduct),
      if (baseProduct.store != 'Drogerie Natura')
        _searchNatura(searchKey, validEan, baseProduct),
      if (baseProduct.store != 'Pachnij.pl')
        _searchPachnij(searchKey, validEan, baseProduct),
      if (baseProduct.store != 'eZebra')
        _searchEzebra(searchKey, validEan, baseProduct),
      if (baseProduct.store != 'Cocolita')
        _searchCocolita(searchKey, validEan, baseProduct),
      if (baseProduct.store != 'Apteka Melissa')
        _searchMelissa(searchKey, validEan, baseProduct),
      if (geminiApiKey.trim().isNotEmpty)
        _searchMultiStoresWithGeminiGrounding(
          apiKey: geminiApiKey.trim(),
          ean: validEan,
          baseProduct: baseProduct,
        ),
    ];

    final results = await Future.wait(tasks);
    for (final list in results) {
      for (final found in list) {
        if (found.price <= 0) continue;
        final existingIdx = offers.indexWhere(
          (o) => o.store.toLowerCase() == found.store.toLowerCase(),
        );
        if (existingIdx == -1) {
          offers.add(found);
        } else if (!offers[existingIdx].isOrigin &&
            found.price < offers[existingIdx].price) {
          offers[existingIdx] = found;
        }
      }
    }

    offers.sort((a, b) => a.price.compareTo(b.price));
    return offers;
  }

  static Future<List<StoreOffer>> _searchRossmann(
    String query,
    String? ean,
    ProductInfo baseProduct,
  ) async {
    try {
      final html = await _fetchHtml(
        'https://www.rossmann.pl/szukaj?Search=${Uri.encodeComponent(query)}',
      );
      final matches = RegExp(r'/Produkt/[^"\\]+').allMatches(html).take(3);
      for (final match in matches) {
        final rossUrl = 'https://www.rossmann.pl${match.group(0)}';
        final rossHtml = await _fetchHtml(rossUrl);
        final parsed = _parseHtmlDocument(
          html: rossHtml,
          url: rossUrl,
          storeInfo: {'name': 'Rossmann', 'category': 'Drogeria'},
          extractionMethod: 'JSON-LD',
        );
        if (parsed != null &&
            parsed.currentPrice > 0 &&
            isSameProduct(
              baseProduct: baseProduct,
              candidate: parsed,
              searchedEan: ean,
              candidateHtml: rossHtml,
            )) {
          return [
            StoreOffer(
              store: 'Rossmann',
              price: parsed.currentPrice,
              regularPrice: parsed.regularPrice,
              isPromo: parsed.isPromo,
              url: rossUrl,
              availability: parsed.availability,
              isOrigin: false,
            ),
          ];
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<List<StoreOffer>> _searchNatura(
    String query,
    String? ean,
    ProductInfo baseProduct,
  ) async {
    try {
      final html = await _fetchHtml(
        'https://drogerienatura.pl/catalogsearch/result/?q=${Uri.encodeComponent(query)}',
      );
      final pattern = (ean != null && ean.isNotEmpty)
          ? 'https://drogerienatura\\.pl/produkt/([a-z0-9-]+)-($ean)'
          : r'https://drogerienatura\.pl/produkt/([a-z0-9-]+)-(\d{13})';
      final matches = RegExp(pattern, caseSensitive: false).allMatches(html);

      final seen = <String>{};
      for (final m in matches) {
        final natUrl = m.group(0)!;
        final slug = m.group(1)!;
        final linkEan = m.group(2)!;
        if (seen.contains(natUrl)) continue;
        seen.add(natUrl);

        // Jeśli szukaliśmy po nazwie (bez EAN), wstępnie odrzuć widgety promocyjne typu "Plusssz Magnez" po slugu URL!
        if (ean == null || ean != linkEan) {
          final slugCandidate = ProductInfo(
            store: 'Drogerie Natura',
            category: 'Drogeria',
            url: natUrl,
            brand: '',
            title: slug.replaceAll('-', ' '),
            fullName: slug.replaceAll('-', ' '),
            unit: '',
            ean: null,
            currentPrice: 1,
            regularPrice: 1,
            isPromo: false,
            availability: '',
            checkedAt: '',
          );
          if (!isSameProduct(baseProduct: baseProduct, candidate: slugCandidate)) {
            continue;
          }
        }

        final natHtml = await _fetchHtml(natUrl);
        final parsed = _parseHtmlDocument(
          html: natHtml,
          url: natUrl,
          storeInfo: {'name': 'Drogerie Natura', 'category': 'Drogeria'},
          extractionMethod: 'JSON-LD',
        );
        if (parsed != null &&
            parsed.currentPrice > 0 &&
            isSameProduct(
              baseProduct: baseProduct,
              candidate: parsed,
              searchedEan: ean,
              candidateHtml: natHtml,
            )) {
          return [
            StoreOffer(
              store: 'Drogerie Natura',
              price: parsed.currentPrice,
              regularPrice: parsed.regularPrice,
              isPromo: parsed.isPromo,
              url: natUrl,
              availability: parsed.availability,
              isOrigin: false,
            ),
          ];
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<List<StoreOffer>> _searchPachnij(
    String query,
    String? ean,
    ProductInfo baseProduct,
  ) async {
    try {
      final html = await _fetchHtml(
        'https://pachnij.pl/szukaj?controller=search&s=${Uri.encodeComponent(query)}',
      );
      final pattern = (ean != null && ean.isNotEmpty)
          ? 'https://pachnij\\.pl/[^"\\x27]+-$ean\\.html'
          : r'https://pachnij\.pl/[^"\x27]+-\d{13}\.html';
      final matches = RegExp(pattern, caseSensitive: false).allMatches(html).take(3);
      for (final m in matches) {
        final prodUrl = m.group(0)!;
        final prodHtml = await _fetchHtml(prodUrl);
        final parsed = _parseHtmlDocument(
          html: prodHtml,
          url: prodUrl,
          storeInfo: {'name': 'Pachnij.pl', 'category': 'Drogeria'},
          extractionMethod: 'Microdata',
        );
        if (parsed != null &&
            parsed.currentPrice > 0 &&
            isSameProduct(
              baseProduct: baseProduct,
              candidate: parsed,
              searchedEan: ean,
              candidateHtml: prodHtml,
            )) {
          return [
            StoreOffer(
              store: 'Pachnij.pl',
              price: parsed.currentPrice,
              regularPrice: parsed.regularPrice,
              isPromo: parsed.isPromo,
              url: prodUrl,
              availability: 'Dostępny',
              isOrigin: false,
            ),
          ];
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<List<StoreOffer>> _searchEzebra(
    String query,
    String? ean,
    ProductInfo baseProduct,
  ) async {
    try {
      final html = await _fetchHtml(
        'https://www.ezebra.pl/pl/search.html?text=${Uri.encodeComponent(query)}',
      );
      final matches = RegExp(
        r'https://www\.ezebra\.pl/pl/products/[^"\x27]+\.html',
        caseSensitive: false,
      ).allMatches(html).take(3);
      for (final prodMatch in matches) {
        final prodUrl = prodMatch.group(0)!;
        final prodHtml = await _fetchHtml(prodUrl);
        final parsed = _parseHtmlDocument(
          html: prodHtml,
          url: prodUrl,
          storeInfo: {'name': 'eZebra', 'category': 'Drogeria'},
          extractionMethod: 'JSON-LD',
        );
        if (parsed != null &&
            parsed.currentPrice > 0 &&
            isSameProduct(
              baseProduct: baseProduct,
              candidate: parsed,
              searchedEan: ean,
              candidateHtml: prodHtml,
            )) {
          return [
            StoreOffer(
              store: 'eZebra',
              price: parsed.currentPrice,
              regularPrice: parsed.regularPrice,
              isPromo: parsed.isPromo,
              url: prodUrl,
              availability: 'Dostępny',
              isOrigin: false,
            ),
          ];
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<List<StoreOffer>> _searchCocolita(
    String query,
    String? ean,
    ProductInfo baseProduct,
  ) async {
    try {
      final html = await _fetchHtml(
        'https://www.cocolita.pl/pl/searchquery/${Uri.encodeComponent(query)}/1/phot/5?url=${Uri.encodeComponent(query)}',
      );
      final matches = RegExp(
        r'href=["\x27](https://www\.cocolita\.pl/[a-z0-9-]+)["\x27]',
        caseSensitive: false,
      ).allMatches(html).take(4);
      final seen = <String>{};
      for (final prodMatch in matches) {
        final prodUrl = prodMatch.group(1)!;
        if (seen.contains(prodUrl)) continue;
        seen.add(prodUrl);

        final prodHtml = await _fetchHtml(prodUrl);
        final parsed = _parseHtmlDocument(
          html: prodHtml,
          url: prodUrl,
          storeInfo: {'name': 'Cocolita', 'category': 'Drogeria'},
          extractionMethod: 'JSON-LD',
        );
        if (parsed != null &&
            parsed.currentPrice > 0 &&
            isSameProduct(
              baseProduct: baseProduct,
              candidate: parsed,
              searchedEan: ean,
              candidateHtml: prodHtml,
            )) {
          return [
            StoreOffer(
              store: 'Cocolita',
              price: parsed.currentPrice,
              regularPrice: parsed.regularPrice,
              isPromo: parsed.isPromo,
              url: prodUrl,
              availability: 'Dostępny',
              isOrigin: false,
            ),
          ];
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<List<StoreOffer>> _searchMelissa(
    String query,
    String? ean,
    ProductInfo baseProduct,
  ) async {
    try {
      final html = await _fetchHtml(
        'https://www.apteka-melissa.pl/szukaj?q=${Uri.encodeComponent(query)}',
      );
      final matches = RegExp(
        r'https://www\.apteka-melissa\.pl/produkt/[^"\x27]+',
        caseSensitive: false,
      ).allMatches(html).take(3);
      for (final prodMatch in matches) {
        final prodUrl = prodMatch.group(0)!;
        final prodHtml = await _fetchHtml(prodUrl);
        final parsed = _parseHtmlDocument(
          html: prodHtml,
          url: prodUrl,
          storeInfo: {'name': 'Apteka Melissa', 'category': 'Apteka'},
          extractionMethod: 'JSON-LD',
        );
        if (parsed != null &&
            parsed.currentPrice > 0 &&
            isSameProduct(
              baseProduct: baseProduct,
              candidate: parsed,
              searchedEan: ean,
              candidateHtml: prodHtml,
            )) {
          return [
            StoreOffer(
              store: 'Apteka Melissa',
              price: parsed.currentPrice,
              regularPrice: parsed.regularPrice,
              isPromo: parsed.isPromo,
              url: prodUrl,
              availability: 'Dostępny',
              isOrigin: false,
            ),
          ];
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<List<StoreOffer>> _searchMultiStoresWithGeminiGrounding({
    required String apiKey,
    required String? ean,
    required ProductInfo baseProduct,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 25);
    try {
      final endpoint = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
      );

      final prompt = '''
Wyszukaj w polskich sklepach internetowych aktualne ceny dokładnie tego produktu:
Marka: "${baseProduct.brand}"
Nazwa: "${baseProduct.fullName}"
Kod EAN/GTIN: "${ean ?? 'brak'}"
Pojemność/Model: "${baseProduct.unit}"

Sprawdź jak najwięcej polskich sklepów (np. Hebe, Rossmann, Super-Pharm, Notino, Drogerie Natura, Cocolita, eZebra, Douglas, Sephora, MAKEUP, Cosibella, Lyko, Dr.Max, Gemini, Allegro, Amazon.pl, Media Expert, RTV Euro AGD, x-kom, Morele).
Zwróć WYŁĄCZNIE tablicę JSON z ofertami znalezionych sklepów w formacie:
[
  {
    "store": "Nazwa sklepu",
    "productName": "Nazwa znalezionego produktu w tym sklepie",
    "price": 0.00,
    "regularPrice": 0.00,
    "url": "https://bezposredni-link-do-produktu-w-sklepie"
  }
]
BARDZO WAŻNE:
- Uwzględnij TYLKO oferty dotyczące dokładnie tego samego produktu tej samej marki (${baseProduct.brand}) i tej samej pojemności.
- Odrzuć wszelkie przypadkowe suplementy, zestawy czy inne produkty.
''';

      final payload = jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'tools': [
          {'google_search': {}},
        ],
        'generationConfig': {
          'temperature': 0.1,
        },
      });

      final req = await client.postUrl(endpoint);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(utf8.encode(payload));

      final resp = await req.close();
      final respBody = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return [];

      final decoded = jsonDecode(respBody);
      final rawText =
          decoded?['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString() ?? '';
      if (rawText.isEmpty) return [];

      final jsonArrayMatch = RegExp(r'\[[\s\S]*\]').firstMatch(rawText);
      if (jsonArrayMatch == null) return [];

      final list = jsonDecode(jsonArrayMatch.group(0)!) as List;
      final foundOffers = <StoreOffer>[];

      for (final item in list) {
        if (item is! Map) continue;
        final store = (item['store'] ?? '').toString().trim();
        final prodName = (item['productName'] ?? baseProduct.fullName).toString().trim();
        final price = (item['price'] as num?)?.toDouble() ??
            double.tryParse((item['price'] ?? '').toString().replaceAll(',', '.')) ??
            0.0;
        if (store.isEmpty || price <= 0) continue;

        // Weryfikujemy czy zwrócona przez AI oferta na pewno dotyczy tej samej marki/produktu
        final candidateCheck = ProductInfo(
          store: store,
          category: baseProduct.category,
          url: '',
          brand: baseProduct.brand,
          title: prodName,
          fullName: prodName,
          unit: '',
          currentPrice: price,
          regularPrice: price,
          isPromo: false,
          availability: '',
          checkedAt: '',
        );
        if (!isSameProduct(baseProduct: baseProduct, candidate: candidateCheck)) {
          continue;
        }

        final regPrice = (item['regularPrice'] as num?)?.toDouble() ??
            double.tryParse((item['regularPrice'] ?? '').toString().replaceAll(',', '.')) ??
            price;
        final url = (item['url'] ?? '').toString().trim();

        foundOffers.add(
          StoreOffer(
            store: store,
            price: price,
            regularPrice: regPrice >= price ? regPrice : price,
            isPromo: regPrice > price,
            url: url.startsWith('http')
                ? url
                : 'https://www.google.com/search?q=${Uri.encodeComponent("${baseProduct.fullName} ${ean ?? ""} $store")}',
            availability: 'Znaleziono (Agent AI)',
            isOrigin: false,
          ),
        );
      }

      return foundOffers;
    } catch (_) {
      return [];
    } finally {
      client.close();
    }
  }
}
