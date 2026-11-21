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

  static const Set<String> _storeNameTokens = {
    'rossmann', 'natura', 'drogerie natura', 'hebe', 'cocolita', 'ezebra',
    'notino', 'superpharm', 'super pharm', 'pachnij', 'melissa', 'apteka melissa',
    'sklep', 'produkt'
  };

  static const Set<String> _genericWords = {
    'krem', 'zel', 'plyn', 'serum', 'balsam', 'szampon', 'odzywka', 'maska',
    'tonik', 'olejek', 'pianka', 'emulsja', 'woda', 'perfumy', 'twarzy',
    'ciala', 'skory', 'wlosow', 'oczu', 'rak', 'dloni', 'stop', 'suchej',
    'normalnej', 'mieszanej', 'wrazliwej', 'tlustej', 'do', 'dla', 'ze',
    'bez', 'oraz', 'lub', 'pod', 'nad', 'przy', 'spf', 'uva', 'uvb',
    'ml', 'szt', 'g', 'kg', 'l', 'opakowanie', 'nowosc', 'promocja',
    'rossmann', 'natura', 'hebe', 'cocolita', 'ezebra', 'notino',
  };

  /// Kontrola poczytalności dla dopasowania po EAN: marka, pojemność oraz
  /// (gdy nie znamy prawdziwej marki) przynajmniej jedno słowo modelu.
  static bool _isNameCompatibleForEanMatch(ProductInfo base, ProductInfo cand) {
    final normBaseBrand = _normalizeText(base.brand);
    final normCandBrand = _normalizeText(cand.brand);
    final normCandFull = _normalizeText('${cand.brand} ${cand.fullName}');
    final candWords = normCandFull.split(' ').toSet();

    final isRealBrand =
        normBaseBrand.isNotEmpty && !_storeNameTokens.contains(normBaseBrand);
    if (isRealBrand) {
      final brandWords = normBaseBrand
          .split(' ')
          .where((w) => w.length >= 2 && !_storeNameTokens.contains(w))
          .toList();
      if (brandWords.isNotEmpty &&
          !brandWords.any((bw) => normCandFull.contains(bw) || normCandBrand.contains(bw))) {
        return false;
      }
    }

    final baseCap = _extractCapacity(base.fullName, base.unit);
    final candCap = _extractCapacity(cand.fullName, cand.unit);
    if (baseCap != null && candCap != null && baseCap != candCap) return false;

    if (!isRealBrand) {
      final modelWords = _normalizeText(base.fullName)
          .split(' ')
          .where((w) => w.length >= 3 && !_genericWords.contains(w))
          .toSet();
      if (modelWords.isNotEmpty &&
          !modelWords.any((w) => candWords.contains(w) || normCandFull.contains(w))) {
        return false;
      }
    }
    return true;
  }

  /**
   * Rygorystyczna weryfikacja, czy znaleziony w innym sklepie produkt (`candidate`)
   * to faktycznie ten sam produkt co `baseProduct` (chroni przed odwoływaniem się do innego produktu
   * z tej samej marki lub losowych produktów polecanych przez wyszukiwarkę sklepu).
   */
  static bool isSameProduct({
    required ProductInfo baseProduct,
    required ProductInfo candidate,
    String? searchedEan,
    String candidateHtml = '',
  }) {
    final candEan = candidate.ean;

    // 1. Jeśli szukaliśmy po konkretnym kodzie EAN-13:
    if (searchedEan != null && isValidEan13(searchedEan)) {
      var eanConfirmed = false;
      if (candEan != null && isValidEan13(candEan)) {
        // Jeśli kandydat ma zidentyfikowany EAN, musi być identyczny!
        if (searchedEan != candEan) return false;
        eanConfirmed = true;
      } else if (RegExp('(?<![0-9])$searchedEan(?![0-9])').hasMatch(candidateHtml)) {
        // Kandydat nie ma wprost przypisanego EAN, ale jego HTML zawiera szukany kod.
        eanConfirmed = true;
      }
      // Szukaliśmy po EAN i nie występuje on na stronie kandydata (np. losowy
      // "bestseller" z wyników wyszukiwania) -> odrzucamy.
      if (!eanConfirmed) return false;

      // Sam EAN NIE wystarcza: kod odczytany ze strony bywa błędny (np. EAN produktu
      // z karuzeli "Polecane" zamiast głównego produktu). Dlatego zgodny EAN musi
      // iść w parze z zgodną marką / pojemnością / nazwą.
      return _isNameCompatibleForEanMatch(baseProduct, candidate);
    }

    // 2. Jeśli nie mamy EAN lub sprawdzamy dopasowanie po nazwie:
    final normBaseBrand = _normalizeText(baseProduct.brand);
    final normCandBrand = _normalizeText(candidate.brand);
    final normCandFull = _normalizeText('${candidate.brand} ${candidate.fullName}');

    const storeNames = {
      'rossmann', 'natura', 'drogerie natura', 'hebe', 'cocolita', 'ezebra',
      'notino', 'superpharm', 'super pharm', 'pachnij', 'melissa', 'apteka melissa',
      'sklep', 'produkt'
    };

    // A) Weryfikacja marki:
    final isRealBrand = normBaseBrand.isNotEmpty && !storeNames.contains(normBaseBrand);
    if (isRealBrand) {
      final baseBrandWords = normBaseBrand
          .split(' ')
          .where((w) => w.length >= 2 && !storeNames.contains(w))
          .toList();

      if (baseBrandWords.isNotEmpty) {
        // Kandydat MUSI zawierać główne słowo marki w nazwie lub marce
        final brandMatches = baseBrandWords.where((bw) => normCandFull.contains(bw) || normCandBrand.contains(bw)).length;
        if (brandMatches == 0) {
          return false;
        }
      }
    }

    // B) Sprawdzamy pojemność (np. 50ml vs 400ml)
    final baseCap = _extractCapacity(baseProduct.fullName, baseProduct.unit);
    final candCap = _extractCapacity(candidate.fullName, candidate.unit);
    if (baseCap != null && candCap != null && baseCap != candCap) {
      return false;
    }

    // C) Słowa kluczowe MODELU / WARIANTU (z wykluczeniem marki i słów ogólnych!):
    const stopWords = {
      'krem', 'zel', 'plyn', 'serum', 'balsam', 'szampon', 'odzywka', 'maska',
      'tonik', 'olejek', 'pianka', 'emulsja', 'woda', 'perfumy', 'twarzy',
      'ciala', 'skory', 'wlosow', 'oczu', 'rak', 'dloni', 'stop', 'suchej',
      'normalnej', 'mieszanej', 'wrazliwej', 'tlustej', 'do', 'dla', 'ze',
      'bez', 'oraz', 'lub', 'pod', 'nad', 'przy', 'spf', 'uva', 'uvb',
      'ml', 'szt', 'g', 'kg', 'l', 'opakowanie', 'nowosc', 'promocja',
      'rossmann', 'natura', 'hebe', 'cocolita', 'ezebra', 'notino',
    };

    final brandWordsSet = normBaseBrand.split(' ').toSet();

    // Słowa modelu to słowa z nazwy bazowej, które NIE są marką ani słowami pospolitymi:
    final baseModelWords = _normalizeText(baseProduct.fullName)
        .split(' ')
        .where((w) => w.length >= 3 && !stopWords.contains(w) && !brandWordsSet.contains(w))
        .toSet();

    final candWords = normCandFull.split(' ').toSet();

    // Jeśli produkt bazowy ma unikalne słowa modelu (np. "relief", "rice", "probiotics"):
    if (baseModelWords.isNotEmpty) {
      int matchedModelWords = 0;
      for (final w in baseModelWords) {
        if (candWords.contains(w) || normCandFull.contains(w)) {
          matchedModelWords++;
        }
      }
      final ratio = matchedModelWords / baseModelWords.length;
      final minRequired = baseModelWords.length == 1 ? 1 : 2;
      if (matchedModelWords < minRequired || ratio < 0.60) {
        return false;
      }
    }

    // D) Sprawdzamy specyficzne numery w nazwie (np. "50", "30", "15", "01"):
    final baseNumbers = RegExp(r'\b\d+\b').allMatches(baseProduct.fullName).map((m) => m.group(0)!).toSet();
    final candNumbers = RegExp(r'\b\d+\b').allMatches(candidate.fullName).map((m) => m.group(0)!).toSet();
    if (baseNumbers.isNotEmpty && candNumbers.isNotEmpty) {
      final commonNumbers = baseNumbers.intersection(candNumbers);
      if (commonNumbers.isEmpty) {
        return false;
      }
    }

    return true;
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

  /// Wykrywa dokładną kategorię na podstawie nazwy produktu, URL i kategorii z JSON-LD,
  /// zamiast ślepo przypisywać kategorię sklepu (np. kawa z morele.net -> "Kawa i herbata", a nie "Elektronika").
  static String detectSmartCategory({
    required String fullName,
    required String url,
    required String storeFallbackCategory,
    String? rawLdCategory,
  }) {
    final text = _normalizeText('$fullName ${rawLdCategory ?? ''} ${Uri.decodeFull(url)}');

    bool hasAny(List<String> patterns) {
      for (final p in patterns) {
        if (RegExp(p, caseSensitive: false).hasMatch(text)) return true;
      }
      return false;
    }

    // 1. AGD / Elektronika (sprawdzane przed kawą, żeby "ekspres do kawy" lub "młynek do kawy" nie trafił do "Kawa i herbata")
    if (hasAny([
      r'\bekspres\b', r'\bmlynek\b', r'\bspieniacz\b', r'\bczajnik\b',
      r'\bsmartfon', r'\biphone\b', r'\bgalaxy\s*s\d', r'\blaptop', r'\bnotebook',
      r'\bmonitor\b', r'\bsluchawk', r'\bklawiatur', r'\bmyszk[ai]\b', r'\bprocesor\b',
      r'\bkarta\s*graficzn', r'\bdysk\s*ssd\b', r'\bpamiec\s*ram\b', r'\btablet\b',
      r'\bsmartwatch', r'\btelewizor', r'\bglosnik', r'\bpowerbank', r'\bladowark',
      r'\brouter\b', r'\bdrukark', r'\bkonsol[ae]\b', r'\bodkurzacz', r'\bairfryer',
      r'\bfrytkownic', r'\bsuszark[ai]\s*do\s*wlosow', r'\bprostownic',
      r'\bszczoteczk[ai]\s*(?:soniczn|elektryczn)', r'\bgolark', r'\bdepilator',
    ])) {
      return 'Elektronika';
    }

    // 2. Kawa i herbata
    if (hasAny([
      r'\bkaw[ayeu]\b', r'\bziarnist', r'\bmielon[ae]\b', r'\bespresso\b',
      r'\blavazza\b', r'\bjacobs\b', r'\btchibo\b', r'\bdallmayr\b', r'\bsegafredo\b',
      r'\bkimbo\b', r'\billy\b', r'\bnescafe\b', r'\bdolce\s*gusto\b', r'\bnespresso\b',
      r'\bherbat[ayeu]\b', r'\bmatch[ay]\b', r'\byerba\b', r'\brooibos\b',
    ])) {
      return 'Kawa i herbata';
    }

    // 3. Perfumy
    if (hasAny([
      r'\bwoda\s*perfumowan', r'\bwoda\s*toaletow', r'\bperfum[ay]?\b',
      r'\bedp\b', r'\bedt\b', r'\bmgielk[ai]\s*zapach',
    ])) {
      return 'Perfumy';
    }

    // 4. Suplementy i zdrowie
    if (hasAny([
      r'\bwitamin', r'\bmagnez', r'\bomega\s*3', r'\bkolagen', r'\bsuplement',
      r'\bprobiotyk', r'\belektrolit', r'\bkreatyn', r'\bbialk[oa]\b', r'\bwhey\b',
      r'\bashwagandh', r'\bcynk\b', r'\bzelazo\b', r'\bmelatonin', r'\btran\b',
      r'\bkapsulk[ai]\b', r'\btabletk[ai]\b',
    ])) {
      return 'Suplementy';
    }

    // 5. Kosmetyki i pielęgnacja
    if (hasAny([
      r'\bkrem\b', r'\bbalsam', r'\bserum\b', r'\btonik\b', r'\bszampon',
      r'\bodzywk[ai]\b', r'\bmask[ai]\b', r'\bmaseczk', r'\bpeeling', r'\bspf\s*\d',
      r'\bsamoopal', r'\bbrazujac', r'\bolejek\b', r'\bmicelarn', r'\bpiank[ai]\b',
      r'\bzel\s*(?:do\s*mycia|pod\s*prysznic|do\s*twarzy)', r'\bpomadk', r'\btusz\s*do\s*rzes',
      r'\bpodklad\b', r'\bpuder\b', r'\bkorektor\b', r'\bmakijaz', r'\blakier\s*do\s*paznokci',
      r'\bdezodorant', r'\bantyperspirant', r'\bpasta\s*do\s*zebow', r'\bkosmetyk',
    ])) {
      return 'Kosmetyki';
    }

    // 6. Spożywcze
    if (hasAny([
      r'\bczekolad', r'\bbaton\b', r'\borzech', r'\bmiod\b', r'\boliwa\b',
      r'\bolej\s*kokos', r'\bplatki\b', r'\bmakaron', r'\bsos\b', r'\bprzypraw',
      r'\bsyrop\b', r'\bsok\b', r'\bnapoj', r'\bzywnosc', r'\bspozywcz', r'\bslodycz',
      r'\bmaslo\s*orzechow', r'\bkrem\s*orzechow',
    ])) {
      return 'Spożywcze';
    }

    // 7. Chemia i dom
    if (hasAny([
      r'\bproszek\s*do\s*prania', r'\bkapsulk[ai]\s*do\s*prania', r'\bplyn\s*do\s*plukania',
      r'\bplyn\s*do\s*naczyn', r'\btabletk[ai]\s*do\s*zmywarki', r'\bodswiezacz',
      r'\bpapier\s*toaletow', r'\brecznik\s*papierow', r'\bswiec[ae]\b', r'\bdyfuzor',
      r'\bpatelni', r'\bgarnek\b', r'\bkubek\b', r'\btermos\b', r'\bposciel',
    ])) {
      return 'Chemia i dom';
    }

    // 8. Dla zwierząt
    if (hasAny([
      r'\bkarma\s*dla', r'\bprzysmak\s*dla', r'\bzwirek\b', r'\bdla\s*psa\b', r'\bdla\s*kota\b',
    ])) {
      return 'Dla zwierząt';
    }

    // 9. Dla dzieci
    if (hasAny([
      r'\bpieluch', r'\bpieluszk', r'\bpampers', r'\bmleko\s*modyfikowan',
      r'\bsmoczek', r'\bzabawk', r'\bklocki\b', r'\blego\b',
    ])) {
      return 'Dla dzieci';
    }

    // 10. Sport i turystyka
    if (hasAny([
      r'\brower\b', r'\bhantle\b', r'\bmata\s*do\s*cwiczen', r'\bnamiot\b',
      r'\bspiwor\b', r'\bplecak\b', r'\bbidon\b',
    ])) {
      return 'Sport';
    }

    // 11. Książki i gry
    if (hasAny([
      r'\bksiazk', r'\bebook\b', r'\baudiobook', r'\bwinyl\b', r'\bgra\s*planszow', r'\bpuzzle\b',
    ])) {
      return 'Książki i gry';
    }

    return storeFallbackCategory;
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
        final parsed = parseHtmlDocument(
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
      final wvJsonLdList = (wvData['jsonLdList'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList() ??
          const <String>[];
      final screenshotB64 = (wvData['screenshotBase64'] ?? '').toString();

      final domParsed = parseHtmlDocument(
        html: wvHtml,
        url: url,
        storeInfo: storeInfo,
        fallbackText: wvText,
        fallbackTitle: wvTitle,
        fallbackImage: wvOgImage,
        extraJsonLd: wvJsonLdList,
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
        final parsed = parseHtmlDocument(
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

  static double? _parsePrice(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final cleaned = value
        .toString()
        .replaceAll(',', '.')
        .replaceAll(RegExp(r'[^\d.]'), '');
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
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

ZASADY DOTYCZĄCE CEN:
- "currentPrice": DOKŁADNA aktualna cena zakupu produktu, jaką klient płaci dzisiaj.
  BARDZO WAŻNE: Jeśli produkt jest w promocji (widoczna niższa cena, przekreślona stara cena lub cena promocyjna/klubowa), wpisz tę NIŻSZĄ CENĘ ZAKUPU (np. 29.99).
  NIGDY nie wpisuj tu ceny jednostkowej (np. "49,44 zł /100ml", "cena za 100ml/1l/1kg"), rekomendowanej ceny dostawcy, progu darmowej dostawy (np. 199.00), kuponu powitalnego / rabatu za newsletter (np. 10.00 / 20.00) ani rat.
- "regularPrice": cena regularna / wyjściowa (przekreślona) przed rabatem. Jeśli produkt nie jest przeceniony, wpisz taką samą jak currentPrice.
- "lowestOmnibusPrice": najniższa cena z ostatnich 30 dni przed wprowadzeniem obniżki (dyrektywa Omnibus) jeśli jest podana na karcie produktu (często małym drukiem), w przeciwnym razie null.

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
      final price = _parsePrice(aiData['currentPrice']) ?? 0.0;

      if (price <= 0) return null;

      final regPrice = _parsePrice(aiData['regularPrice']) ?? price;
      final omnibus = _parsePrice(aiData['lowestOmnibusPrice']);

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

      final cleanFullName = fullName.replaceAll(RegExp(r'\s+'), ' ').trim();
      final smartCategory = detectSmartCategory(
        fullName: cleanFullName,
        url: url,
        storeFallbackCategory: storeInfo['category'] ?? 'Sklep',
      );

      return ProductInfo(
        store: storeInfo['name'] ?? 'Sklep',
        category: smartCategory,
        url: url,
        brand: brand.isEmpty ? (storeInfo['name'] ?? 'Sklep') : brand,
        title: title,
        fullName: cleanFullName,
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

  static ProductInfo? parseHtmlDocument({
    required String html,
    required String url,
    required Map<String, String> storeInfo,
    String fallbackText = '',
    String fallbackTitle = '',
    String fallbackImage = '',
    List<String> extraJsonLd = const [],
    required String extractionMethod,
    String? screenshotBase64,
  }) {
    if (html.isEmpty && fallbackText.isEmpty && extraJsonLd.isEmpty) return null;

    Map<String, dynamic>? jsonLdProduct;
    for (final rawLd in extraJsonLd) {
      try {
        final parsed = jsonDecode(rawLd.trim());
        final found = _findProductInJsonLd(parsed);
        if (found != null) {
          jsonLdProduct = found;
          break;
        }
      } catch (_) {}
    }

    if (jsonLdProduct == null && html.isNotEmpty) {
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
    final rawLdBrand = jsonLdProduct?['brand'];
    if (nextProduct?['brand'] != null) {
      brand = nextProduct!['brand'].toString();
    } else if (rawLdBrand is String) {
      brand = rawLdBrand;
    } else if (rawLdBrand is Map) {
      brand = (rawLdBrand['name'] ?? '').toString();
    } else if (rawLdBrand is List && rawLdBrand.isNotEmpty) {
      final first = rawLdBrand.first;
      if (first is Map) {
        brand = (first['name'] ?? '').toString();
      } else if (first != null) {
        brand = first.toString();
      }
    } else {
      brand = getMeta('product:brand') ?? getItemprop('brand') ?? '';
    }
    brand = brand.trim();

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

    // Hebe i część sklepów umieszcza typ produktu i pojemność w disambiguatingDescription
    // (np. name="Mokosh Pomarańcza z cynamonem", disambiguatingDescription="brązujący balsam do ciała i twarzy, 180 ml")
    final disamb = (jsonLdProduct?['disambiguatingDescription'] ?? '').toString().trim();
    if (disamb.isNotEmpty &&
        !rawTitle.toLowerCase().contains(disamb.toLowerCase())) {
      rawTitle = '$rawTitle $disamb';
    }

    // Usuń śmieciowe dopiski sklepów z tytułu (np. " | Drogeria Hebe.pl", " - Sklep Cocolita.pl")
    rawTitle = rawTitle
        .replaceAll(RegExp(r'\s*[|\-–]\s*(?:Drogeria|Sklep|Apteka)?\s*(?:Hebe|Rossmann|Natura|Cocolita|eZebra|Notino|Super-Pharm).*$', caseSensitive: false), '')
        .trim();

    var unit = (nextProduct?['unit'] ?? '').toString().trim();
    if (unit.isEmpty) {
      unit = _extractCapacity(rawTitle, '') ?? '';
    }
    String fullName = rawTitle;
    if (brand.isNotEmpty && !rawTitle.toLowerCase().startsWith(brand.toLowerCase())) {
      fullName = '$brand $rawTitle';
    }
    if (unit.isNotEmpty &&
        !fullName.toLowerCase().replaceAll(' ', '').contains(unit.toLowerCase().replaceAll(' ', ''))) {
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

    double? detectedCurrentPrice;
    double? detectedRegularPrice;
    double? detectedOmnibusPrice;

    // 1. Z Next.js (__NEXT_DATA__) np. Rossmann
    if (nextProduct != null) {
      final npPrice = _parsePrice(nextProduct['price']);
      final npOld = _parsePrice(nextProduct['oldPrice']);
      final npOmni = _parsePrice(nextProduct['lastLowestPriceV2']);

      if (npPrice != null && npPrice > 0) detectedCurrentPrice = npPrice;
      if (npOld != null && npOld > 0) detectedRegularPrice = npOld;
      if (npOmni != null && npOmni > 0) detectedOmnibusPrice = npOmni;
    }

    // 2. Z JSON-LD / schema.org offers & priceSpecification (obsługuje List oraz Map)
    void inspectPriceSpec(dynamic spec) {
      if (spec == null) return;
      if (spec is List) {
        for (final item in spec) {
          inspectPriceSpec(item);
        }
        return;
      }
      if (spec is Map) {
        final p = _parsePrice(spec['price']);
        if (p == null || p <= 0) return;
        final pType = (spec['priceType'] ?? '').toString().toLowerCase();

        if (pType.contains('strikethrough') || pType.contains('listprice') || pType.contains('regular') || pType.contains('original')) {
          detectedRegularPrice = p;
        } else if (pType.contains('saleprice') || pType.contains('special') || pType.contains('promo')) {
          detectedCurrentPrice = p;
        } else if (pType.contains('minimumadvertised') || pType.contains('lowest') || pType.contains('30day') || pType.contains('omnibus')) {
          detectedOmnibusPrice = p;
        }
      }
    }

    if (offer != null) {
      inspectPriceSpec(offer['priceSpecification']);

      final offerPrice = _parsePrice(offer['price']);
      final offerLow = _parsePrice(offer['lowPrice']);
      final offerHigh = _parsePrice(offer['highPrice']);

      if (offerLow != null && offerLow > 0) {
        detectedCurrentPrice ??= offerLow;
        if (offerHigh != null && offerHigh > offerLow) {
          detectedRegularPrice ??= offerHigh;
        } else if (offerPrice != null && offerPrice > offerLow) {
          detectedRegularPrice ??= offerPrice;
        }
      } else if (offerPrice != null && offerPrice > 0) {
        detectedCurrentPrice ??= offerPrice;
      }
    }

    // 3. Z meta tagów i Microdata
    final metaPriceStr = getMeta('product:price:amount') ??
        getMeta('og:price:amount') ??
        getItemprop('price');
    if (metaPriceStr != null) {
      final mp = double.tryParse(metaPriceStr.replaceAll(',', '.'));
      if (mp != null && mp > 0) {
        detectedCurrentPrice ??= mp;
      }
    }

    // 4. Z widocznego tekstu strony (odrzuca ceny jednostkowe /100ml, rekomendowane, progi dostawy i kupony)
    final currPre = detectedCurrentPrice;
    if ((currPre == null || currPre <= 0) && fallbackText.isNotEmpty) {
      final priceMatches = RegExp(r'(\d{1,5}[,.]\d{2})\s*(?:zł|PLN)', caseSensitive: false)
          .allMatches(fallbackText);
      final badBefore = RegExp(
        r'(?:jednostkow|rekomendowan|dostawc|dostaw|kupon|rabat|za\s*100|30\s*dni|omnibus|rat|newsletter)',
        caseSensitive: false,
      );
      final badAfter = RegExp(r'^\s*/\s*(?:100|1000|1)?\s*(?:ml|g|l|kg|szt)', caseSensitive: false);
      for (final m in priceMatches) {
        final lineStart = fallbackText.lastIndexOf('\n', m.start);
        final beforeStart = (lineStart >= 0 ? lineStart + 1 : 0).clamp(
          (m.start - 45).clamp(0, fallbackText.length),
          m.start,
        );
        final beforeCtx = fallbackText.substring(beforeStart, m.start);
        final lineEnd = fallbackText.indexOf('\n', m.end);
        final afterEnd = (lineEnd >= 0 ? lineEnd : fallbackText.length).clamp(
          m.end,
          (m.end + 20).clamp(0, fallbackText.length),
        );
        final afterCtx = fallbackText.substring(m.end, afterEnd);
        if (badBefore.hasMatch(beforeCtx) || badAfter.hasMatch(afterCtx)) {
          continue;
        }
        final p = double.tryParse(m.group(1)!.replaceAll(',', '.'));
        if (p != null && p > 0) {
          detectedCurrentPrice = p;
          break;
        }
      }
    }

    final currFinal = detectedCurrentPrice;
    if (currFinal == null || currFinal <= 0) return null;

    final double currentPrice = currFinal;
    final double regularPrice = (detectedRegularPrice != null && detectedRegularPrice! >= currentPrice)
        ? detectedRegularPrice!
        : currentPrice;

    // 5. Najniższa cena z 30 dni (Omnibus)
    double? lowestOmnibusPrice = detectedOmnibusPrice;
    if (lowestOmnibusPrice == null && fallbackText.isNotEmpty) {
      final omniMatch = RegExp(
        r'(?:najniższa\s*cena|30\s*dni|omnibus)[^0-9]{1,40}(\d{1,5}[,.]\d{2})\s*(?:zł|PLN)',
        caseSensitive: false,
      ).firstMatch(fallbackText);
      if (omniMatch != null) {
        lowestOmnibusPrice = double.tryParse(omniMatch.group(1)!.replaceAll(',', '.'));
      }
    }

    String? cleanImageUrl(dynamic raw) {
      if (raw == null) return null;
      String? u;
      if (raw is String) {
        u = raw.trim();
      } else if (raw is Map) {
        u = (raw['url'] ?? raw['contentUrl'] ?? raw['medium'] ?? raw['large'])?.toString().trim();
      } else if (raw is List && raw.isNotEmpty) {
        for (final item in raw) {
          final candidate = cleanImageUrl(item);
          if (candidate != null) return candidate;
        }
        return null;
      }
      if (u == null || u.isEmpty) return null;
      if (u.startsWith('//')) u = 'https:$u';
      if (!u.startsWith('http://') && !u.startsWith('https://')) return null;
      return u;
    }

    String? image;
    final pics = nextProduct?['pictures'] ?? nextProduct?['galleryItems'];
    if (pics is List && pics.isNotEmpty && pics.first is Map) {
      image = cleanImageUrl((pics.first as Map)['medium'] ?? (pics.first as Map)['large']);
    }
    image ??= cleanImageUrl(jsonLdProduct?['image']);
    image ??= cleanImageUrl(getMeta('og:image'));
    image ??= cleanImageUrl(getMeta('twitter:image'));
    image ??= cleanImageUrl(fallbackImage);
    if (image == null && html.isNotEmpty) {
      // Fallback dla Allegro CDN (a.allegroimg.com) i głównych zdjęć produktów
      final allegroImg = RegExp(
        r'https://a\.allegroimg\.com/(?:s\d+|original)/[a-zA-Z0-9/_.-]+',
        caseSensitive: false,
      ).firstMatch(html);
      if (allegroImg != null) {
        image = allegroImg.group(0);
      }
    }

    final smartCategory = detectSmartCategory(
      fullName: fullName,
      url: url,
      storeFallbackCategory: storeInfo['category'] ?? 'Sklep',
      rawLdCategory: jsonLdProduct?['category']?.toString(),
    );

    return ProductInfo(
      store: storeInfo['name'] ?? 'Sklep',
      category: smartCategory,
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

    List<Future<List<StoreOffer>>> buildTasks(String key, String? eanForSearch, bool withGemini) {
      return <Future<List<StoreOffer>>>[
        if (baseProduct.store != 'Rossmann')
          _searchRossmann(key, eanForSearch, baseProduct),
        if (baseProduct.store != 'Drogerie Natura')
          _searchNatura(key, eanForSearch, baseProduct),
        if (baseProduct.store != 'Pachnij.pl')
          _searchPachnij(key, eanForSearch, baseProduct),
        if (baseProduct.store != 'eZebra')
          _searchEzebra(key, eanForSearch, baseProduct),
        if (baseProduct.store != 'Cocolita')
          _searchCocolita(key, eanForSearch, baseProduct),
        if (baseProduct.store != 'Apteka Melissa')
          _searchMelissa(key, eanForSearch, baseProduct),
        if (withGemini && geminiApiKey.trim().isNotEmpty)
          _searchMultiStoresWithGeminiGrounding(
            apiKey: geminiApiKey.trim(),
            ean: validEan,
            baseProduct: baseProduct,
          ),
      ];
    }

    var results = await Future.wait(buildTasks(searchKey, validEan, true));

    // Jeśli wyszukiwanie po EAN nic nie dało (np. EAN odczytany ze strony był błędny
    // i został odrzucony przez kontrolę nazwy), próbujemy jeszcze raz po samej nazwie.
    final foundAny = results.any((l) => l.any((o) => o.price > 0));
    if (!foundAny && validEan != null && nameQuery.isNotEmpty) {
      results = await Future.wait(buildTasks(nameQuery, null, false));
    }

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
        final parsed = parseHtmlDocument(
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
        final parsed = parseHtmlDocument(
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
        final parsed = parseHtmlDocument(
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
        final parsed = parseHtmlDocument(
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
        final parsed = parseHtmlDocument(
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
        final parsed = parseHtmlDocument(
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

  /// Czy host URL pasuje do nazwy sklepu (dla znanych sklepów); dla nieznanych akceptujemy.
  static bool _urlMatchesStore(String url, String storeName) {
    final detected = detectStore(url)['name'] ?? '';
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    final want = _normalizeText(storeName).replaceAll(' ', '');
    final got = _normalizeText(detected).replaceAll(' ', '');
    final hostFlat = host.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (got.isNotEmpty && (got.contains(want) || want.contains(got))) return true;
    // Nazwa sklepu w hoście (np. "Cosibella" -> cosibella.pl)
    return want.length >= 4 && hostFlat.contains(want);
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
        final prodName = (item['productName'] ?? '').toString().trim();
        final price = _parsePrice(item['price']) ?? 0.0;
        if (store.isEmpty || prodName.isEmpty || price <= 0) continue;

        // Weryfikujemy czy zwrócona przez AI oferta na pewno dotyczy dokładnie tego samego produktu i marki!
        final candidateCheck = ProductInfo(
          store: store,
          category: baseProduct.category,
          url: '',
          brand: '', // Nie wpisujemy marki na sztywno, kandydat musi sam zawierać markę!
          title: prodName,
          fullName: prodName,
          unit: _extractCapacity(prodName, '') ?? '',
          currentPrice: price,
          regularPrice: price,
          isPromo: false,
          availability: '',
          checkedAt: '',
        );
        // Oferty z wyszukiwarki AI nie mają kodu EAN ani HTML, więc weryfikujemy je po nazwie.
        if (!isSameProduct(baseProduct: baseProduct, candidate: candidateCheck)) {
          continue;
        }

        final regPrice = _parsePrice(item['regularPrice']) ?? price;
        final rawUrl = (item['url'] ?? '').toString().trim();
        // Link musi prowadzić do domeny deklarowanego sklepu (AI potrafi podać link do innego sklepu/produktu).
        final isValidDirectUrl = rawUrl.startsWith('http') &&
            !rawUrl.contains('google.com/search') &&
            rawUrl.split('/').length > 3 &&
            _urlMatchesStore(rawUrl, store);

        final finalUrl = isValidDirectUrl
            ? rawUrl
            : 'https://www.google.com/search?q=${Uri.encodeComponent("${baseProduct.fullName} ${ean ?? ""} $store")}';

        foundOffers.add(
          StoreOffer(
            store: store,
            price: price,
            regularPrice: regPrice >= price ? regPrice : price,
            isPromo: regPrice > price,
            url: finalUrl,
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
