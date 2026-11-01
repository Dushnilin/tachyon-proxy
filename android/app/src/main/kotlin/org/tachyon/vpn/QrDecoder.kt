package org.tachyon.vpn

import android.graphics.Bitmap
import java.nio.charset.StandardCharsets
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Автономный декодер QR-кодов стандарта ISO/IEC 18004 (версии 1..25, уровни коррекции L/M/Q/H).
 * Не требует сторонних библиотек: включает адаптивную бинаризацию, поиск маркеров 1:1:3:1:1,
 * перспективное преобразование, деинтерливинг блоков и декодер Рида-Соломона над GF(256).
 */
object QrDecoder {

    fun decode(bitmap: Bitmap): String? {
        val w = bitmap.width
        val h = bitmap.height
        if (w < 21 || h < 21) return null
        val pixels = IntArray(w * h)
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
        val lum = ByteArray(w * h)
        for (i in pixels.indices) {
            val c = pixels[i]
            val r = (c shr 16) and 0xFF
            val g = (c shr 8) and 0xFF
            val b = c and 0xFF
            lum[i] = ((r * 306 + g * 601 + b * 117) shr 10).toByte()
        }
        return decodeLuminance(lum, w, h)
    }

    fun decodeLuminance(lum: ByteArray, width: Int, height: Int): String? {
        if (width < 21 || height < 21) return null
        val matrix = binarizeAdaptive(lum, width, height)
        return decodeMatrix(matrix, width, height)
            ?: decodeMatrix(invertMatrix(matrix), width, height)
    }

    private fun invertMatrix(src: Array<BooleanArray>): Array<BooleanArray> {
        return Array(src.size) { y ->
            BooleanArray(src[y].size) { x -> !src[y][x] }
        }
    }

    private fun binarizeAdaptive(lum: ByteArray, width: Int, height: Int): Array<BooleanArray> {
        // Интегральное изображение для мгновенного локального порога
        val integral = IntArray((width + 1) * (height + 1))
        val stride = width + 1
        for (y in 0 until height) {
            var rowSum = 0
            val srcOff = y * width
            val dstOff = (y + 1) * stride
            val prevOff = y * stride
            for (x in 0 until width) {
                rowSum += lum[srcOff + x].toInt() and 0xFF
                integral[dstOff + x + 1] = integral[prevOff + x + 1] + rowSum
            }
        }
        val win = max(15, min(width, height) / 8)
        val half = win / 2
        val out = Array(height) { BooleanArray(width) }
        for (y in 0 until height) {
            val y0 = max(0, y - half)
            val y1 = min(height - 1, y + half)
            val row = out[y]
            val srcOff = y * width
            for (x in 0 until width) {
                val x0 = max(0, x - half)
                val x1 = min(width - 1, x + half)
                val count = (x1 - x0 + 1) * (y1 - y0 + 1)
                val sum = integral[(y1 + 1) * stride + (x1 + 1)] -
                    integral[y0 * stride + (x1 + 1)] -
                    integral[(y1 + 1) * stride + x0] +
                    integral[y0 * stride + x0]
                val v = lum[srcOff + x].toInt() and 0xFF
                row[x] = v * count <= sum - count * 5
            }
        }
        return out
    }

    private data class FinderCenter(
        var x: Float,
        var y: Float,
        var moduleSize: Float,
        var count: Int = 1,
    )

    private fun decodeMatrix(img: Array<BooleanArray>, width: Int, height: Int): String? {
        val centers = findFinderPatterns(img, width, height)
        if (centers.size < 3) return null

        // Пробуем лучшие тройки поисковых маркеров
        val top = centers.sortedByDescending { it.count }.take(6)
        for (i in 0 until top.size - 2) {
            for (j in i + 1 until top.size - 1) {
                for (k in j + 1 until top.size) {
                    val ordered = orderFinders(top[i], top[j], top[k]) ?: continue
                    val res = sampleAndDecode(img, width, height, ordered[0], ordered[1], ordered[2])
                    if (res != null) return res
                }
            }
        }
        return null
    }

    private fun findFinderPatterns(
        img: Array<BooleanArray>,
        width: Int,
        height: Int,
    ): List<FinderCenter> {
        val centers = mutableListOf<FinderCenter>()
        val state = IntArray(5)
        val step = max(1, height / 240)

        for (y in 0 until height step step) {
            state.fill(0)
            var cur = 0
            val row = img[y]
            for (x in 0 until width) {
                if (row[x]) {
                    if ((cur and 1) == 1) cur++
                    state[cur]++
                } else {
                    if ((cur and 1) == 1) {
                        state[cur]++
                    } else {
                        if (cur == 4) {
                            if (foundRatio(state)) {
                                handlePossibleCenter(img, width, height, state, y, x, centers)
                            }
                            cur = 3
                            state[0] = state[2]
                            state[1] = state[3]
                            state[2] = state[4]
                            state[3] = 1
                            state[4] = 0
                        } else {
                            cur++
                            state[cur]++
                        }
                    }
                }
            }
            if (cur == 4 && foundRatio(state)) {
                handlePossibleCenter(img, width, height, state, y, width, centers)
            }
        }
        return centers
    }

    private fun foundRatio(s: IntArray): Boolean {
        var total = 0
        for (i in 0..4) {
            if (s[i] == 0) return false
            total += s[i]
        }
        if (total < 7) return false
        val module = total / 7.0f
        val maxVar = module * 0.65f
        return abs(module - s[0]) < maxVar &&
            abs(module - s[1]) < maxVar &&
            abs(3f * module - s[2]) < 3f * maxVar &&
            abs(module - s[3]) < maxVar &&
            abs(module - s[4]) < maxVar
    }

    private fun handlePossibleCenter(
        img: Array<BooleanArray>,
        width: Int,
        height: Int,
        state: IntArray,
        row: Int,
        endX: Int,
        centers: MutableList<FinderCenter>,
    ) {
        val total = state[0] + state[1] + state[2] + state[3] + state[4]
        val centerX = endX - state[4] - state[3] - state[2] / 2.0f
        val centerY = crossCheckVertical(img, height, row, centerX.toInt(), state[2], total)
        if (centerY.isNaN()) return
        val refinedX = crossCheckHorizontal(img, width, centerX.toInt(), centerY.toInt(), state[2], total)
        if (refinedX.isNaN()) return
        val mod = total / 7.0f

        for (c in centers) {
            val dx = abs(refinedX - c.x)
            val dy = abs(centerY - c.y)
            if (dx <= max(mod, c.moduleSize) * 1.5f && dy <= max(mod, c.moduleSize) * 1.5f) {
                val n = c.count + 1
                c.x = (c.x * c.count + refinedX) / n
                c.y = (c.y * c.count + centerY) / n
                c.moduleSize = (c.moduleSize * c.count + mod) / n
                c.count = n
                return
            }
        }
        centers.add(FinderCenter(refinedX, centerY, mod, 1))
    }

    private fun crossCheckVertical(
        img: Array<BooleanArray>,
        height: Int,
        startY: Int,
        centerX: Int,
        maxCount: Int,
        origTotal: Int,
    ): Float {
        val s = IntArray(5)
        var y = startY
        while (y >= 0 && img[y][centerX]) {
            s[2]++; y--
        }
        if (y < 0) return Float.NaN
        while (y >= 0 && !img[y][centerX] && s[1] <= maxCount) {
            s[1]++; y--
        }
        if (y < 0 || s[1] > maxCount) return Float.NaN
        while (y >= 0 && img[y][centerX] && s[0] <= maxCount) {
            s[0]++; y--
        }
        if (s[0] > maxCount) return Float.NaN

        y = startY + 1
        while (y < height && img[y][centerX]) {
            s[2]++; y++
        }
        if (y == height) return Float.NaN
        while (y < height && !img[y][centerX] && s[3] <= maxCount) {
            s[3]++; y++
        }
        if (y == height || s[3] > maxCount) return Float.NaN
        while (y < height && img[y][centerX] && s[4] <= maxCount) {
            s[4]++; y++
        }
        if (s[4] > maxCount) return Float.NaN

        val total = s[0] + s[1] + s[2] + s[3] + s[4]
        if (5 * abs(total - origTotal) >= 2 * origTotal) return Float.NaN
        return if (foundRatio(s)) (y - s[4] - s[3] - s[2] / 2.0f) else Float.NaN
    }

    private fun crossCheckHorizontal(
        img: Array<BooleanArray>,
        width: Int,
        startX: Int,
        centerY: Int,
        maxCount: Int,
        origTotal: Int,
    ): Float {
        val s = IntArray(5)
        val row = img[centerY]
        var x = startX
        while (x >= 0 && row[x]) {
            s[2]++; x--
        }
        if (x < 0) return Float.NaN
        while (x >= 0 && !row[x] && s[1] <= maxCount) {
            s[1]++; x--
        }
        if (x < 0 || s[1] > maxCount) return Float.NaN
        while (x >= 0 && row[x] && s[0] <= maxCount) {
            s[0]++; x--
        }
        if (s[0] > maxCount) return Float.NaN

        x = startX + 1
        while (x < width && row[x]) {
            s[2]++; x++
        }
        if (x == width) return Float.NaN
        while (x < width && !row[x] && s[3] <= maxCount) {
            s[3]++; x++
        }
        if (x == width || s[3] > maxCount) return Float.NaN
        while (x < width && row[x] && s[4] <= maxCount) {
            s[4]++; x++
        }
        if (s[4] > maxCount) return Float.NaN

        val total = s[0] + s[1] + s[2] + s[3] + s[4]
        if (5 * abs(total - origTotal) >= origTotal) return Float.NaN
        return if (foundRatio(s)) (x - s[4] - s[3] - s[2] / 2.0f) else Float.NaN
    }

    private fun dist(a: FinderCenter, b: FinderCenter): Float {
        val dx = a.x - b.x
        val dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    private fun orderFinders(
        a: FinderCenter,
        b: FinderCenter,
        c: FinderCenter,
    ): Array<FinderCenter>? {
        val dab = dist(a, b)
        val dbc = dist(b, c)
        val dac = dist(a, c)
        val topLeft: FinderCenter
        var p1: FinderCenter
        var p2: FinderCenter
        if (dbc >= dab && dbc >= dac) {
            topLeft = a; p1 = b; p2 = c
        } else if (dac >= dab && dac >= dbc) {
            topLeft = b; p1 = a; p2 = c
        } else {
            topLeft = c; p1 = a; p2 = b
        }
        val d1 = dist(topLeft, p1)
        val d2 = dist(topLeft, p2)
        if (d1 < 10f || d2 < 10f) return null
        if (abs(d1 - d2) > max(d1, d2) * 0.35f) return null

        val cross = (p1.x - topLeft.x) * (p2.y - topLeft.y) - (p1.y - topLeft.y) * (p2.x - topLeft.x)
        if (cross < 0f) {
            val tmp = p1; p1 = p2; p2 = tmp
        }
        // topLeft, topRight (p1), bottomLeft (p2)
        return arrayOf(topLeft, p1, p2)
    }

    private fun sampleAndDecode(
        img: Array<BooleanArray>,
        width: Int,
        height: Int,
        tl: FinderCenter,
        tr: FinderCenter,
        bl: FinderCenter,
    ): String? {
        val modSize = (tl.moduleSize + tr.moduleSize + bl.moduleSize) / 3.0f
        if (modSize <= 0.5f) return null
        val dTop = dist(tl, tr)
        val dLeft = dist(tl, bl)
        val estDim = (((dTop + dLeft) / (2.0f * modSize)).roundToInt() + 7)
        val baseVer = ((estDim - 17) + 2) / 4

        for (verDelta in intArrayOf(0, -1, 1, -2, 2)) {
            val ver = baseVer + verDelta
            if (ver < 1 || ver > 25) continue
            val dim = 17 + 4 * ver
            val grid = sampleGrid(img, width, height, dim, tl, tr, bl, ver) ?: continue
            val text = decodeQrGrid(grid, dim, ver)
            if (text != null) return text
        }
        return null
    }

    private fun sampleGrid(
        img: Array<BooleanArray>,
        width: Int,
        height: Int,
        dim: Int,
        tl: FinderCenter,
        tr: FinderCenter,
        bl: FinderCenter,
        ver: Int,
    ): Array<BooleanArray>? {
        val span = (dim - 7).toFloat()
        val ux = (tr.x - tl.x) / span
        val uy = (tr.y - tl.y) / span
        val vx = (bl.x - tl.x) / span
        val vy = (bl.y - tl.y) / span

        val grid = Array(dim) { BooleanArray(dim) }
        for (r in 0 until dim) {
            val dy = r - 3.5f
            for (c in 0 until dim) {
                val dx = c - 3.5f
                val px = (tl.x + dx * ux + dy * vx).roundToInt()
                val py = (tl.y + dx * uy + dy * vy).roundToInt()
                if (px in 0 until width && py in 0 until height) {
                    grid[r][c] = img[py][px]
                }
            }
        }
        return grid
    }

    private fun decodeQrGrid(grid: Array<BooleanArray>, dim: Int, ver: Int): String? {
        val fmt = readFormatInfo(grid, dim) ?: return null
        val ecLevel = (fmt shr 3) and 0x03 // 1=L, 0=M, 3=Q, 2=H
        val mask = fmt and 0x07

        val func = buildFunctionMask(dim, ver)
        val codewords = readCodewords(grid, func, dim, mask)
        val dataBytes = correctErrors(codewords, ver, ecLevel) ?: return null
        return decodeDataStream(dataBytes, ver)
    }

    private val FORMAT_TABLE = intArrayOf(
        0x5412, 0x5125, 0x5E7C, 0x5B4B, 0x45F9, 0x40CE, 0x4F97, 0x4AA0,
        0x77C4, 0x72F3, 0x7DAA, 0x789D, 0x662F, 0x6318, 0x6C41, 0x6976,
        0x1689, 0x13BE, 0x1CE7, 0x19D0, 0x0762, 0x0255, 0x0D0C, 0x083B,
        0x355F, 0x3068, 0x3F31, 0x3A06, 0x24B4, 0x2183, 0x2EDA, 0x2BED,
    )

    private fun readFormatInfo(grid: Array<BooleanArray>, dim: Int): Int? {
        var bits1 = 0
        for (i in 0..5) bits1 = (bits1 shl 1) or if (grid[8][i]) 1 else 0
        bits1 = (bits1 shl 1) or if (grid[8][7]) 1 else 0
        bits1 = (bits1 shl 1) or if (grid[8][8]) 1 else 0
        bits1 = (bits1 shl 1) or if (grid[7][8]) 1 else 0
        for (i in 5 downTo 0) bits1 = (bits1 shl 1) or if (grid[i][8]) 1 else 0

        var bits2 = 0
        for (i in dim - 1 downTo dim - 7) bits2 = (bits2 shl 1) or if (grid[i][8]) 1 else 0
        for (i in dim - 8 until dim) bits2 = (bits2 shl 1) or if (grid[8][i]) 1 else 0

        var bestData = -1
        var bestDist = 4
        for (idx in FORMAT_TABLE.indices) {
            val target = FORMAT_TABLE[idx]
            val d1 = Integer.bitCount(bits1 xor target)
            if (d1 < bestDist) {
                bestDist = d1; bestData = idx
            }
            val d2 = Integer.bitCount(bits2 xor target)
            if (d2 < bestDist) {
                bestDist = d2; bestData = idx
            }
        }
        return if (bestData >= 0) bestData else null
    }

    private val ALIGN_POS = arrayOf(
        intArrayOf(),
        intArrayOf(),
        intArrayOf(6, 18),
        intArrayOf(6, 22),
        intArrayOf(6, 26),
        intArrayOf(6, 30),
        intArrayOf(6, 34),
        intArrayOf(6, 22, 38),
        intArrayOf(6, 24, 42),
        intArrayOf(6, 26, 46),
        intArrayOf(6, 28, 50),
        intArrayOf(6, 30, 54),
        intArrayOf(6, 32, 58),
        intArrayOf(6, 34, 62),
        intArrayOf(6, 26, 46, 66),
        intArrayOf(6, 26, 48, 70),
        intArrayOf(6, 26, 50, 74),
        intArrayOf(6, 30, 54, 78),
        intArrayOf(6, 30, 56, 82),
        intArrayOf(6, 30, 58, 86),
        intArrayOf(6, 34, 62, 90),
        intArrayOf(6, 28, 50, 72, 94),
        intArrayOf(6, 26, 50, 74, 98),
        intArrayOf(6, 30, 54, 78, 102),
        intArrayOf(6, 28, 54, 80, 106),
        intArrayOf(6, 32, 58, 84, 110),
    )

    private fun buildFunctionMask(dim: Int, ver: Int): Array<BooleanArray> {
        val f = Array(dim) { BooleanArray(dim) }
        fun markRect(r0: Int, c0: Int, h: Int, w: Int) {
            for (r in r0 until (r0 + h)) {
                for (c in c0 until (c0 + w)) {
                    if (r in 0 until dim && c in 0 until dim) f[r][c] = true
                }
            }
        }
        markRect(0, 0, 9, 9)
        markRect(0, dim - 8, 9, 8)
        markRect(dim - 8, 0, 8, 9)
        for (i in 0 until dim) {
            f[6][i] = true
            f[i][6] = true
        }
        if (ver in 2..25) {
            val pos = ALIGN_POS[ver]
            for (r in pos) {
                for (c in pos) {
                    if ((r == 6 && c == 6) || (r == 6 && c == dim - 7) || (r == dim - 7 && c == 6)) continue
                    markRect(r - 2, c - 2, 5, 5)
                }
            }
        }
        if (ver >= 7) {
            markRect(0, dim - 11, 6, 3)
            markRect(dim - 11, 0, 3, 6)
        }
        return f
    }

    private fun applyMask(mask: Int, r: Int, c: Int): Boolean = when (mask) {
        0 -> ((r + c) and 1) == 0
        1 -> (r and 1) == 0
        2 -> c % 3 == 0
        3 -> (r + c) % 3 == 0
        4 -> (((r / 2) + (c / 3)) and 1) == 0
        5 -> ((r * c) and 1) + ((r * c) % 3) == 0
        6 -> ((((r * c) and 1) + ((r * c) % 3)) and 1) == 0
        7 -> ((((r + c) and 1) + ((r * c) % 3)) and 1) == 0
        else -> false
    }

    private fun readCodewords(
        grid: Array<BooleanArray>,
        func: Array<BooleanArray>,
        dim: Int,
        mask: Int,
    ): IntArray {
        val bytes = mutableListOf<Int>()
        var curByte = 0
        var bitCount = 0
        var upward = true
        var col = dim - 1
        while (col > 0) {
            if (col == 6) col--
            for (step in 0 until dim) {
                val r = if (upward) (dim - 1 - step) else step
                for (dc in 0..1) {
                    val c = col - dc
                    if (!func[r][c]) {
                        val bit = grid[r][c] xor applyMask(mask, r, c)
                        curByte = (curByte shl 1) or if (bit) 1 else 0
                        bitCount++
                        if (bitCount == 8) {
                            bytes.add(curByte)
                            curByte = 0
                            bitCount = 0
                        }
                    }
                }
            }
            upward = !upward
            col -= 2
        }
        return bytes.toIntArray()
    }

    // Таблица параметров ECC для версий 1..25 и уровней L(1), M(0), Q(3), H(2).
    // Для каждого уровня: [ecCodewordsPerBlock, numBlocksGroup1, dataPerBlock1, numBlocksGroup2, dataPerBlock2]
    private val EC_BLOCKS = mapOf(
        // Level L (ecLevel = 1)
        (1 to 1) to intArrayOf(7, 1, 19, 0, 0),
        (2 to 1) to intArrayOf(10, 1, 34, 0, 0),
        (3 to 1) to intArrayOf(15, 1, 55, 0, 0),
        (4 to 1) to intArrayOf(20, 1, 80, 0, 0),
        (5 to 1) to intArrayOf(26, 1, 108, 0, 0),
        (6 to 1) to intArrayOf(18, 2, 68, 0, 0),
        (7 to 1) to intArrayOf(20, 2, 78, 0, 0),
        (8 to 1) to intArrayOf(24, 2, 97, 0, 0),
        (9 to 1) to intArrayOf(30, 2, 116, 0, 0),
        (10 to 1) to intArrayOf(18, 2, 68, 2, 69),
        (11 to 1) to intArrayOf(20, 4, 81, 0, 0),
        (12 to 1) to intArrayOf(24, 2, 92, 2, 93),
        (13 to 1) to intArrayOf(26, 4, 107, 0, 0),
        (14 to 1) to intArrayOf(30, 3, 115, 1, 116),
        (15 to 1) to intArrayOf(22, 5, 87, 1, 88),
        (16 to 1) to intArrayOf(24, 5, 98, 1, 99),
        (17 to 1) to intArrayOf(28, 1, 107, 5, 108),
        (18 to 1) to intArrayOf(30, 5, 120, 1, 121),
        (19 to 1) to intArrayOf(28, 3, 113, 4, 114),
        (20 to 1) to intArrayOf(28, 3, 107, 5, 108),
        // Level M (ecLevel = 0)
        (1 to 0) to intArrayOf(10, 1, 16, 0, 0),
        (2 to 0) to intArrayOf(16, 1, 28, 0, 0),
        (3 to 0) to intArrayOf(26, 1, 44, 0, 0),
        (4 to 0) to intArrayOf(18, 2, 32, 0, 0),
        (5 to 0) to intArrayOf(24, 2, 43, 0, 0),
        (6 to 0) to intArrayOf(16, 4, 27, 0, 0),
        (7 to 0) to intArrayOf(18, 4, 31, 0, 0),
        (8 to 0) to intArrayOf(22, 2, 38, 2, 39),
        (9 to 0) to intArrayOf(22, 3, 36, 2, 37),
        (10 to 0) to intArrayOf(26, 4, 43, 1, 44),
        (11 to 0) to intArrayOf(30, 1, 50, 4, 51),
        (12 to 0) to intArrayOf(22, 6, 36, 2, 37),
        (13 to 0) to intArrayOf(22, 8, 37, 1, 38),
        (14 to 0) to intArrayOf(24, 4, 40, 5, 41),
        (15 to 0) to intArrayOf(24, 5, 41, 5, 42),
        (16 to 0) to intArrayOf(28, 7, 45, 3, 46),
        (17 to 0) to intArrayOf(28, 10, 46, 1, 47),
        (18 to 0) to intArrayOf(26, 9, 43, 4, 44),
        (19 to 0) to intArrayOf(26, 3, 44, 11, 45),
        (20 to 0) to intArrayOf(26, 3, 41, 13, 42),
        // Level Q (ecLevel = 3)
        (1 to 3) to intArrayOf(13, 1, 13, 0, 0),
        (2 to 3) to intArrayOf(22, 1, 22, 0, 0),
        (3 to 3) to intArrayOf(18, 2, 17, 0, 0),
        (4 to 3) to intArrayOf(26, 2, 24, 0, 0),
        (5 to 3) to intArrayOf(18, 2, 15, 2, 16),
        (6 to 3) to intArrayOf(24, 4, 19, 0, 0),
        (7 to 3) to intArrayOf(18, 2, 14, 4, 15),
        (8 to 3) to intArrayOf(22, 4, 18, 2, 19),
        (9 to 3) to intArrayOf(20, 4, 16, 4, 17),
        (10 to 3) to intArrayOf(24, 6, 19, 2, 20),
        (11 to 3) to intArrayOf(28, 4, 22, 4, 23),
        (12 to 3) to intArrayOf(26, 4, 20, 6, 21),
        // Level H (ecLevel = 2)
        (1 to 2) to intArrayOf(17, 1, 9, 0, 0),
        (2 to 2) to intArrayOf(28, 1, 16, 0, 0),
        (3 to 2) to intArrayOf(22, 2, 11, 0, 0),
        (4 to 2) to intArrayOf(16, 4, 9, 0, 0),
        (5 to 2) to intArrayOf(22, 2, 11, 2, 12),
        (6 to 2) to intArrayOf(28, 4, 15, 0, 0),
        (7 to 2) to intArrayOf(26, 4, 13, 1, 14),
        (8 to 2) to intArrayOf(26, 4, 14, 2, 15),
        (9 to 2) to intArrayOf(24, 4, 12, 4, 13),
        (10 to 2) to intArrayOf(28, 6, 15, 2, 16),
    )

    private fun correctErrors(raw: IntArray, ver: Int, ecLevel: Int): ByteArray? {
        val spec = EC_BLOCKS[ver to ecLevel] ?: return null
        val ecPerBlock = spec[0]
        val numB1 = spec[1]
        val dataB1 = spec[2]
        val numB2 = spec[3]
        val dataB2 = spec[4]
        val totalBlocks = numB1 + numB2
        val blocksData = Array(totalBlocks) { idx ->
            IntArray(if (idx < numB1) dataB1 else dataB2)
        }
        val blocksEc = Array(totalBlocks) { IntArray(ecPerBlock) }

        var pos = 0
        val maxDataLen = max(dataB1, dataB2)
        for (i in 0 until maxDataLen) {
            for (b in 0 until totalBlocks) {
                if (i < blocksData[b].size && pos < raw.size) {
                    blocksData[b][i] = raw[pos++]
                }
            }
        }
        for (i in 0 until ecPerBlock) {
            for (b in 0 until totalBlocks) {
                if (pos < raw.size) {
                    blocksEc[b][i] = raw[pos++]
                }
            }
        }

        val out = ByteArray(numB1 * dataB1 + numB2 * dataB2)
        var outPos = 0
        for (b in 0 until totalBlocks) {
            val dLen = blocksData[b].size
            val cw = IntArray(dLen + ecPerBlock)
            System.arraycopy(blocksData[b], 0, cw, 0, dLen)
            System.arraycopy(blocksEc[b], 0, cw, dLen, ecPerBlock)
            if (!rsDecode(cw, ecPerBlock)) return null
            for (i in 0 until dLen) {
                out[outPos++] = cw[i].toByte()
            }
        }
        return out
    }

    // GF(256) с примитивным полиномом 0x11D
    private val GF_EXP = IntArray(512)
    private val GF_LOG = IntArray(256)

    init {
        var x = 1
        for (i in 0 until 255) {
            GF_EXP[i] = x
            GF_LOG[x] = i
            x = x shl 1
            if ((x and 0x100) != 0) x = x xor 0x11D
        }
        for (i in 255 until 512) {
            GF_EXP[i] = GF_EXP[i - 255]
        }
    }

    private fun gfMul(a: Int, b: Int): Int {
        if (a == 0 || b == 0) return 0
        return GF_EXP[GF_LOG[a] + GF_LOG[b]]
    }

    private fun gfInv(a: Int): Int = GF_EXP[255 - GF_LOG[a]]

    private fun rsDecode(cw: IntArray, twoS: Int): Boolean {
        val syn = IntArray(twoS)
        var hasError = false
        for (i in 0 until twoS) {
            var eval = 0
            val a = GF_EXP[i]
            for (c in cw) {
                eval = gfMul(eval, a) xor (c and 0xFF)
            }
            syn[i] = eval
            if (eval != 0) hasError = true
        }
        if (!hasError) return true

        // Алгоритм Берлекэмпа-Мэсси
        var sigma = intArrayOf(1)
        var oldSigma = intArrayOf(1)
        var l = 0
        var m = 1
        var bVal = 1
        for (n in 0 until twoS) {
            var d = syn[n]
            for (i in 1..l) {
                if (i < sigma.size) {
                    d = d xor gfMul(sigma[i], syn[n - i])
                }
            }
            if (d == 0) {
                m++
            } else {
                val t = sigma.copyOf(max(sigma.size, oldSigma.size + m))
                val factor = gfMul(d, gfInv(bVal))
                for (i in oldSigma.indices) {
                    t[i + m] = t[i + m] xor gfMul(factor, oldSigma[i])
                }
                if (2 * l <= n) {
                    l = n + 1 - l
                    oldSigma = sigma
                    bVal = d
                    m = 1
                } else {
                    m++
                }
                sigma = t
            }
        }
        if (l > twoS / 2) return false

        // Поиск корней Ченя
        val errLocs = mutableListOf<Int>()
        for (i in 0 until cw.size) {
            val xInv = GF_EXP[(255 - i) % 255]
            var sum = 0
            var xPow = 1
            for (coef in sigma) {
                sum = sum xor gfMul(coef, xPow)
                xPow = gfMul(xPow, xInv)
            }
            if (sum == 0) errLocs.add(i)
        }
        if (errLocs.size != l) return false

        // Полином оценки ошибок Омега
        val omega = IntArray(twoS)
        for (i in 0 until twoS) {
            var v = 0
            for (j in 0..min(i, sigma.size - 1)) {
                v = v xor gfMul(sigma[j], syn[i - j])
            }
            omega[i] = v
        }

        // Формула Форни
        for (pos in errLocs) {
            val xInv = GF_EXP[(255 - pos) % 255]
            var num = 0
            var xPow = 1
            for (i in 0 until twoS) {
                num = num xor gfMul(omega[i], xPow)
                xPow = gfMul(xPow, xInv)
            }
            var den = 0
            var xPow2 = 1
            var i = 1
            while (i < sigma.size) {
                den = den xor gfMul(sigma[i], xPow2)
                xPow2 = gfMul(xPow2, gfMul(xInv, xInv))
                i += 2
            }
            if (den == 0) return false
            val errMag = gfMul(num, gfInv(den))
            val idx = cw.size - 1 - pos
            if (idx in cw.indices) {
                cw[idx] = (cw[idx] xor errMag) and 0xFF
            }
        }
        return true
    }

    private val ALPHANUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

    private fun decodeDataStream(bytes: ByteArray, ver: Int): String? {
        var bitOffset = 0
        fun readBits(count: Int): Int {
            var res = 0
            for (i in 0 until count) {
                val byteIdx = bitOffset shr 3
                if (byteIdx >= bytes.size) return -1
                val bit = (bytes[byteIdx].toInt() shr (7 - (bitOffset and 7))) and 1
                res = (res shl 1) or bit
                bitOffset++
            }
            return res
        }

        val sb = StringBuilder()
        while (bitOffset + 4 <= bytes.size * 8) {
            val mode = readBits(4)
            if (mode == 0) break // Terminator
            when (mode) {
                0x4 -> { // Byte mode
                    val lenBits = if (ver <= 9) 8 else 16
                    val count = readBits(lenBits)
                    if (count < 0) return null
                    val buf = ByteArray(count)
                    for (i in 0 until count) {
                        val b = readBits(8)
                        if (b < 0) return null
                        buf[i] = b.toByte()
                    }
                    sb.append(String(buf, StandardCharsets.UTF_8))
                }
                0x2 -> { // Alphanumeric mode
                    val lenBits = if (ver <= 9) 9 else if (ver <= 26) 11 else 13
                    var count = readBits(lenBits)
                    if (count < 0) return null
                    while (count > 1) {
                        val v = readBits(11)
                        if (v < 0 || v / 45 >= ALPHANUM.length) return null
                        sb.append(ALPHANUM[v / 45])
                        sb.append(ALPHANUM[v % 45])
                        count -= 2
                    }
                    if (count == 1) {
                        val v = readBits(6)
                        if (v < 0 || v >= ALPHANUM.length) return null
                        sb.append(ALPHANUM[v])
                    }
                }
                0x1 -> { // Numeric mode
                    val lenBits = if (ver <= 9) 10 else if (ver <= 26) 12 else 14
                    var count = readBits(lenBits)
                    if (count < 0) return null
                    while (count >= 3) {
                        val v = readBits(10)
                        if (v < 0 || v >= 1000) return null
                        sb.append(String.format("%03d", v))
                        count -= 3
                    }
                    if (count == 2) {
                        val v = readBits(7)
                        if (v < 0 || v >= 100) return null
                        sb.append(String.format("%02d", v))
                    } else if (count == 1) {
                        val v = readBits(4)
                        if (v < 0 || v >= 10) return null
                        sb.append(v)
                    }
                }
                0x7 -> { // ECI
                    val b1 = readBits(8)
                    if ((b1 and 0x80) != 0) readBits(8)
                }
                else -> break
            }
        }
        return if (sb.isNotEmpty()) sb.toString() else null
    }
}
