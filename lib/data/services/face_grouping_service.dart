import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/face_cluster.dart';
import '../models/vault_media.dart';
import 'crypto_service.dart';
import 'local_db_service.dart';

class _CroppedFacePayload {
  final Uint8List modelRgbBytes;
  final Uint8List flippedRgbBytes;
  final Uint8List avatarJpg;

  const _CroppedFacePayload({
    required this.modelRgbBytes,
    required this.flippedRgbBytes,
    required this.avatarJpg,
  });
}

/// Normalizes EXIF rotation & scales large photos to max 1280px so ML Kit
/// and Dart cropping share the exact same upright coordinate grid with zero OOM.
Uint8List? _prepareUprightJpgIsolate(Uint8List sourceBytes) {
  try {
    final decoded = img.decodeImage(sourceBytes);
    if (decoded == null) return null;

    final oriented = img.bakeOrientation(decoded);
    img.Image normalized = oriented;
    if (oriented.width >= oriented.height && oriented.width > 1280) {
      normalized = img.copyResize(oriented, width: 1280);
    } else if (oriented.height > oriented.width && oriented.height > 1280) {
      normalized = img.copyResize(oriented, height: 1280);
    }
    return img.encodeJpg(normalized, quality: 90);
  } catch (_) {
    return null;
  }
}

/// Helper: Extracts an exact 1:1 square crop centered on (cx, cy), optionally
/// rotating upright with extra margin so no black corner triangles enter the crop.
img.Image _extractAlignedSquare({
  required img.Image source,
  required double centerX,
  required double centerY,
  required double targetSide,
  required double rollAngle,
}) {
  final imgW = source.width;
  final imgH = source.height;
  final maxPossible = math.min<int>(imgW, imgH);

  final shouldRotate = rollAngle.abs() > 3.0 && rollAngle.abs() < 45.0;
  final desiredSide = targetSide.round().clamp(32, maxPossible).toInt();

  if (!shouldRotate) {
    final x = (centerX - desiredSide / 2.0)
        .round()
        .clamp(0, imgW - desiredSide)
        .toInt();
    final y = (centerY - desiredSide / 2.0)
        .round()
        .clamp(0, imgH - desiredSide)
        .toInt();
    return img.copyCrop(
      source,
      x: x,
      y: y,
      width: desiredSide,
      height: desiredSide,
    );
  }

  final outerSide =
      (targetSide * 1.42).round().clamp(desiredSide, maxPossible).toInt();
  final ox = (centerX - outerSide / 2.0)
      .round()
      .clamp(0, imgW - outerSide)
      .toInt();
  final oy = (centerY - outerSide / 2.0)
      .round()
      .clamp(0, imgH - outerSide)
      .toInt();
  final preCrop = img.copyCrop(
    source,
    x: ox,
    y: oy,
    width: outerSide,
    height: outerSide,
  );

  final rotated = img.copyRotate(preCrop, angle: -rollAngle);
  final finalSide = desiredSide
      .clamp(32, math.min<int>(rotated.width, rotated.height))
      .toInt();
  final rx = ((rotated.width - finalSide) / 2.0)
      .round()
      .clamp(0, rotated.width - finalSide)
      .toInt();
  final ry = ((rotated.height - finalSide) / 2.0)
      .round()
      .clamp(0, rotated.height - finalSide)
      .toInt();

  return img.copyCrop(
    rotated,
    x: rx,
    y: ry,
    width: finalSide,
    height: finalSide,
  );
}

/// Bilinearly warps the face using a 2D similarity transform anchored to the eyes
/// so MobileFaceNet receives exact ArcFace 112x112 aligned coordinates.
Uint8List? _tryArcFaceEyeAlignedRgb({
  required img.Image source,
  required double boxWidth,
  required double? leftEyeX,
  required double? leftEyeY,
  required double? rightEyeX,
  required double? rightEyeY,
  required double? noseX,
  required double? noseY,
  required int inputW,
  required int inputH,
}) {
  if (leftEyeX == null ||
      leftEyeY == null ||
      rightEyeX == null ||
      rightEyeY == null) {
    return null;
  }

  // Sort by image X so vector always runs image-left -> image-right
  final bool swap = leftEyeX > rightEyeX;
  final lx = swap ? rightEyeX : leftEyeX;
  final ly = swap ? rightEyeY : leftEyeY;
  final rx = swap ? leftEyeX : rightEyeX;
  final ry = swap ? leftEyeY : rightEyeY;

  final dx = rx - lx;
  final dy = ry - ly;
  final srcDist = math.sqrt(dx * dx + dy * dy);
  if (srcDist < boxWidth * 0.22 || srcDist > boxWidth * 0.68) return null;

  final eyeAngleDeg = math.atan2(dy, dx) * 180.0 / math.pi;
  if (eyeAngleDeg.abs() > 45.0) return null;

  final ux = dx / srcDist;
  final uy = dy / srcDist;
  // Perpendicular downward unit vector in image space (Y grows downward)
  final vx = -uy;
  final vy = ux;

  final srcMidX = (lx + rx) * 0.5;
  final srcMidY = (ly + ry) * 0.5;

  // Sanity check: nose must sit below the eye line
  if (noseX != null && noseY != null) {
    final noseDown = (noseX - srcMidX) * vx + (noseY - srcMidY) * vy;
    if (noseDown < srcDist * 0.12) return null;
  }

  // ArcFace / InsightFace standard 112x112 template eye landmarks:
  // leftEye=(38.2946, 51.6963), rightEye=(73.5318, 51.5014)
  final scaleX = inputW / 112.0;
  final scaleY = inputH / 112.0;
  final dstMidX = 55.9132 * scaleX;
  final dstMidY = 51.5989 * scaleY;
  final dstEyeDist = 35.2377 * scaleX;
  final srcPerDst = srcDist / dstEyeDist;

  final imgW = source.width;
  final imgH = source.height;
  final maxX = (imgW - 1).toDouble();
  final maxY = (imgH - 1).toDouble();

  final out = Uint8List(inputW * inputH * 3);
  int idx = 0;

  for (int v = 0; v < inputH; v++) {
    final dv = (v - dstMidY) * srcPerDst;
    final rowBaseX = srcMidX + dv * vx;
    final rowBaseY = srcMidY + dv * vy;

    for (int u = 0; u < inputW; u++) {
      final du = (u - dstMidX) * srcPerDst;
      final sx = (rowBaseX + du * ux).clamp(0.0, maxX);
      final sy = (rowBaseY + du * uy).clamp(0.0, maxY);

      final x0 = sx.floor();
      final y0 = sy.floor();
      final x1 = x0 + 1 < imgW ? x0 + 1 : x0;
      final y1 = y0 + 1 < imgH ? y0 + 1 : y0;
      final fx = sx - x0;
      final fy = sy - y0;
      final w00 = (1.0 - fx) * (1.0 - fy);
      final w10 = fx * (1.0 - fy);
      final w01 = (1.0 - fx) * fy;
      final w11 = fx * fy;

      final p00 = source.getPixel(x0, y0);
      final p10 = source.getPixel(x1, y0);
      final p01 = source.getPixel(x0, y1);
      final p11 = source.getPixel(x1, y1);

      final r = (p00.r * w00 + p10.r * w10 + p01.r * w01 + p11.r * w11)
          .round()
          .clamp(0, 255);
      final g = (p00.g * w00 + p10.g * w10 + p01.g * w01 + p11.g * w11)
          .round()
          .clamp(0, 255);
      final b = (p00.b * w00 + p10.b * w10 + p01.b * w01 + p11.b * w11)
          .round()
          .clamp(0, 255);

      out[idx++] = r;
      out[idx++] = g;
      out[idx++] = b;
    }
  }

  return out;
}

Uint8List _flipRgbHorizontal(Uint8List rgb, int width, int height) {
  final out = Uint8List(rgb.length);
  for (int y = 0; y < height; y++) {
    final rowOffset = y * width * 3;
    for (int x = 0; x < width; x++) {
      final srcIdx = rowOffset + x * 3;
      final dstIdx = rowOffset + (width - 1 - x) * 3;
      out[dstIdx] = rgb[srcIdx];
      out[dstIdx + 1] = rgb[srcIdx + 1];
      out[dstIdx + 2] = rgb[srcIdx + 2];
    }
  }
  return out;
}

/// Crops upright, eye-aligned faces for both MobileFaceNet (inputW x inputH RGB
/// + horizontal mirror) and the encrypted 160x160 UI avatar.
List<_CroppedFacePayload> _cropFacesIsolate(Map<String, dynamic> args) {
  final uprightBytes = args['bytes'] as Uint8List;
  final rawFaces = args['faces'] as List;
  final inputW = args['inputW'] as int;
  final inputH = args['inputH'] as int;

  final image = img.decodeImage(uprightBytes);
  if (image == null) return const [];

  if (math.min<int>(image.width, image.height) < 40) return const [];
  final results = <_CroppedFacePayload>[];

  for (final raw in rawFaces) {
    final f = raw as Map<String, dynamic>;
    final left = f['left'] as double;
    final top = f['top'] as double;
    final width = f['width'] as double;
    final height = f['height'] as double;
    final rollAngle = (f['roll'] as double?) ?? 0.0;

    if (width < 44 || height < 44) continue;

    final centerX = left + (width / 2.0);
    final centerY = top + (height / 2.0);
    final baseSide = math.max<double>(width, height);

    // 1. Padded 1:1 avatar thumbnail for People tab
    final avatarSquare = _extractAlignedSquare(
      source: image,
      centerX: centerX,
      centerY: centerY,
      targetSide: baseSide * 1.50,
      rollAngle: rollAngle,
    );
    final avatarSmall = img.copyResize(
      avatarSquare,
      width: 160,
      height: 160,
      interpolation: img.Interpolation.linear,
    );
    final avatarJpg = img.encodeJpg(avatarSmall, quality: 82);

    // 2. Prefer exact ArcFace eye-aligned crop; fallback to 1:1 square box crop
    Uint8List? modelRgb = _tryArcFaceEyeAlignedRgb(
      source: image,
      boxWidth: width,
      leftEyeX: f['leftEyeX'] as double?,
      leftEyeY: f['leftEyeY'] as double?,
      rightEyeX: f['rightEyeX'] as double?,
      rightEyeY: f['rightEyeY'] as double?,
      noseX: f['noseX'] as double?,
      noseY: f['noseY'] as double?,
      inputW: inputW,
      inputH: inputH,
    );

    if (modelRgb == null) {
      final modelSquare = _extractAlignedSquare(
        source: image,
        centerX: centerX,
        centerY: centerY,
        targetSide: baseSide * 1.12,
        rollAngle: rollAngle,
      );
      final resized = img.copyResize(
        modelSquare,
        width: inputW,
        height: inputH,
        interpolation: img.Interpolation.linear,
      );
      modelRgb = _imageToRgbBytes(resized);
    }

    final flippedRgb = _flipRgbHorizontal(modelRgb, inputW, inputH);

    results.add(
      _CroppedFacePayload(
        modelRgbBytes: modelRgb,
        flippedRgbBytes: flippedRgb,
        avatarJpg: avatarJpg,
      ),
    );
  }

  return results;
}

Uint8List _imageToRgbBytes(img.Image image) {
  final out = Uint8List(image.width * image.height * 3);
  int idx = 0;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      out[idx++] = p.r.toInt();
      out[idx++] = p.g.toInt();
      out[idx++] = p.b.toInt();
    }
  }
  return out;
}

List<double> _l2Normalize(List<double> v) {
  double sumSq = 0.0;
  for (final x in v) {
    sumSq += x * x;
  }
  final norm = math.sqrt(sumSq);
  if (norm < 1e-9) return const [];
  return v.map((x) => x / norm).toList();
}

class FaceGroupingService {
  static const String _modelAssetPath = 'assets/models/mobilefacenet.tflite';
  static const int expectedEmbeddingDim = 192;

  /// Calibrated MobileFaceNet 192-D cosine threshold (~1.00 Euclidean).
  /// Strangers stay < 0.38 on eye-aligned crops; same person across angles/light >= 0.50.
  static const double _matchThreshold = 0.50;

  /// Only update a cluster's centroid on high-confidence matches to stop drift.
  static const double _centroidUpdateThreshold = 0.62;

  /// Post-scan auto-consolidation threshold for merging split sub-groups of the same person.
  static const double _consolidateThreshold = 0.56;

  static const int _maxCentroidWeight = 20;
  static const int _maxAvatarRamBytes = 12 * 1024 * 1024;

  final CryptoService _crypto;
  final LocalDbService _db;

  FaceDetector? _detector;
  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;
  Future<bool>? _modelInitFuture;
  Future<void> _inferenceQueue = Future<void>.value();
  bool _isDisposed = false;

  int _inputH = 112;
  int _inputW = 112;
  int _outputDim = expectedEmbeddingDim;
  TensorType _inputType = TensorType.float32;
  TensorType _outputType = TensorType.float32;
  double _outputScale = 1.0;
  int _outputZeroPoint = 0;

  final LinkedHashMap<String, Uint8List> _avatarRamCache =
      LinkedHashMap<String, Uint8List>();
  int _currentAvatarRamBytes = 0;

  FaceGroupingService({
    required CryptoService cryptoService,
    required LocalDbService localDbService,
  })  : _crypto = cryptoService,
        _db = localDbService;

  int get activeEmbeddingDim => _outputDim;

  FaceDetector get _faceDetector => _detector ??= FaceDetector(
        options: FaceDetectorOptions(
          enableLandmarks: true,
          enableContours: false,
          enableClassification: false,
          enableTracking: false,
          minFaceSize: 0.06,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );

  /// Serializes all native TFLite calls so concurrent upload + batch scan never SIGSEGV.
  Future<T> _runSerialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _inferenceQueue = _inferenceQueue.then((_) async {
      try {
        final result = await action();
        if (!completer.isCompleted) completer.complete(result);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<bool> _ensureModelLoaded() {
    if (_isDisposed) return Future<bool>.value(false);
    if (_interpreter != null) return Future<bool>.value(true);
    return _modelInitFuture ??= _loadModelInternal();
  }

  Future<bool> _loadModelInternal() async {
    try {
      final options = InterpreterOptions()..threads = 2;
      final interpreter = await Interpreter.fromAsset(
        _modelAssetPath,
        options: options,
      );

      final inTensor = interpreter.getInputTensor(0);
      final outTensor = interpreter.getOutputTensor(0);

      if (inTensor.shape.length >= 3) {
        _inputH = inTensor.shape[1];
        _inputW = inTensor.shape[2];
      }
      _outputDim =
          outTensor.shape.isNotEmpty ? outTensor.shape.last : expectedEmbeddingDim;
      _inputType = inTensor.type;
      _outputType = outTensor.type;

      try {
        final q = outTensor.params;
        if (q.scale > 0) {
          _outputScale = q.scale;
          _outputZeroPoint = q.zeroPoint;
        }
      } catch (_) {}

      _interpreter = interpreter;
      try {
        _isolateInterpreter = await IsolateInterpreter.create(
          address: interpreter.address,
        );
      } catch (_) {
        _isolateInterpreter = null;
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Pkrypt][FaceGrouping] Failed to load MobileFaceNet: $e');
      }
      _modelInitFuture = null;
      return false;
    }
  }

  Uint8List? getCachedAvatar(String clusterId) {
    final existing = _avatarRamCache.remove(clusterId);
    if (existing != null) {
      _avatarRamCache[clusterId] = existing;
    }
    return existing;
  }

  Future<VaultMedia> scanAndGroupMedia({
    required VaultMedia media,
    required Uint8List plainImageBytes,
    String? existingLocalFilePath,
  }) async {
    if (_isDisposed || !_crypto.isUnlocked || !_db.isOpen) return media;
    if (plainImageBytes.isEmpty) return media;

    final modelReady = await _ensureModelLoaded();
    if (!modelReady) return media;

    final uprightJpg = await compute(_prepareUprightJpgIsolate, plainImageBytes);
    if (uprightJpg == null || uprightJpg.isEmpty) {
      final updated = media.copyWith(
        faceClusterIds: const [],
        facesScanned: true,
      );
      await _db.saveMedia(updated);
      return updated;
    }

    File? ephemeralFile;
    try {
      final tempDir = await getTemporaryDirectory();
      final uniqueTag = DateTime.now().microsecondsSinceEpoch;
      ephemeralFile = File(
        '${tempDir.path}${Platform.pathSeparator}vg_face_${media.id}_$uniqueTag.jpg',
      );
      await ephemeralFile.writeAsBytes(uprightJpg, flush: true);

      final inputImage = InputImage.fromFilePath(ephemeralFile.path);
      final detectedFaces = await _faceDetector.processImage(inputImage);

      // Filter unusable faces + deduplicate overlapping detections on the same face
      final usableFaces = _suppressOverlappingFaces(
        detectedFaces.where(_isUsableFace).toList(),
      );

      if (usableFaces.isEmpty) {
        final updated = media.copyWith(
          faceClusterIds: const [],
          facesScanned: true,
        );
        await _db.saveMedia(updated);
        return updated;
      }

      final serializedFaces = usableFaces.map(_serializeFaceBox).toList();
      final croppedFaces = await compute(_cropFacesIsolate, {
        'bytes': uprightJpg,
        'faces': serializedFaces,
        'inputW': _inputW,
        'inputH': _inputH,
      });

      final assignedInThisPhoto = <String>{};

      for (final faceData in croppedFaces) {
        if (_isDisposed || !_crypto.isUnlocked || !_db.isOpen) break;

        final embedding = await _computeDualFaceEmbedding(
          faceData.modelRgbBytes,
          faceData.flippedRgbBytes,
        );
        if (embedding.isEmpty) continue;

        final clusterId = await _matchOrCreateCluster(
          embedding: embedding,
          avatarJpg: faceData.avatarJpg,
          excludeClusterIds: assignedInThisPhoto,
        );
        assignedInThisPhoto.add(clusterId);
      }

      final updated = media.copyWith(
        faceClusterIds: assignedInThisPhoto.toList(),
        facesScanned: true,
      );
      await _db.saveMedia(updated);
      return updated;
    } finally {
      if (ephemeralFile != null && await ephemeralFile.exists()) {
        try {
          await ephemeralFile.delete();
        } catch (_) {}
      }
    }
  }

  /// Non-Maximum Suppression: guarantees one physical face never spawns duplicate boxes.
  List<Face> _suppressOverlappingFaces(List<Face> faces) {
    if (faces.length <= 1) return faces;
    final sorted = List<Face>.from(faces)
      ..sort((a, b) {
        final areaA = a.boundingBox.width * a.boundingBox.height;
        final areaB = b.boundingBox.width * b.boundingBox.height;
        return areaB.compareTo(areaA);
      });

    final kept = <Face>[];
    for (final candidate in sorted) {
      bool overlapsExisting = false;
      for (final existing in kept) {
        if (_boxIoU(candidate.boundingBox, existing.boundingBox) > 0.35) {
          overlapsExisting = true;
          break;
        }
      }
      if (!overlapsExisting) kept.add(candidate);
    }
    return kept;
  }

  double _boxIoU(Rect a, Rect b) {
    final interLeft = math.max<double>(a.left, b.left);
    final interTop = math.max<double>(a.top, b.top);
    final interRight = math.min<double>(a.right, b.right);
    final interBottom = math.min<double>(a.bottom, b.bottom);
    final interW = math.max<double>(0.0, interRight - interLeft);
    final interH = math.max<double>(0.0, interBottom - interTop);
    final interArea = interW * interH;
    if (interArea <= 0.0) return 0.0;
    final unionArea =
        (a.width * a.height) + (b.width * b.height) - interArea;
    return unionArea > 0.0 ? interArea / unionArea : 0.0;
  }

  bool _isUsableFace(Face face) {
    final box = face.boundingBox;
    if (box.width < 44 || box.height < 44) return false;
    final yaw = (face.headEulerAngleY ?? 0.0).abs();
    final pitch = (face.headEulerAngleX ?? 0.0).abs();
    if (yaw > 45.0 || pitch > 38.0) return false;
    return true;
  }

  Map<String, dynamic> _serializeFaceBox(Face face) {
    final box = face.boundingBox;
    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    final nose = face.landmarks[FaceLandmarkType.noseBase]?.position;

    double roll = face.headEulerAngleZ ?? 0.0;
    if (leftEye != null && rightEye != null && leftEye.x != rightEye.x) {
      final imgLeftEye = leftEye.x < rightEye.x ? leftEye : rightEye;
      final imgRightEye = leftEye.x < rightEye.x ? rightEye : leftEye;
      final eyeAngle = math.atan2(
            (imgRightEye.y - imgLeftEye.y).toDouble(),
            (imgRightEye.x - imgLeftEye.x).toDouble(),
          ) *
          180.0 /
          math.pi;
      if (eyeAngle.abs() <= 45.0) {
        roll = eyeAngle;
      }
    }

    return {
      'left': box.left,
      'top': box.top,
      'width': box.width,
      'height': box.height,
      'roll': roll,
      'leftEyeX': leftEye?.x.toDouble(),
      'leftEyeY': leftEye?.y.toDouble(),
      'rightEyeX': rightEye?.x.toDouble(),
      'rightEyeY': rightEye?.y.toDouble(),
      'noseX': nose?.x.toDouble(),
      'noseY': nose?.y.toDouble(),
    };
  }

  /// Runs MobileFaceNet on both original & horizontally flipped crops and
  /// averages their normalized embeddings for higher angle robustness.
  Future<List<double>> _computeDualFaceEmbedding(
    Uint8List rgbBytes,
    Uint8List flippedRgbBytes,
  ) async {
    final embA = await _runSingleEmbedding(rgbBytes);
    if (embA.isEmpty) return const [];

    final embB = await _runSingleEmbedding(flippedRgbBytes);
    if (embB.length != embA.length) return embA;

    final avg = List<double>.generate(
      embA.length,
      (i) => (embA[i] + embB[i]) * 0.5,
    );
    return _l2Normalize(avg);
  }

  Future<List<double>> _runSingleEmbedding(Uint8List rgbBytes) {
    return _runSerialized(() async {
      final interpreter = _interpreter;
      if (_isDisposed || interpreter == null) return const <double>[];

      final expectedLen = _inputH * _inputW * 3;
      if (rgbBytes.length != expectedLen) return const <double>[];

      final Object inputTensorData;
      if (_inputType == TensorType.uint8) {
        inputTensorData = rgbBytes.toList().reshape([1, _inputH, _inputW, 3]);
      } else if (_inputType == TensorType.int8) {
        final int8Input = List<int>.generate(
          expectedLen,
          (i) => rgbBytes[i] - 128,
        );
        inputTensorData = int8Input.reshape([1, _inputH, _inputW, 3]);
      } else {
        final floatInput = List<double>.generate(
          expectedLen,
          (i) => (rgbBytes[i] - 127.5) / 128.0,
        );
        inputTensorData = floatInput.reshape([1, _inputH, _inputW, 3]);
      }

      final isQuantizedOut =
          _outputType == TensorType.uint8 || _outputType == TensorType.int8;
      final Object outputBuffer = isQuantizedOut
          ? List<int>.filled(_outputDim, 0).reshape([1, _outputDim])
          : List<double>.filled(_outputDim, 0.0).reshape([1, _outputDim]);

      if (_isolateInterpreter != null) {
        await _isolateInterpreter!.run(inputTensorData, outputBuffer);
      } else {
        interpreter.run(inputTensorData, outputBuffer);
      }

      final rawRow = (outputBuffer as List)[0] as List;
      final vector = List<double>.generate(rawRow.length, (i) {
        final v = (rawRow[i] as num).toDouble();
        return isQuantizedOut ? (v - _outputZeroPoint) * _outputScale : v;
      });

      return _l2Normalize(vector);
    });
  }

  Future<String> _matchOrCreateCluster({
    required List<double> embedding,
    required Uint8List avatarJpg,
    required Set<String> excludeClusterIds,
  }) async {
    final existingClusters = _db.getAllFaceClusters();
    FaceCluster? bestMatch;
    double bestScore = -1.0;

    for (final cluster in existingClusters) {
      if (excludeClusterIds.contains(cluster.id)) continue;
      if (cluster.embedding.length != embedding.length) continue;
      final score = _cosineSimilarity(cluster.embedding, embedding);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = cluster;
      }
    }

    if (bestMatch != null && bestScore >= _matchThreshold) {
      List<double> nextEmbedding = bestMatch.embedding;
      int nextSamples = bestMatch.sampleCount;

      if (bestScore >= _centroidUpdateThreshold) {
        final w = bestMatch.sampleCount.clamp(1, _maxCentroidWeight);
        final updatedVec = List<double>.generate(
          embedding.length,
          (i) => ((bestMatch!.embedding[i] * w) + embedding[i]) / (w + 1),
        );
        final normalized = _l2Normalize(updatedVec);
        if (normalized.isNotEmpty) {
          nextEmbedding = normalized;
        }
        nextSamples = bestMatch.sampleCount + 1;
      }

      String? avatarPath = bestMatch.avatarPath;
      if (avatarPath == null || !await File(avatarPath).exists()) {
        avatarPath = await _saveEncryptedAvatar(bestMatch.id, avatarJpg);
      }

      final updatedCluster = bestMatch.copyWith(
        embedding: nextEmbedding,
        sampleCount: nextSamples,
        avatarPath: avatarPath,
      );
      await _db.saveFaceCluster(updatedCluster);
      return updatedCluster.id;
    }

    final nextNum = existingClusters.length + 1;
    final newId = 'person_${DateTime.now().microsecondsSinceEpoch}';
    final avatarPath = await _saveEncryptedAvatar(newId, avatarJpg);

    final newCluster = FaceCluster(
      id: newId,
      name: 'Person $nextNum',
      embedding: embedding,
      sampleCount: 1,
      avatarPath: avatarPath,
      createdAt: DateTime.now(),
    );
    await _db.saveFaceCluster(newCluster);
    return newCluster.id;
  }

  /// Post-scan consolidation: merges split sub-groups of the same person
  /// while guaranteeing people who appeared together in the same photo never merge.
  Future<int> consolidateClusters() async {
    if (_isDisposed || !_crypto.isUnlocked || !_db.isOpen) return 0;

    int mergedCount = 0;

    // 1. Remove any orphaned 0-photo clusters first
    final allMedia = _db.getAllMedia();
    final photoCounts = <String, int>{};
    for (final m in allMedia) {
      for (final cid in m.faceClusterIds) {
        photoCounts[cid] = (photoCounts[cid] ?? 0) + 1;
      }
    }
    for (final cluster in _db.getAllFaceClusters()) {
      if ((photoCounts[cluster.id] ?? 0) == 0) {
        await _db.deleteFaceCluster(cluster.id);
        final removed = _avatarRamCache.remove(cluster.id);
        if (removed != null) {
          _currentAvatarRamBytes -= removed.length;
          removed.fillRange(0, removed.length, 0);
        }
        try {
          if (cluster.avatarPath != null && cluster.avatarPath!.isNotEmpty) {
            final f = File(cluster.avatarPath!);
            if (await f.exists()) await f.delete();
          }
        } catch (_) {}
      }
    }

    // 2. Agglomerative merge of highest-similarity pairs with same-photo protection
    while (!_isDisposed && _crypto.isUnlocked && _db.isOpen) {
      final clusters = _db.getAllFaceClusters();
      if (clusters.length < 2) break;

      final coOccur = <String>{};
      final currentCounts = <String, int>{};
      for (final m in _db.getAllMedia()) {
        final ids = m.faceClusterIds;
        for (int i = 0; i < ids.length; i++) {
          currentCounts[ids[i]] = (currentCounts[ids[i]] ?? 0) + 1;
          for (int j = i + 1; j < ids.length; j++) {
            coOccur.add(_pairKey(ids[i], ids[j]));
          }
        }
      }

      FaceCluster? bestA;
      FaceCluster? bestB;
      double bestScore = -1.0;

      for (int i = 0; i < clusters.length; i++) {
        final a = clusters[i];
        if (a.embedding.length != _outputDim) continue;
        for (int j = i + 1; j < clusters.length; j++) {
          final b = clusters[j];
          if (b.embedding.length != _outputDim) continue;
          if (coOccur.contains(_pairKey(a.id, b.id))) continue;

          final score = _cosineSimilarity(a.embedding, b.embedding);
          if (score > bestScore) {
            bestScore = score;
            bestA = a;
            bestB = b;
          }
        }
      }

      if (bestA == null || bestB == null || bestScore < _consolidateThreshold) {
        break;
      }

      // Preserve custom user-renamed cluster; otherwise keep the larger cluster
      final aCustom = !bestA.name.startsWith('Person ');
      final bCustom = !bestB.name.startsWith('Person ');
      final aCount = currentCounts[bestA.id] ?? bestA.sampleCount;
      final bCount = currentCounts[bestB.id] ?? bestB.sampleCount;

      final FaceCluster target;
      final FaceCluster source;
      if (aCustom && !bCustom) {
        target = bestA;
        source = bestB;
      } else if (bCustom && !aCustom) {
        target = bestB;
        source = bestA;
      } else if (aCount >= bCount) {
        target = bestA;
        source = bestB;
      } else {
        target = bestB;
        source = bestA;
      }

      await mergeClusters(
        sourceClusterId: source.id,
        targetClusterId: target.id,
      );
      mergedCount++;
    }

    return mergedCount;
  }

  String _pairKey(String a, String b) =>
      a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

  double _cosineSimilarity(List<double> a, List<double> b) {
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  Future<Directory> _resolveAvatarDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(
      '${docsDir.path}${Platform.pathSeparator}vault_faces',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _saveEncryptedAvatar(
    String clusterId,
    Uint8List avatarJpg,
  ) async {
    final encrypted = await _crypto.encrypt(avatarJpg);
    final dir = await _resolveAvatarDir();
    final file = File('${dir.path}${Platform.pathSeparator}$clusterId.vface');
    await file.writeAsBytes(encrypted, flush: true);
    _putInRamCache(clusterId, avatarJpg);
    return file.path;
  }

  Future<Uint8List?> loadDecryptedAvatar(FaceCluster cluster) async {
    if (!_crypto.isUnlocked) return null;

    final cached = getCachedAvatar(cluster.id);
    if (cached != null) return cached;

    try {
      File file;
      if (cluster.avatarPath != null && cluster.avatarPath!.isNotEmpty) {
        file = File(cluster.avatarPath!);
      } else {
        final dir = await _resolveAvatarDir();
        file = File('${dir.path}${Platform.pathSeparator}${cluster.id}.vface');
      }

      if (!await file.exists()) return null;
      final encBytes = await file.readAsBytes();
      if (encBytes.isEmpty) return null;

      final plain = await _crypto.decrypt(encBytes);
      _putInRamCache(cluster.id, plain);
      return plain;
    } catch (_) {
      return null;
    }
  }

  Future<void> renameCluster(String clusterId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final cluster = _db.getFaceCluster(clusterId);
    if (cluster == null) return;
    await _db.saveFaceCluster(cluster.copyWith(name: trimmed));
  }

  Future<void> mergeClusters({
    required String sourceClusterId,
    required String targetClusterId,
  }) async {
    if (sourceClusterId == targetClusterId) return;
    final source = _db.getFaceCluster(sourceClusterId);
    final target = _db.getFaceCluster(targetClusterId);
    if (source == null || target == null) return;

    final affectedMedia = _db.getMediaForFaceCluster(sourceClusterId);
    for (final media in affectedMedia) {
      final ids = media.faceClusterIds
          .where((id) => id != sourceClusterId)
          .toSet()
        ..add(targetClusterId);
      await _db.saveMedia(media.copyWith(faceClusterIds: ids.toList()));
    }

    List<double> mergedEmbedding = target.embedding;
    if (source.embedding.length == target.embedding.length &&
        target.embedding.isNotEmpty) {
      final totalSamples = source.sampleCount + target.sampleCount;
      final weighted = List<double>.generate(
        target.embedding.length,
        (i) =>
            ((target.embedding[i] * target.sampleCount) +
                (source.embedding[i] * source.sampleCount)) /
            totalSamples,
      );
      final normalized = _l2Normalize(weighted);
      if (normalized.isNotEmpty) {
        mergedEmbedding = normalized;
      }
    }

    await _db.saveFaceCluster(
      target.copyWith(
        embedding: mergedEmbedding,
        sampleCount: target.sampleCount + source.sampleCount,
      ),
    );

    await _db.deleteFaceCluster(sourceClusterId);
    final removed = _avatarRamCache.remove(sourceClusterId);
    if (removed != null) {
      _currentAvatarRamBytes -= removed.length;
      removed.fillRange(0, removed.length, 0);
    }
    try {
      if (source.avatarPath != null && source.avatarPath!.isNotEmpty) {
        final f = File(source.avatarPath!);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  void _putInRamCache(String clusterId, Uint8List bytes) {
    if (bytes.length > _maxAvatarRamBytes) return;
    final previous = _avatarRamCache.remove(clusterId);
    if (previous != null) {
      _currentAvatarRamBytes -= previous.length;
    }

    while (_currentAvatarRamBytes + bytes.length > _maxAvatarRamBytes &&
        _avatarRamCache.isNotEmpty) {
      final oldest = _avatarRamCache.keys.first;
      final evicted = _avatarRamCache.remove(oldest)!;
      _currentAvatarRamBytes -= evicted.length;
      evicted.fillRange(0, evicted.length, 0);
    }

    _avatarRamCache[clusterId] = bytes;
    _currentAvatarRamBytes += bytes.length;
  }

  void clearRamCache() {
    for (final bytes in _avatarRamCache.values) {
      bytes.fillRange(0, bytes.length, 0);
    }
    _avatarRamCache.clear();
    _currentAvatarRamBytes = 0;
  }

  Future<void> wipeAllAvatars() async {
    clearRamCache();
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${docsDir.path}${Platform.pathSeparator}vault_faces',
      );
      if (!await dir.exists()) return;
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> dispose() async {
    _isDisposed = true;
    clearRamCache();
    try {
      await _inferenceQueue;
    } catch (_) {}
    await _detector?.close();
    _detector = null;
    await _isolateInterpreter?.close();
    _isolateInterpreter = null;
    _interpreter?.close();
    _interpreter = null;
    _modelInitFuture = null;
  }
}