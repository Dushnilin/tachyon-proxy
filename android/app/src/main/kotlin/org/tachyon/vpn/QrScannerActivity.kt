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
import android.util.Size
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Экран сканирования QR-кода: живое превью Camera2 с видоискателем и выбор изображения из галереи.
 */
class QrScannerActivity : Activity() {

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var bgThread: HandlerThread? = null
    private var bgHandler: Handler? = null
    private lateinit var textureView: TextureView
    private val decoding = AtomicBoolean(false)
    private val finished = AtomicBoolean(false)

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

        // Верхняя панель с заголовком и кнопкой закрытия
        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(48, 84, 48, 32)
        }
        val title = TextView(this).apply {
            text = "Наведите камеру на QR-код подписки или сервера"
            setTextColor(Color.parseColor("#F2F2F3"))
            textSize = 15f
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val closeBtn = Button(this).apply {
            text = "Закрыть"
            setTextColor(Color.parseColor("#F2F2F3"))
            setBackgroundColor(Color.parseColor("#26262B"))
            setOnClickListener {
                setResult(RESULT_CANCELED)
                finish()
            }
        }
        topBar.addView(title)
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
            } catch (_: Throwable) {}
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
        val out = Intent().putExtra(EXTRA_QR_RESULT, text)
        setResult(RESULT_OK, out)
        finish()
    }

    private fun setupCameraPreview() {
        startBgThread()
        if (textureView.isAvailable) {
            openCamera()
        } else {
            textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(s: SurfaceTexture, w: Int, h: Int) = openCamera()
                override fun onSurfaceTextureSizeChanged(s: SurfaceTexture, w: Int, h: Int) = Unit
                override fun onSurfaceTextureDestroyed(s: SurfaceTexture): Boolean = true
                override fun onSurfaceTextureUpdated(s: SurfaceTexture) = Unit
            }
        }
    }

    private fun openCamera() {
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return
        val mgr = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val camId = mgr.cameraIdList.firstOrNull { id ->
            val chars = mgr.getCameraCharacteristics(id)
            chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: mgr.cameraIdList.firstOrNull() ?: return

        imageReader = ImageReader.newInstance(640, 480, ImageFormat.YUV_420_888, 2).apply {
            setOnImageAvailableListener({ reader ->
                val img = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                if (!decoding.compareAndSet(false, true)) {
                    img.close()
                    return@setOnImageAvailableListener
                }
                try {
                    val plane = img.planes[0]
                    val buf = plane.buffer
                    val rowStride = plane.rowStride
                    val w = img.width
                    val h = img.height
                    val lum = ByteArray(w * h)
                    if (rowStride == w) {
                        buf.get(lum, 0, w * h)
                    } else {
                        for (r in 0 until h) {
                            buf.position(r * rowStride)
                            buf.get(lum, r * w, w)
                        }
                    }
                    val res = QrDecoder.decodeLuminance(lum, w, h)
                    if (!res.isNullOrBlank()) {
                        runOnUiThread { deliverSuccess(res) }
                    }
                } catch (_: Throwable) {
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
        } catch (_: Throwable) {}
    }

    private fun startPreviewSession(camera: CameraDevice) {
        val st = textureView.surfaceTexture ?: return
        st.setDefaultBufferSize(1280, 720)
        val previewSurface = Surface(st)
        val readerSurface = imageReader?.surface ?: return

        try {
            val req = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(previewSurface)
                addTarget(readerSurface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            }
            @Suppress("DEPRECATION")
            camera.createCaptureSession(
                listOf(previewSurface, readerSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        try {
                            session.setRepeatingRequest(req.build(), null, bgHandler)
                        } catch (_: Throwable) {}
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

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val side = (width.coerceAtMost(height) * 0.66f)
            val left = (width - side) / 2f
            val top = (height - side) / 2f
            val rect = RectF(left, top, left + side, top + side)
            canvas.drawRoundRect(rect, 36f, 36f, borderPaint)
        }
    }

    companion object {
        const val EXTRA_GALLERY_ONLY = "org.tachyon.vpn.extra.GALLERY_ONLY"
        const val EXTRA_QR_RESULT = "org.tachyon.vpn.extra.QR_RESULT"
        private const val REQ_CAMERA = 5001
        private const val REQ_GALLERY = 5002
    }
}
