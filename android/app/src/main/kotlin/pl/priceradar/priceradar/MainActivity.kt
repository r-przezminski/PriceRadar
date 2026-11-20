package pl.priceradar.priceradar

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.View
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.regex.Pattern

class MainActivity : FlutterActivity() {
    private val CHANNEL = "pl.priceradar.app/native"
    private val WORK_NAME = "PriceRadarPeriodicCheck"
    private var notifCounter = 3001

    override fun onCreate(savedInstanceState: Bundle?) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                WebView.enableSlowWholeDocumentDraw()
            }
        } catch (_: Throwable) {}
        super.onCreate(savedInstanceState)
        try {
            createNotificationChannel()
        } catch (_: Throwable) {}
        try {
            requestNotificationPermissionIfNeeded()
        } catch (_: Throwable) {}
        try {
            scheduleBackgroundPriceWork()
        } catch (_: Throwable) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val prefs = getSharedPreferences(PriceCheckWorker.PREFS_NAME, Context.MODE_PRIVATE)
                when (call.method) {
                    "getTrackedJson" -> {
                        val json = prefs.getString(PriceCheckWorker.KEY_TRACKED_JSON, "") ?: ""
                        result.success(json)
                    }
                    "saveTrackedJson" -> {
                        val json = call.argument<String>("json") ?: "[]"
                        prefs.edit().putString(PriceCheckWorker.KEY_TRACKED_JSON, json).apply()
                        result.success(true)
                    }
                    "getAgentConfig" -> {
                        val apiKey = prefs.getString("gemini_api_key", "") ?: ""
                        val alwaysAgent = prefs.getBoolean("always_use_agent", false)
                        val obj = JSONObject().apply {
                            put("geminiApiKey", apiKey)
                            put("alwaysUseAgent", alwaysAgent)
                        }
                        result.success(obj.toString())
                    }
                    "saveAgentConfig" -> {
                        val apiKey = call.argument<String>("geminiApiKey") ?: ""
                        val alwaysAgent = call.argument<Boolean>("alwaysUseAgent") ?: false
                        prefs.edit()
                            .putString("gemini_api_key", apiKey.trim())
                            .putBoolean("always_use_agent", alwaysAgent)
                            .apply()
                        result.success(true)
                    }
                    "captureViaWebView" -> {
                        val url = call.argument<String>("url") ?: ""
                        if (url.isEmpty()) {
                            result.error("INVALID_URL", "Pusty adres URL", null)
                        } else {
                            OffscreenWebViewCapturer.captureAsync(
                                applicationContext,
                                url,
                                onSuccess = { payload -> result.success(payload) },
                                onError = { err -> result.error("WEBVIEW_ERROR", err, null) }
                            )
                        }
                    }
                    "sendNotification" -> {
                        val title = call.argument<String>("title") ?: "PriceRadar"
                        val message = call.argument<String>("message") ?: ""
                        PriceCheckWorker.sendPriceDropNotification(this, title, message, notifCounter++)
                        result.success(true)
                    }
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (!url.isNullOrEmpty()) {
                            try {
                                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                startActivity(intent)
                            } catch (_: Exception) {}
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun scheduleBackgroundPriceWork() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val request = PeriodicWorkRequestBuilder<PriceCheckWorker>(2, TimeUnit.HOURS)
            .setConstraints(constraints)
            .build()

        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                PriceCheckWorker.CHANNEL_ID,
                "Powiadomienia o spadku cen",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alerty o niższych cenach obserwowanych produktów"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    101
                )
            }
        }
    }
}

/**
 * Offscreen WebView Capturer - działa zarówno z otwartej aplikacji,
 * jak i w tle z WorkManagera podczas uśpienia telefonu (bez potrzeby otwartego okna Activity!).
 */
object OffscreenWebViewCapturer {
    @SuppressLint("SetJavaScriptEnabled")
    fun captureAsync(
        appContext: Context,
        targetUrl: String,
        onSuccess: (String) -> Unit,
        onError: (String) -> Unit
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        mainHandler.post {
            var completed = false
            var webView: WebView? = null

            fun cleanup() {
                try {
                    webView?.stopLoading()
                    webView?.destroy()
                } catch (_: Throwable) {}
                webView = null
            }

            fun finishOk(payload: String) {
                if (completed) return
                completed = true
                cleanup()
                onSuccess(payload)
            }

            fun finishErr(msg: String) {
                if (completed) return
                completed = true
                cleanup()
                onError(msg)
            }

            try {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        WebView.enableSlowWholeDocumentDraw()
                    }
                } catch (_: Throwable) {}

                val wv = WebView(appContext)
                webView = wv

                val width = 540
                val height = 1080
                wv.setLayerType(View.LAYER_TYPE_SOFTWARE, null)

                // Wymiarowanie offscreen w pamięci RAM (działa nawet przy wygaszonym ekranie!)
                val widthSpec = View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY)
                val heightSpec = View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY)
                wv.measure(widthSpec, heightSpec)
                wv.layout(0, 0, width, height)

                val cookieManager = CookieManager.getInstance()
                cookieManager.setAcceptCookie(true)
                cookieManager.setAcceptThirdPartyCookies(wv, true)

                wv.settings.apply {
                    javaScriptEnabled = true
                    domStorageEnabled = true
                    databaseEnabled = true
                    loadsImagesAutomatically = true
                    mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                    userAgentString =
                        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36"
                }

                var extractionScheduled = false

                fun performCaptureAndExtract() {
                    if (completed || extractionScheduled) return
                    extractionScheduled = true

                    // 1. Zamknij banery Cookies ORAZ rozwiń zakładki "Szczegóły / Specyfikacja / EAN"
                    val prepareDomJs = """
                        (function() {
                            try {
                                var cookieSelectors = [
                                    '#onetrust-accept-btn-handler',
                                    '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
                                    '[data-testid="cookie-accept"]',
                                    '.cookie-accept',
                                    '#didomi-notice-agree-button'
                                ];
                                for (var i = 0; i < cookieSelectors.length; i++) {
                                    var btn = document.querySelector(cookieSelectors[i]);
                                    if (btn) btn.click();
                                }
                                var buttons = document.querySelectorAll('button, a, [role="tab"], summary');
                                for (var j = 0; j < buttons.length; j++) {
                                    var txt = (buttons[j].innerText || '').toLowerCase().trim();
                                    if (txt === 'akceptuję' || txt === 'zaakceptuj wszystkie' || txt === 'zgadzam się' || txt === 'akceptuj wszystko') {
                                        buttons[j].click();
                                    }
                                    if (txt.includes('specyfikacja') || txt.includes('szczegóły produktu') || txt.includes('dane techniczne') || txt.includes('informacje o produkcie')) {
                                        try { buttons[j].click(); } catch(e) {}
                                    }
                                }
                            } catch(e) {}
                        })();
                    """.trimIndent()

                    wv.evaluateJavascript(prepareDomJs, null)

                    mainHandler.postDelayed({
                        if (completed) return@postDelayed
                        try {
                            wv.measure(widthSpec, heightSpec)
                            wv.layout(0, 0, width, height)

                            var screenshotB64 = ""
                            try {
                                val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                                val canvas = Canvas(bmp)
                                wv.draw(canvas)
                                val baos = ByteArrayOutputStream()
                                bmp.compress(Bitmap.CompressFormat.JPEG, 72, baos)
                                screenshotB64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
                                bmp.recycle()
                            } catch (_: Throwable) {}

                            val extractJs = """
                                (function() {
                                    var lds = [];
                                    var scripts = document.querySelectorAll('script[type="application/ld+json"]');
                                    for (var i = 0; i < scripts.length; i++) {
                                        lds.push(scripts[i].innerText || scripts[i].textContent || '');
                                    }
                                    var metaPrice = '';
                                    var mp = document.querySelector('meta[property="product:price:amount"], meta[property="og:price:amount"], [itemprop="price"]');
                                    if (mp) metaPrice = mp.getAttribute('content') || mp.innerText || '';
                                    var ogImg = '';
                                    var mi = document.querySelector('meta[property="og:image"]');
                                    if (mi) ogImg = mi.getAttribute('content') || '';
                                    var bodyText = document.body ? document.body.innerText.substring(0, 12000) : '';
                                    var fullHtml = document.documentElement ? document.documentElement.outerHTML.substring(0, 160000) : '';
                                    return JSON.stringify({
                                        title: document.title || '',
                                        url: location.href,
                                        metaPrice: metaPrice,
                                        ogImage: ogImg,
                                        jsonLdList: lds,
                                        innerText: bodyText,
                                        html: fullHtml
                                    });
                                })();
                            """.trimIndent()

                            wv.evaluateJavascript(extractJs) { rawEval ->
                                try {
                                    val unescaped = if (rawEval != null && rawEval.startsWith("\"") && rawEval.endsWith("\"")) {
                                        JSONTokener(rawEval).nextValue().toString()
                                    } else {
                                        rawEval ?: "{}"
                                    }
                                    val parsed = JSONObject(unescaped)
                                    parsed.put("screenshotBase64", screenshotB64)
                                    finishOk(parsed.toString())
                                } catch (_: Throwable) {
                                    val fallback = JSONObject().apply {
                                        put("title", wv.title ?: "")
                                        put("url", targetUrl)
                                        put("innerText", "")
                                        put("html", "")
                                        put("screenshotBase64", screenshotB64)
                                    }
                                    finishOk(fallback.toString())
                                }
                            }
                        } catch (e: Throwable) {
                            finishErr("Błąd zrzutu WebView: ${e.message}")
                        }
                    }, 1000)
                }

                wv.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                        return false
                    }

                    override fun onPageFinished(view: WebView?, url: String?) {
                        super.onPageFinished(view, url)
                        mainHandler.postDelayed({
                            performCaptureAndExtract()
                        }, 2400)
                    }
                }

                mainHandler.postDelayed({
                    if (!completed) {
                        performCaptureAndExtract()
                    }
                }, 12000)

                wv.loadUrl(targetUrl)
            } catch (e: Throwable) {
                finishErr("Nie udało się uruchomić offscreen WebView: ${e.message}")
            }
        }
    }

    /**
     * Synchroniczna wersja dla WorkManagera działającego w tle podczas uśpienia telefonu
     */
    fun captureBlocking(appContext: Context, targetUrl: String, timeoutSec: Long = 16): JSONObject? {
        val latch = CountDownLatch(1)
        var resultObj: JSONObject? = null
        captureAsync(
            appContext,
            targetUrl,
            onSuccess = { jsonStr ->
                try {
                    resultObj = JSONObject(jsonStr)
                } catch (_: Throwable) {}
                latch.countDown()
            },
            onError = {
                latch.countDown()
            }
        )
        try {
            latch.await(timeoutSec, TimeUnit.SECONDS)
        } catch (_: Throwable) {}
        return resultObj
    }
}

class PriceCheckWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    companion object {
        const val PREFS_NAME = "priceradar_prefs"
        const val KEY_TRACKED_JSON = "tracked_json"
        const val CHANNEL_ID = "priceradar_alerts"
        private const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36"

        fun sendPriceDropNotification(
            context: Context,
            title: String,
            message: String,
            notificationId: Int
        ) {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                    ?: return

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Powiadomienia o spadku cen",
                    NotificationManager.IMPORTANCE_HIGH
                )
                manager.createNotificationChannel(channel)
            }

            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(message)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)

            manager.notify(notificationId, builder.build())
        }
    }

    override fun doWork(): Result {
        val context = applicationContext
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val rawJson = prefs.getString(KEY_TRACKED_JSON, null)
        val geminiApiKey = prefs.getString("gemini_api_key", "") ?: ""
        val alwaysUseAgent = prefs.getBoolean("always_use_agent", false)

        if (rawJson.isNullOrBlank()) {
            return Result.success()
        }

        return try {
            val trackedItems = JSONArray(rawJson)
            var anyChanged = false

            for (i in 0 until trackedItems.length()) {
                val item = trackedItems.optJSONObject(i) ?: continue
                val product = item.optJSONObject("product") ?: continue
                val offers = item.optJSONArray("offers")

                var oldBest = product.optDouble("currentPrice", 0.0)
                if (offers != null && offers.length() > 0) {
                    val firstOffer = offers.optJSONObject(0)
                    if (firstOffer != null) {
                        oldBest = firstOffer.optDouble("price", oldBest)
                    }
                }

                var newBest = oldBest
                var bestStore = product.optString("store", "Sklep")

                if (offers != null && offers.length() > 0) {
                    for (j in 0 until offers.length()) {
                        val offer = offers.optJSONObject(j) ?: continue
                        val offerUrl = offer.optString("url", "")
                        if (offerUrl.isEmpty()) continue

                        val fetchedPrice = checkSingleUrlInBackground(context, offerUrl, geminiApiKey, alwaysUseAgent)
                        if (fetchedPrice > 0) {
                            offer.put("price", fetchedPrice)
                            if (offer.optBoolean("isOrigin", false)) {
                                product.put("currentPrice", fetchedPrice)
                            }
                            if (fetchedPrice < newBest || j == 0) {
                                newBest = fetchedPrice
                                bestStore = offer.optString("store", bestStore)
                            }
                            anyChanged = true
                        }
                    }

                    sortOffersByPrice(offers)
                    val cheapest = offers.optJSONObject(0)
                    if (cheapest != null) {
                        newBest = cheapest.optDouble("price", newBest)
                        bestStore = cheapest.optString("store", bestStore)
                    }
                } else {
                    val prodUrl = product.optString("url", "")
                    val fetchedPrice = checkSingleUrlInBackground(context, prodUrl, geminiApiKey, alwaysUseAgent)
                    if (fetchedPrice > 0) {
                        product.put("currentPrice", fetchedPrice)
                        newBest = fetchedPrice
                        anyChanged = true
                    }
                }

                val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
                sdf.timeZone = TimeZone.getTimeZone("UTC")
                product.put("checkedAt", sdf.format(Date()))

                if (newBest > 0 && oldBest > 0 && newBest < oldBest - 0.005) {
                    val fullName = product.optString("fullName", "Obserwowany produkt")
                    val msg = String.format(
                        Locale.forLanguageTag("pl-PL"),
                        "%s kosztuje teraz %.2f zł w %s (spadek z %.2f zł)!",
                        fullName, newBest, bestStore, oldBest
                    )
                    sendPriceDropNotification(context, "📉 Spadek ceny w $bestStore!", msg, 2000 + i)
                }
            }

            if (anyChanged) {
                prefs.edit().putString(KEY_TRACKED_JSON, trackedItems.toString()).apply()
            }

            Result.success()
        } catch (e: Exception) {
            Result.retry()
        }
    }

    /**
     * Sprawdza cenę w tle (podczas uśpienia telefonu):
     * 1. Najpierw próbuje szybkiego HTTP (jeśli !alwaysUseAgent)
     * 2. Jeśli HTTP zawiedzie lub włączony jest tryb Agenta -> uruchamia Offscreen WebView w RAM,
     *    robi zrzut ekranu (Screenshot) i odpytuje Gemini AI (lub wyciąga cenę z wyrenderowanego DOM)
     */
    private fun checkSingleUrlInBackground(
        context: Context,
        urlStr: String,
        geminiApiKey: String,
        alwaysUseAgent: Boolean
    ): Double {
        if (!alwaysUseAgent) {
            val fastPrice = fetchLivePriceHttp(urlStr)
            if (fastPrice > 0) return fastPrice
        }

        // Offscreen WebView + Screenshot (działa w uśpieniu telefonu bez Activity!)
        val wvObj = OffscreenWebViewCapturer.captureBlocking(context, urlStr) ?: return -1.0
        val html = wvObj.optString("html", "")
        val innerText = wvObj.optString("innerText", "")
        val screenshotB64 = wvObj.optString("screenshotBase64", "")

        if (geminiApiKey.isNotBlank()) {
            val aiPrice = askGeminiForPriceInBackground(geminiApiKey, urlStr, innerText, screenshotB64)
            if (aiPrice > 0) return aiPrice
        }

        val domPrice = extractPriceFromHtmlOrText(html, innerText)
        if (domPrice > 0) return domPrice

        return -1.0
    }

    private fun askGeminiForPriceInBackground(
        apiKey: String,
        urlStr: String,
        innerText: String,
        screenshotB64: String
    ): Double {
        var conn: HttpURLConnection? = null
        try {
            val endpoint = URL("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey")
            conn = (endpoint.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 20000
                readTimeout = 20000
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
            }

            val parts = JSONArray()
            val clippedText = if (innerText.length > 4000) innerText.substring(0, 4000) else innerText
            parts.put(JSONObject().put("text", "Odczytaj ze zrzutu ekranu i tekstu aktualną cenę produktu ($urlStr) w PLN i zwróć wyłącznie JSON: {\"currentPrice\": 0.00}\nTekst:\n$clippedText"))
            if (screenshotB64.isNotEmpty()) {
                val inlineData = JSONObject()
                    .put("mime_type", "image/jpeg")
                    .put("data", screenshotB64)
                parts.put(JSONObject().put("inline_data", inlineData))
            }

            val payload = JSONObject()
                .put("contents", JSONArray().put(JSONObject().put("parts", parts)))
                .put("generationConfig", JSONObject().put("temperature", 0.1).put("responseMimeType", "application/json"))

            OutputStreamWriter(conn.outputStream, StandardCharsets.UTF_8).use {
                it.write(payload.toString())
            }

            if (conn.responseCode == 200) {
                val respStr = BufferedReader(InputStreamReader(conn.inputStream, StandardCharsets.UTF_8)).use { it.readText() }
                val root = JSONObject(respStr)
                val textJson = root.optJSONArray("candidates")
                    ?.optJSONObject(0)
                    ?.optJSONObject("content")
                    ?.optJSONArray("parts")
                    ?.optJSONObject(0)
                    ?.optString("text", "") ?: ""
                if (textJson.isNotEmpty()) {
                    val priceObj = JSONObject(textJson)
                    val p = priceObj.optDouble("currentPrice", -1.0)
                    if (p > 0) return p
                }
            }
        } catch (_: Exception) {
        } finally {
            conn?.disconnect()
        }
        return -1.0
    }

    private fun sortOffersByPrice(offers: JSONArray) {
        try {
            for (i in 0 until offers.length()) {
                for (j in i + 1 until offers.length()) {
                    val a = offers.getJSONObject(i)
                    val b = offers.getJSONObject(j)
                    if (b.optDouble("price", Double.MAX_VALUE) < a.optDouble("price", Double.MAX_VALUE)) {
                        offers.put(i, b)
                        offers.put(j, a)
                    }
                }
            }
        } catch (_: Exception) {}
    }

    private fun fetchLivePriceHttp(urlStr: String): Double {
        var conn: HttpURLConnection? = null
        try {
            val url = URL(urlStr)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 12000
                readTimeout = 12000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", USER_AGENT)
                setRequestProperty("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
                setRequestProperty("Accept-Language", "pl-PL,pl;q=0.9")
            }

            val code = conn.responseCode
            if (code !in 200..399) return -1.0

            val html = BufferedReader(InputStreamReader(conn.inputStream, StandardCharsets.UTF_8)).use {
                it.readText()
            }
            return extractPriceFromHtmlOrText(html, "")
        } catch (_: Exception) {
        } finally {
            conn?.disconnect()
        }
        return -1.0
    }

    private fun extractPriceFromHtmlOrText(html: String, innerText: String): Double {
        val jsonPricePattern = Pattern.compile("\"price\"\\s*:\\s*\"?(\\d+(?:[.,]\\d{1,2})?)\"?")
        val m1 = jsonPricePattern.matcher(html)
        if (m1.find()) {
            val v = m1.group(1)?.replace(",", ".")?.toDoubleOrNull() ?: -1.0
            if (v > 0) return v
        }

        val metaPricePattern = Pattern.compile(
            "(?:product:price:amount|itemprop=[\"']price[\"'])[^>]*content=[\"'](\\d+(?:[.,]\\d{1,2})?)[\"']",
            Pattern.CASE_INSENSITIVE
        )
        val m2 = metaPricePattern.matcher(html)
        if (m2.find()) {
            val v = m2.group(1)?.replace(",", ".")?.toDoubleOrNull() ?: -1.0
            if (v > 0) return v
        }

        if (innerText.isNotEmpty()) {
            val textPricePattern = Pattern.compile("(\\d{1,5}[,.]\\d{2})\\s*(?:zł|PLN)")
            val m3 = textPricePattern.matcher(innerText)
            if (m3.find()) {
                val v = m3.group(1)?.replace(",", ".")?.toDoubleOrNull() ?: -1.0
                if (v > 0) return v
            }
        }
        return -1.0
    }
}
