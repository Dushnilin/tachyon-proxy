package org.tachyon.vpn

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/**
 * Экран сканирования QR-кода: живое превью Camera2 с автофокусом, фонариком,
 * двойным контуром распознавания (YUV ImageReader 1280x720 + TextureView Bitmap)
 * и выбором изображения с QR-кодом из галереи.
 */
class QrScannerActivity : Activity() {

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var previewRequestBuilder: CaptureRequest.Builder? = null
    private var imageReader: ImageReader? = null
    private var bgThread: HandlerThread? = null
    private var bgHandler: Handler? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var textureView: TextureView
    private var torchEnabled = false
    private val decoding = AtomicBoolean(false)
    private val finished = AtomicBoolean(false)
    private var lastTextureScanMs = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent?.getBooleanExtra(EXTRA_GALLERY_ONLY, false) == true) {
            openGalleryPicker()
            return
        }

        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor("#0B0B0D"))
        }

        textureView = TextureView(this)
        root.addView(
            textureView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // Видоискатель в стиле Morphe
        root.addView(
            ViewfinderOverlay(this),
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // Верхняя панель с заголовком, фонариком и кнопкой закрытия
        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(40, 84, 40, 28)
            setBackgroundColor(Color.parseColor("#990B0B0D"))
        }
        val title = TextView(this).apply {
            text = "Наведите камеру на QR-код"
            setTextColor(Color.parseColor("#F2F2F3"))
            textSize = 15f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val torchBtn = Button(this).apply {
            text = "Фонарик"
            setTextColor(Color.parseColor("#B9A8FF"))
            setBackgroundColor(Color.parseColor("#1E1E24"))
            setOnClickListener {
                torchEnabled = !torchEnabled
                applyTorchState()
                text = if (torchEnabled) "Фонарик: ВКЛ" else "Фонарик"
            }
        }
        val closeBtn = Button(this).apply {
            text = "Закрыть"
            setTextColor(Color.parseColor("#F2F2F3"))
            setBackgroundColor(Color.parseColor("#26262B"))
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { leftMargin = 16 }
            layoutParams = lp
            setOnClickListener {
                setResult(RESULT_CANCELED)
                finish()
            }
        }
        topBar.addView(title)
        topBar.addView(torchBtn)
        topBar.addView(closeBtn)
        root.addView(
            topBar,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            ),
        )

        // Нижняя кнопка выбора QR из галереи
        val bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(48, 32, 48, 96)
        }
        val galleryBtn = Button(this).apply {
            text = "Выбрать изображение с QR из галереи"
            setTextColor(Color.parseColor("#0B0B0D"))
            setBackgroundColor(Color.parseColor("#B9A8FF"))
            setPadding(48, 28, 48, 28)
            setOnClickListener { openGalleryPicker() }
        }
        bottomBar.addView(galleryBtn)
        root.addView(
            bottomBar,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM,
            ),
        )

        setContentView(root)

        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
        } else {
            setupCameraPreview()
        }
    }

    private fun applyTorchState() {
        val builder = previewRequestBuilder ?: return
        val session = captureSession ?: return
        try {
            builder.set(
                CaptureRequest.FLASH_MODE,
                if (torchEnabled) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF,
            )
            session.setRepeatingRequest(builder.build(), null, bgHandler)
        } catch (_: Throwable) {}
    }

    private fun openGalleryPicker() {
        val pick = Intent(Intent.ACTION_GET_CONTENT).apply {
            type = "image/*"
            addCategory(Intent.CATEGORY_OPENABLE)
        }
        startActivityForResult(Intent.createChooser(pick, "Выберите QR-код"), REQ_GALLERY)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CAMERA) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                setupCameraPreview()
            } else {
                Toast.makeText(this, "Доступ к камере не выдан — выберите QR из галереи", Toast.LENGTH_SHORT).show()
                openGalleryPicker()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_GALLERY) {
            val uri: Uri? = data?.data
            if (resultCode == RESULT_OK && uri != null) {
                decodeUri(uri)
            } else if (intent?.getBooleanExtra(EXTRA_GALLERY_ONLY, false) == true) {
                setResult(RESULT_CANCELED)
                finish()
            }
        }
    }

    private fun decodeUri(uri: Uri) {
        Thread {
            var decoded: String? = null
            try {
                contentResolver.openInputStream(uri)?.use { stream ->
                    val opts = BitmapFactory.Options().apply { inSampleSize = 1 }
                    val bmp = BitmapFactory.decodeStream(stream, null, opts)
                    if (bmp != null) {
                        decoded = QrDecoder.decode(bmp)
                        bmp.recycle()
                    }
                }
            } catch (e: Throwable) {
                Log.e(TAG, "decodeUri failed", e)
            }
            runOnUiThread {
                if (!decoded.isNullOrBlank()) {
                    deliverSuccess(decoded!!)
                } else {
                    Toast.makeText(this, "QR-код на изображении не найден", Toast.LENGTH_SHORT).show()
                    if (intent?.getBooleanExtra(EXTRA_GALLERY_ONLY, false) == true) {
                        setResult(RESULT_CANCELED)
                        finish()
                    }
                }
            }
        }.start()
    }

    private fun deliverSuccess(text: String) {
        if (!finished.compareAndSet(false, true)) return
        Log.i(TAG, "QR успешно распознан (${text.length} симв.)")
        runCatching {
            window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        }
        val out = Intent().putExtra(EXTRA_QR_RESULT, text)
        setResult(RESULT_OK, out)
        finish()
    }

    private fun setupCameraPreview() {
        startBgThread()
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(s: SurfaceTexture, w: Int, h: Int) {
                configureTransform(w, h)
                openCamera()
            }

            override fun onSurfaceTextureSizeChanged(s: SurfaceTexture, w: Int, h: Int) {
                configureTransform(w, h)
            }

            override fun onSurfaceTextureDestroyed(s: SurfaceTexture): Boolean = true

            override fun onSurfaceTextureUpdated(s: SurfaceTexture) {
                // Дополнительный контур: раз в 180 мс берём отрендеренный кадр прямо с TextureView,
                // если фоновый декодер свободен. Это гарантирует работу даже на устройствах с нестандартным YUV stride.
                val now = System.currentTimeMillis()
                if (now - lastTextureScanMs < 180 || finished.get()) return
                if (!decoding.compareAndSet(false, true)) return
                lastTextureScanMs = now

                val w = textureView.width
                val h = textureView.height
                if (w < 64 || h < 64) {
                    decoding.set(false)
                    return
                }
                val bmpW = if (w <= h) 720 else 1280
                val bmpH = if (w <= h) 1280 else 720
                val bmp = runCatching { textureView.getBitmap(bmpW, bmpH) }.getOrNull()
                if (bmp == null) {
                    decoding.set(false)
                    return
                }
                bgHandler?.post {
                    try {
                        val res = QrDecoder.decode(bmp)
                        if (!res.isNullOrBlank()) {
                            mainHandler.post { deliverSuccess(res) }
                        }
                    } catch (_: Throwable) {
                    } finally {
                        bmp.recycle()
                        decoding.set(false)
                    }
                }
            }
        }
        if (textureView.isAvailable) {
            configureTransform(textureView.width, textureView.height)
            openCamera()
        }
    }

    private fun configureTransform(viewWidth: Int, viewHeight: Int) {
        if (viewWidth <= 0 || viewHeight <= 0) return
        // Камера отдаёт поток 1280x720 (в портретной ориентации — 720x1280).
        // Масштабируем с сохранением пропорций (CenterCrop), чтобы QR-код не сплющивало!
        val previewW = 720f
        val previewH = 1280f
        val scaleX = viewWidth / previewW
        val scaleY = viewHeight / previewH
        val maxScale = max(scaleX, scaleY)
        val matrix = Matrix()
        matrix.setScale(maxScale / scaleX, maxScale / scaleY, viewWidth / 2f, viewHeight / 2f)
        textureView.setTransform(matrix)
    }

    private fun openCamera() {
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return
        val mgr = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val camId = mgr.cameraIdList.firstOrNull { id ->
            val chars = mgr.getCameraCharacteristics(id)
            chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: mgr.cameraIdList.firstOrNull() ?: return

        imageReader = ImageReader.newInstance(1280, 720, ImageFormat.YUV_420_888, 2).apply {
            setOnImageAvailableListener({ reader ->
                val img = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                if (finished.get() || !decoding.compareAndSet(false, true)) {
                    img.close()
                    return@setOnImageAvailableListener
                }
                try {
                    val plane = img.planes[0]
                    val buf = plane.buffer
                    val rowStride = plane.rowStride
                    val pixelStride = plane.pixelStride
                    val w = img.width
                    val h = img.height
                    val lum = ByteArray(w * h)
                    if (pixelStride == 1 && rowStride == w) {
                        buf.get(lum, 0, w * h)
                    } else {
                        val rowBuf = ByteArray(rowStride)
                        for (r in 0 until h) {
                            buf.position(r * rowStride)
                            val toRead = minOf(rowStride, buf.remaining())
                            buf.get(rowBuf, 0, toRead)
                            if (pixelStride == 1) {
                                System.arraycopy(rowBuf, 0, lum, r * w, w)
                            } else {
                                for (c in 0 until w) {
                                    val idx = c * pixelStride
                                    if (idx < toRead) {
                                        lum[r * w + c] = rowBuf[idx]
                                    }
                                }
                            }
                        }
                    }
                    val res = QrDecoder.decodeLuminance(lum, w, h)
                    if (!res.isNullOrBlank()) {
                        mainHandler.post { deliverSuccess(res) }
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "YUV decode error", e)
                } finally {
                    img.close()
                    decoding.set(false)
                }
            }, bgHandler)
        }

        try {
            mgr.openCamera(camId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    startPreviewSession(camera)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    cameraDevice = null
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    cameraDevice = null
                }
            }, bgHandler)
        } catch (e: Throwable) {
            Log.e(TAG, "openCamera failed", e)
        }
    }

    private fun startPreviewSession(camera: CameraDevice) {
        val st = textureView.surfaceTexture ?: return
        st.setDefaultBufferSize(1280, 720)
        val previewSurface = Surface(st)
        val readerSurface = imageReader?.surface

        try {
            val req = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(previewSurface)
                if (readerSurface != null) addTarget(readerSurface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            }
            previewRequestBuilder = req
            val targets = if (readerSurface != null) {
                listOf(previewSurface, readerSurface)
            } else {
                listOf(previewSurface)
            }
            @Suppress("DEPRECATION")
            camera.createCaptureSession(
                targets,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        try {
                            session.setRepeatingRequest(req.build(), null, bgHandler)
                        } catch (_: Throwable) {}
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        // Если двойной поток не поддерживается драйвером — запускаем только на TextureView
                        if (readerSurface != null) {
                            startSingleSurfaceSession(camera, previewSurface)
                        }
                    }
                },
                bgHandler,
            )
        } catch (_: Throwable) {}
    }

    private fun startSingleSurfaceSession(camera: CameraDevice, previewSurface: Surface) {
        try {
            val req = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(previewSurface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            }
            previewRequestBuilder = req
            @Suppress("DEPRECATION")
            camera.createCaptureSession(
                listOf(previewSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        runCatching { session.setRepeatingRequest(req.build(), null, bgHandler) }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) = Unit
                },
                bgHandler,
            )
        } catch (_: Throwable) {}
    }

    private fun startBgThread() {
        if (bgThread != null) return
        bgThread = HandlerThread("TachyonQrCamera").also {
            it.start()
            bgHandler = Handler(it.looper)
        }
    }

    private fun stopCamera() {
        try {
            captureSession?.close()
            captureSession = null
            cameraDevice?.close()
            cameraDevice = null
            imageReader?.close()
            imageReader = null
            bgThread?.quitSafely()
            bgThread = null
            bgHandler = null
        } catch (_: Throwable) {}
    }

    override fun onDestroy() {
        stopCamera()
        super.onDestroy()
    }

    private class ViewfinderOverlay(context: Context) : View(context) {
        private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#B9A8FF")
            style = Paint.Style.STROKE
            strokeWidth = 6f
        }

        private val scrimPaint = Paint().apply {
            color = Color.parseColor("#66000000")
            style = Paint.Style.FILL
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val side = (width.coerceAtMost(height) * 0.68f)
            val left = (width - side) / 2f
            val top = (height - side) / 2f
            val right = left + side
            val bottom = top + side

            // Затенение вокруг рамки видоискателя
            canvas.drawRect(0f, 0f, width.toFloat(), top, scrimPaint)
            canvas.drawRect(0f, bottom, width.toFloat(), height.toFloat(), scrimPaint)
            canvas.drawRect(0f, top, left, bottom, scrimPaint)
            canvas.drawRect(right, top, width.toFloat(), bottom, scrimPaint)

            val rect = RectF(left, top, right, bottom)
            canvas.drawRoundRect(rect, 36f, 36f, borderPaint)
        }
    }

    companion object {
        private const val TAG = "TachyonQr"
        const val EXTRA_GALLERY_ONLY = "org.tachyon.vpn.extra.GALLERY_ONLY"
        const val EXTRA_QR_RESULT = "org.tachyon.vpn.extra.QR_RESULT"
        private const val REQ_CAMERA = 5001
        private const val REQ_GALLERY = 5002
    }
}
