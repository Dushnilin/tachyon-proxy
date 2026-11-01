import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Чистый Dart-генератор и виджет QR-кода (ISO/IEC 18004, Byte Mode, ECC Level L, версии 1..20, до 858 байт).
/// Не требует сторонних пакетов.
class QrCodeView extends StatelessWidget {
  const QrCodeView({
    super.key,
    required this.data,
    this.size = 220,
    this.foregroundColor = Colors.black,
    this.backgroundColor = Colors.white,
  });

  final String data;
  final double size;
  final Color foregroundColor;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final matrix = _QrEncoder.encode(data);
    if (matrix == null) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Ссылка слишком длинная для QR-кода (используйте кнопку Копировать или Поделиться)',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.black87),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: CustomPaint(
        size: Size.square(size - 24),
        painter: _QrPainter(matrix: matrix, color: foregroundColor),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter({required this.matrix, required this.color});

  final List<List<bool>> matrix;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final n = matrix.length;
    if (n == 0) return;
    final cell = size.width / n;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (matrix[r][c]) {
          canvas.drawRect(
            Rect.fromLTWH(c * cell, r * cell, cell + 0.35, cell + 0.35),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.matrix != matrix || oldDelegate.color != color;
}

class _QrEncoder {
  // Таблица параметров версий 1..20 для уровня коррекции L:
  // [ecCodewordsPerBlock, blocksGroup1, dataCwGroup1, blocksGroup2, dataCwGroup2]
  static const List<List<int>> _vTableL = [
    [],
    [7, 1, 19, 0, 0], // v1
    [10, 1, 34, 0, 0], // v2
    [15, 1, 55, 0, 0], // v3
    [20, 1, 80, 0, 0], // v4
    [26, 1, 108, 0, 0], // v5
    [18, 2, 68, 0, 0], // v6
    [20, 2, 78, 0, 0], // v7
    [24, 2, 97, 0, 0], // v8
    [30, 2, 116, 0, 0], // v9
    [18, 2, 68, 2, 69], // v10
    [20, 4, 81, 0, 0], // v11
    [24, 2, 92, 2, 93], // v12
    [26, 4, 107, 0, 0], // v13
    [30, 3, 115, 1, 116], // v14
    [22, 5, 87, 1, 88], // v15
    [24, 5, 98, 1, 99], // v16
    [28, 1, 107, 5, 108], // v17
    [30, 5, 120, 1, 121], // v18
    [28, 3, 113, 4, 114], // v19
    [28, 3, 107, 5, 108], // v20
  ];

  static const List<List<int>> _alignCenters = [
    [],
    [],
    [6, 18],
    [6, 22],
    [6, 26],
    [6, 30],
    [6, 34],
    [6, 22, 38],
    [6, 24, 42],
    [6, 26, 46],
    [6, 28, 50],
    [6, 30, 54],
    [6, 32, 58],
    [6, 34, 62],
    [6, 26, 46, 66],
    [6, 26, 48, 70],
    [6, 26, 50, 74],
    [6, 30, 54, 78],
    [6, 30, 56, 82],
    [6, 30, 58, 86],
    [6, 34, 62, 90],
  ];

  static List<List<bool>>? encode(String text) {
    final payload = utf8.encode(text);
    var version = 0;
    for (var v = 1; v <= 20; v++) {
      final spec = _vTableL[v];
      final totalDataCw = spec[1] * spec[2] + spec[3] * spec[4];
      final lenBits = v <= 9 ? 8 : 16;
      final maxBytes = ((totalDataCw * 8) - 4 - lenBits) ~/ 8;
      if (payload.length <= maxBytes) {
        version = v;
        break;
      }
    }
    if (version == 0) return null;

    final spec = _vTableL[version];
    final ecPerBlock = spec[0];
    final g1Blocks = spec[1];
    final g1DataCw = spec[2];
    final g2Blocks = spec[3];
    final g2DataCw = spec[4];
    final totalDataCw = g1Blocks * g1DataCw + g2Blocks * g2DataCw;

    // 1. Собираем битовый поток данных (Byte Mode = 0100)
    final bits = <int>[];
    void pushBits(int val, int count) {
      for (var i = count - 1; i >= 0; i--) {
        bits.add((val >> i) & 1);
      }
    }

    pushBits(0x4, 4);
    pushBits(payload.length, version <= 9 ? 8 : 16);
    for (final b in payload) {
      pushBits(b, 8);
    }
    final capBits = totalDataCw * 8;
    for (var i = 0; i < 4 && bits.length < capBits; i++) {
      bits.add(0);
    }
    while (bits.length % 8 != 0) {
      bits.add(0);
    }
    final dataCodewords = Uint8List(totalDataCw);
    for (var i = 0; i < bits.length ~/ 8; i++) {
      var byte = 0;
      for (var b = 0; b < 8; b++) {
        byte = (byte << 1) | bits[i * 8 + b];
      }
      dataCodewords[i] = byte;
    }
    const padBytes = [0xEC, 0x11];
    for (var i = bits.length ~/ 8, p = 0; i < totalDataCw; i++, p++) {
      dataCodewords[i] = padBytes[p & 1];
    }

    // 2. Разбиваем на блоки и считаем Reed-Solomon ECC
    final dataBlocks = <Uint8List>[];
    final ecBlocks = <Uint8List>[];
    var offset = 0;
    for (var i = 0; i < g1Blocks; i++) {
      final blk = Uint8List.sublistView(dataCodewords, offset, offset + g1DataCw);
      offset += g1DataCw;
      dataBlocks.add(blk);
      ecBlocks.add(_rsEncode(blk, ecPerBlock));
    }
    for (var i = 0; i < g2Blocks; i++) {
      final blk = Uint8List.sublistView(dataCodewords, offset, offset + g2DataCw);
      offset += g2DataCw;
      dataBlocks.add(blk);
      ecBlocks.add(_rsEncode(blk, ecPerBlock));
    }

    // 3. Чередуем (interleave) кодовые слова данных и коррекции
    final interleaved = <int>[];
    final maxDataLen = g2Blocks > 0 ? g2DataCw : g1DataCw;
    for (var i = 0; i < maxDataLen; i++) {
      for (final blk in dataBlocks) {
        if (i < blk.length) interleaved.add(blk[i]);
      }
    }
    for (var i = 0; i < ecPerBlock; i++) {
      for (final blk in ecBlocks) {
        interleaved.add(blk[i]);
      }
    }

    // 4. Строим матрицу
    final size = 17 + 4 * version;
    final modules = List.generate(size, (_) => List<bool>.filled(size, false));
    final isFunction = List.generate(size, (_) => List<bool>.filled(size, false));

    void setFunc(int r, int c, bool dark) {
      if (r < 0 || r >= size || c < 0 || c >= size) return;
      modules[r][c] = dark;
      isFunction[r][c] = true;
    }

    void drawFinder(int topR, int leftC) {
      for (var dr = -1; dr <= 7; dr++) {
        for (var dc = -1; dc <= 7; dc++) {
          final r = topR + dr;
          final c = leftC + dc;
          if (r < 0 || r >= size || c < 0 || c >= size) continue;
          final inOuter = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
          final onBorder = dr == 0 || dr == 6 || dc == 0 || dc == 6;
          final inCenter = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4;
          setFunc(r, c, inOuter && (onBorder || inCenter));
        }
      }
    }

    drawFinder(0, 0);
    drawFinder(0, size - 7);
    drawFinder(size - 7, 0);

    // Timing patterns
    for (var i = 8; i < size - 8; i++) {
      setFunc(6, i, i % 2 == 0);
      setFunc(i, 6, i % 2 == 0);
    }

    // Alignment patterns
    final centers = _alignCenters[version];
    for (final r in centers) {
      for (final c in centers) {
        if ((r == 6 && c == 6) ||
            (r == 6 && c == size - 7) ||
            (r == size - 7 && c == 6)) {
          continue;
        }
        for (var dr = -2; dr <= 2; dr++) {
          for (var dc = -2; dc <= 2; dc++) {
            final dark = dr.abs() == 2 || dc.abs() == 2 || (dr == 0 && dc == 0);
            setFunc(r + dr, c + dc, dark);
          }
        }
      }
    }

    // Резервируем области формата и версии
    for (var i = 0; i <= 8; i++) {
      if (i != 6) {
        setFunc(8, i, false);
        setFunc(i, 8, false);
      }
    }
    for (var i = 0; i < 8; i++) {
      setFunc(8, size - 1 - i, false);
      setFunc(size - 1 - i, 8, false);
    }
    setFunc(size - 8, 8, true); // Dark module

    if (version >= 7) {
      var rem = version;
      for (var i = 0; i < 12; i++) {
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
      }
      final vBits = (version << 12) | rem;
      for (var i = 0; i < 18; i++) {
        final bit = ((vBits >> i) & 1) != 0;
        final a = size - 11 + (i % 3);
        final b = i ~/ 3;
        setFunc(a, b, bit);
        setFunc(b, a, bit);
      }
    }

    // 5. Зигзаг-укладка битов и маска 0 ((r + c) % 2 == 0)
    var bitIdx = 0;
    final totalBits = interleaved.length * 8;
    var upward = true;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        final r = upward ? (size - 1 - vert) : vert;
        for (var j = 0; j < 2; j++) {
          final c = right - j;
          if (!isFunction[r][c]) {
            var dark = false;
            if (bitIdx < totalBits) {
              dark = ((interleaved[bitIdx >> 3] >> (7 - (bitIdx & 7))) & 1) != 0;
              bitIdx++;
            }
            if ((r + c) % 2 == 0) dark = !dark;
            modules[r][c] = dark;
          }
        }
      }
      upward = !upward;
    }

    // 6. Записываем Format Info для ECC Level L (01) + Mask 0 (000) -> 0b01000
    const data = 0x08; // 01_000
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final formatBits = ((data << 10) | rem) ^ 0x5412;
    for (var i = 0; i <= 5; i++) {
      setFunc(8, i, ((formatBits >> i) & 1) != 0);
    }
    setFunc(8, 7, ((formatBits >> 6) & 1) != 0);
    setFunc(8, 8, ((formatBits >> 7) & 1) != 0);
    setFunc(7, 8, ((formatBits >> 8) & 1) != 0);
    for (var i = 9; i < 15; i++) {
      setFunc(14 - i, 8, ((formatBits >> i) & 1) != 0);
    }
    for (var i = 0; i < 8; i++) {
      setFunc(8, size - 1 - i, ((formatBits >> i) & 1) != 0);
    }
    for (var i = 8; i < 15; i++) {
      setFunc(size - 15 + i, 8, ((formatBits >> i) & 1) != 0);
    }

    return modules;
  }

  static Uint8List _rsEncode(Uint8List data, int degree) {
    final gen = Uint8List(degree);
    gen[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        gen[j] = _gfMul(gen[j], root);
        if (j + 1 < degree) gen[j] ^= gen[j + 1];
      }
      root = _gfMul(root, 0x02);
    }

    final result = Uint8List(degree);
    for (final b in data) {
      final factor = b ^ result[0];
      for (var i = 0; i < degree - 1; i++) {
        result[i] = result[i + 1] ^ _gfMul(gen[i], factor);
      }
      result[degree - 1] = _gfMul(gen[degree - 1], factor);
    }
    return result;
  }

  static int _gfMul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z;
  }
}
