import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'colors/appcolor.dart';
import 'detector_view.dart';
import 'profile.dart';
import 'painters/barcode_detector_painter.dart';
import 'history.dart';
import 'result_qr.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:sensors_plus/sensors_plus.dart';

class BarcodeScannerView extends StatefulWidget {
  const BarcodeScannerView({super.key});

  @override
  State createState() => _BarcodeScannerViewState();
}

enum QRCodeState { waiting, scanning, successful }

class _BarcodeScannerViewState extends State<BarcodeScannerView> {
  final BarcodeScanner _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.qrCode]);
  bool _canProcess = true;
  bool _isBusy = false;
  CustomPaint? _customPaint;
  String? _text;
  CameraLensDirection _cameraLensDirection = CameraLensDirection.back;
  double _barcodeSize = 0;
  CameraController? _cameraController;
  Size? _cameraSize;
  Timer? _captureTimer;
  Timer? _resetZoomTimer;
  bool _isCapturing = false;
  bool _isCameraInitialized = false;
  double lastX = 0, lastY = 0, lastZ = 0;
  double shakeThreshold = 15.0;
  bool isShaking = false;
  Uint8List? _croppedImageBytes;
  bool isDialogVisible = false;
  double currentZoomLevel = 1.0;
  DateTime? _lastQRCodeDetectedTime;
  bool isZooming = false;
  int? _qrStatus;
  QRCodeState _qrCodeState = QRCodeState.waiting;
  String str3 = " ";
  bool _isReinitializing = false;
  StreamSubscription? _accelerometerSubscription;
  bool _isLoading = false; // Track loading state
  bool _cameraPause=false;
  late BuildContext loadingDialogContext; // capture loading dialog context
  bool _isButtonDisabled = false;


  @override
  void initState() {
    super.initState();
    _resetState();
    _initializeCamera();
    _startResetZoomTimer();
    _startAccelerometerListener();
  }

  void _resetState() {
    _canProcess = true;
    _isBusy = false;
    _customPaint = null;
    _text = null;
    _barcodeSize = 0;
    _isCapturing = false;
    _isCameraInitialized = false;
    currentZoomLevel = 1.0;
    isZooming = false;
    _qrCodeState = QRCodeState.waiting;
    _isLoading = false;
    _cameraPause=false;
  }

  Future<void> _initializeCamera() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await _disposeCamera();
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        _cameraController = CameraController(
          cameras.first,
          ResolutionPreset.high,
          enableAudio: false,
        );
        await _cameraController!.initialize();
        await _cameraController!.setFlashMode(FlashMode.off);
        await _cameraController!.setExposureMode(ExposureMode.locked);
        try {
          await _cameraController!.setFocusMode(FocusMode.auto);
        } catch (e) {
          if (kDebugMode) print("Auto focus is not supported on this camera: $e");
        }
        if (mounted) {
          setState(() {
            _isCameraInitialized = true;
            _isLoading = false;
          });
        }
      } else {
        if (kDebugMode) print("No cameras found");
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (kDebugMode) print('Error initializing camera: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _disposeCamera() async {
    if (_cameraController != null) {
      await _cameraController!.dispose();
      _cameraController = null;
    }
  }

  void _startAccelerometerListener() {
    final List<double> deltaXHistory = [];
    final List<double> deltaYHistory = [];
    final List<double> deltaZHistory = [];
    const int smoothingWindow = 15;
    const double stabilityThreshold = 1.5;

    _accelerometerSubscription = accelerometerEvents.listen((AccelerometerEvent event) {
      if (!mounted) return;
      final deltaX = (event.x - lastX).abs();
      final deltaY = (event.y - lastY).abs();
      final deltaZ = (event.z - lastZ).abs();
      deltaXHistory.add(deltaX);
      deltaYHistory.add(deltaY);
      deltaZHistory.add(deltaZ);
      if (deltaXHistory.length > smoothingWindow) {
        deltaXHistory.removeAt(0);
        deltaYHistory.removeAt(0);
        deltaZHistory.removeAt(0);
      }
      final avgDeltaX = deltaXHistory.reduce((a, b) => a + b) / deltaXHistory.length;
      final avgDeltaY = deltaYHistory.reduce((a, b) => a + b) / deltaYHistory.length;
      final avgDeltaZ = deltaZHistory.reduce((a, b) => a + b) / deltaZHistory.length;
      final isCurrentlyShaking =
          avgDeltaX > shakeThreshold || avgDeltaY > shakeThreshold || avgDeltaZ > shakeThreshold;
      if (mounted) {
        setState(() {
          if (isCurrentlyShaking != isShaking) {
            isShaking = isCurrentlyShaking;
            if (!isShaking) {
              Future.delayed(const Duration(milliseconds: 500), () {
                if (!isShaking && mounted) {
                  setState(() {
                    _checkStabilityBeforeResuming();
                  });
                }
              });
            }
          }
        });
      }
      lastX = event.x;
      lastY = event.y;
      lastZ = event.z;
    });
  }

  void _checkStabilityBeforeResuming() async {
    if (isShaking) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!isShaking && mounted) {
        setState(() {
          isShaking = false;
        });
      }
    }
  }

  Future<void> _adjustZoom(double barcodeSize, Rect barcodeBoundingBox, Size screenSize) async {
    if (barcodeSize >= 8000 || isShaking) return;
    double targetZoomLevel = 5.0 - ((barcodeSize / 125) * 0.0625);
    targetZoomLevel = targetZoomLevel.clamp(1.5, 4.0);
    bool nearEdge = barcodeBoundingBox.left < 50 ||
        barcodeBoundingBox.right > (screenSize.width - 50) ||
        barcodeBoundingBox.top < 50 ||
        barcodeBoundingBox.bottom > (screenSize.height - 50);
    if (nearEdge) {
      targetZoomLevel = targetZoomLevel.clamp(1.5, 3.0);
    }
    if (currentZoomLevel >= targetZoomLevel) return;
    setState(() {
      isZooming = true;
    });
    await _smoothZoomTo(targetZoomLevel, screenSize);
    await Future.delayed(const Duration(milliseconds: 750));
    setState(() {
      isZooming = false;
    });
  }

  Future<void> _smoothZoomTo(double targetZoomLevel, Size screenSize, {Duration duration = const Duration(milliseconds: 400)}) async {
    int steps = (duration.inMilliseconds / 16).round();
    double zoomIncrement = (targetZoomLevel - currentZoomLevel) / steps;
    for (int i = 0; i < steps; i++) {
      currentZoomLevel += zoomIncrement;
      currentZoomLevel = currentZoomLevel.clamp(1.0, 5.0);
      if (currentZoomLevel >= targetZoomLevel) {
        currentZoomLevel = targetZoomLevel;
        break;
      }
      if (isShaking) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }
      await _cameraController!.setZoomLevel(currentZoomLevel);
      await Future.delayed(const Duration(milliseconds: 16));
    }
    await _cameraController!.setZoomLevel(currentZoomLevel);
  }

  void showTopSnackbar(BuildContext context, String message) {
    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 10,
        left: 20,
        right: 20,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black, fontSize: 16),
            ),
          ),
        ),
      ),
    );
    overlay.insert(overlayEntry);
    Future.delayed(const Duration(seconds: 1), () {
      overlayEntry.remove();
    });
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _resetZoomTimer?.cancel();
    _canProcess = false;
    _cameraPause=false;
    _barcodeScanner.close();
    _disposeCamera();
    _accelerometerSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            _isCameraInitialized
                ? DetectorView(
              title: 'Barcode Scanner',
              customPaint: _customPaint,
              text: _text,
              onImage: (inputImage) {
                if (!isDialogVisible) {
                  _processImage(inputImage, screenSize);
                }
              },
              initialCameraLensDirection: _cameraLensDirection,
              onCameraLensDirectionChanged: (value) =>
                  setState(() => _cameraLensDirection = value),
              qrCodeState: _qrCodeState,
            )
                : const Center(child: CircularProgressIndicator()),
            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(),
              ),
          ],
        ),
      ),
      bottomNavigationBar: BottomAppBar(
        color: Colors.white,
        child: Container(
          height: 70,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              GestureDetector(
                onTap: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (context) => HomePage()),
                        (route) => false,
                  );
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FontAwesomeIcons.clock),
                    Text(
                      "History",
                      style: TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0092B4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
                    onPressed: () {},
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    PageRouteBuilder(
                      pageBuilder: (context, animation, secondaryAnimation) => ProfileApp(),
                      transitionsBuilder: (context, animation, secondaryAnimation, child) {
                        const begin = Offset(1.0, 0.0);
                        const end = Offset.zero;
                        const curve = Curves.easeInOut;
                        var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                        var offsetAnimation = animation.drive(tween);
                        return SlideTransition(position: offsetAnimation, child: child);
                      },
                    ),
                        (route) => false,
                  );
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FontAwesomeIcons.link),
                    Text(
                      "Connect",
                      style: TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _processImage(InputImage inputImage, Size screenSize) async {
    if (!_canProcess || _isBusy || _isCapturing||_cameraPause) return;
    _isBusy = true;
    setState(() {
      _text = '';
    });
    try {
      final barcodes = await _barcodeScanner.processImage(inputImage);
      if (barcodes.isNotEmpty) {
        _cancelResetZoomTimer();
        _lastQRCodeDetectedTime = DateTime.now();
      }
      if (inputImage.metadata?.size != null && inputImage.metadata?.rotation != null) {
        final painter = BarcodeDetectorPainter(
          barcodes,
          inputImage.metadata!.size,
          inputImage.metadata!.rotation,
          _cameraLensDirection,
              (size) {
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _barcodeSize = size;
                });
                final barcode = barcodes.first;
                final barcodeRect = barcode.boundingBox;
                str3 = barcode.rawValue!;
                if (_barcodeSize < 10000) {
                  _adjustZoom(size, barcodeRect, screenSize);
                } else if (_barcodeSize > 10000 && _barcodeSize < 40000) {
                  if (!_isCapturing && (_captureTimer == null || !_captureTimer!.isActive)) {
                    if (mounted) {
                      setState(() {
                        _qrCodeState = QRCodeState.successful;
                      });
                    }
                    _startCaptureTimer(barcodeRect);
                  }
                }
              }
            });
          },
          _cameraSize ?? Size.zero,
        );
        _customPaint = CustomPaint(painter: painter);
        if (barcodes.isNotEmpty) {
          setState(() {
            _qrCodeState = QRCodeState.scanning;
          });
        }
      }
    } catch (e) {
      if (kDebugMode) print('Error processing image: $e');
    } finally {
      _isBusy = false;
      _checkQRCodeTimeout();
    }
  }

  void _checkQRCodeTimeout() {
    if (_lastQRCodeDetectedTime != null &&
        DateTime.now().difference(_lastQRCodeDetectedTime!).inMinutes >= 3) {
      _resetZoomLevel1();
    }
  }

  void _resetZoomLevel1() {
    if (currentZoomLevel != 1.0) {
      currentZoomLevel = 1.0;
      _cameraController?.setZoomLevel(currentZoomLevel);
    }
  }

  void _cancelResetZoomTimer() {
    _resetZoomTimer?.cancel();
    _resetZoomTimer = Timer(Duration(minutes: 1), _resetZoomLevel);
  }

  void _startResetZoomTimer() {
    _resetZoomTimer = Timer.periodic(
      const Duration(seconds: 10),
          (_) {
        if (!_isCapturing) {
          _resetZoomLevel();
        }
      },
    );
  }

  void _resetZoomLevel() async {
    setState(() {
      currentZoomLevel = 1.0;
    });
    if (_cameraController != null) {
      await _cameraController!.setZoomLevel(currentZoomLevel);
    }
  }

  void _startScanning() {
    if (_isLoading || _isReinitializing) return;

    setState(() {
      _isLoading = true;
      _isCapturing = false;
      isDialogVisible = false;
      isZooming = false;
      _isReinitializing = true;
      _isButtonDisabled = false;
    });

    // Cancel all ongoing operations
    _captureTimer?.cancel();
    _resetZoomTimer?.cancel();
    _resetState();

    _reinitializeCamera().then((_) {
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _isReinitializing = false;
          _isLoading = false;
          _cameraPause = false;
          _isButtonDisabled = false;
        });
      }
    }).catchError((error) {
      if (mounted) {
        setState(() {
          _isReinitializing = false;
          _isLoading = false;
          _cameraPause = false;
          _isButtonDisabled = false;
        });
      }

      if (error is TimeoutException) {
        _showRetryDialog("Camera timed out while initializing. Please try again.");
      } else if (error.toString().contains('No cameras found')) {
        _showErrorDialog("No camera available on this device.");
      } else {
        _showRetryDialog("Failed to initialize camera. Please try again.");
      }
    });
  }

  Future<void> _reinitializeCamera() async {
    try {
      if (_cameraController != null) {
        await _cameraController!.dispose();
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception("No cameras found");
      }

      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!
          .initialize()
          .timeout(const Duration(seconds: 10));

      await _cameraController!.setFlashMode(FlashMode.off);
      await _cameraController!.setExposureMode(ExposureMode.locked);

      try {
        await _cameraController!.setFocusMode(FocusMode.auto);
      } catch (e) {
        if (kDebugMode) {
          print("Auto focus not supported: $e");
        }
      }
    } catch (e) {
      throw e; // Always rethrow for _startScanning to handle
    }
  }

  void _showRetryDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('Camera Error'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('Retry'),
              onPressed: () {
                Navigator.of(context).pop(); // Close the dialog
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const BarcodeScannerView()),
                      (route) => false,
                );
              },
            ),
          ],
        );
      },
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('Camera Error'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop(); // Close the dialog
                _navigateBackToScanner();
              },
            ),
          ],
        );
      },
    );
  }



  Future<void> _captureImage(Rect? barcodeRect) async {
    if (_isCapturing || _cameraController == null || !_cameraController!.value.isInitialized || isZooming || isShaking) {
      return;
    }
    try {
      if (isShaking) {
        showTopSnackbar(context, "Waiting for camera to stabilize...");
        _checkStabilityBeforeResuming();
      }
      setState(() {
        _customPaint = null;
      });
      if (isZooming) {
        showTopSnackbar(context, "Waiting for zoom to stabilize...");
        return;
      }
      if (_barcodeSize > 42000) {
        if (mounted) {
          _cameraController?.setZoomLevel(currentZoomLevel - 0.5);
          showTopSnackbar(context, "Move your mobile slightly away from the QR code.");
        }
        return;
      }
      _setFixedFocus(barcodeRect);
      final XFile image = await _cameraController!.takePicture();
      final Uint8List imageBytes = await image.readAsBytes();
      final String tempPath = (await getTemporaryDirectory()).path;
      final File imageFile = File('$tempPath/temp_image.png');
      await imageFile.writeAsBytes(imageBytes);
      final inputImage = InputImage.fromFilePath(imageFile.path);
      final List barcodes = await _barcodeScanner.processImage(inputImage);
      if (barcodes.isEmpty && _isCapturing) {
        if (mounted) {
          showTopSnackbar(context, "QR code not detected. Adjust your position.");
        }
        setState(() {
          _isCapturing = false;
          _barcodeSize = 0;
        });
        return;
      }
      if (mounted) {
        final Barcode qrCode = barcodes.first;
        final Rect boundingBox = qrCode.boundingBox;
        final img.Image? originalImage = img.decodeImage(imageBytes);
        if (originalImage != null) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext dialogContext) {
              loadingDialogContext = dialogContext; // capture
              return AlertDialog(
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text("Cropping QR Code..."),
                  ],
                ),
              );
            },
          );
          try {
            _cameraController?.pausePreview();
            if(mounted){
              setState(() {
                _cameraPause=false;
              });
            }
            if (!isDialogVisible) {
              await Future.delayed(const Duration(seconds: 1));
            }
            final int cropX = boundingBox.left.toInt();
            final int cropY = boundingBox.top.toInt();
            final int cropWidth = boundingBox.width.toInt();
            final int cropHeight = boundingBox.height.toInt();
            final int adjustedX = cropX.clamp(0, originalImage.width - cropWidth);
            final int adjustedY = cropY.clamp(0, originalImage.height - cropHeight);
            final img.Image croppedImage = img.copyCrop(
              originalImage,
              x: adjustedX - 35,
              y: adjustedY - 35,
              width: cropWidth + 70,
              height: cropHeight + 70,
            );
            final img.Image resizedImage = img.copyResize(croppedImage, width: 500, height: 500);
            _croppedImageBytes = Uint8List.fromList(img.encodePng(resizedImage));
          } catch (e) {
            if (kDebugMode) print('Error during cropping: $e');
            // Close the loading dialog safely
            if (Navigator.canPop(loadingDialogContext)) {
              Navigator.pop(loadingDialogContext);
            }

            showTopSnackbar(context, "Failed to crop the QR code. Please try again.");
            _startScanning();
            return;
          }
          // Close the loading dialog safely
          if (Navigator.canPop(loadingDialogContext)) {
            Navigator.pop(loadingDialogContext);
          }

          if (_croppedImageBytes != null && !isDialogVisible) {
            setState(() {
              isDialogVisible = true;
            });
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (context) {
                return Dialog(
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 5,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(_croppedImageBytes!),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    spreadRadius: 1,
                                    blurRadius: 4,
                                    offset: const Offset(2, 2),
                                  ),
                                ],
                              ),
                              child: ElevatedButton(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  sendImageToApi(_croppedImageBytes!);
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: Colors.black,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  elevation: 0,
                                ),
                                child: const Text("OK"),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    spreadRadius: 1,
                                    blurRadius: 4,
                                    offset: const Offset(2, 2),
                                  ),
                                ],
                              ),
                              child: ElevatedButton.icon(
                                onPressed: _isButtonDisabled ? null : () {
                                  setState(() {
                                    _isButtonDisabled = true; // Disable button immediately
                                  });
                                  Navigator.of(context).pop();
                                  _startScanning();
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: Colors.black,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  elevation: 0,
                                ),
                                icon: const Icon(Icons.camera_alt, color: Color(0xFF0092B4)),
                                label: const Text("Scan Again"),
                              ),

                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ).then((_) {
              if (mounted) {
                setState(() {
                  isDialogVisible = false;
                });
              }
            });
          }
        }
      }
    } catch (e) {
      if (kDebugMode) print('Error capturing image: $e');
    } finally {
      setState(() {
        _isCapturing = false;
      });
    }
  }

  Future<void> _setFixedFocus(Rect? barcodeRect) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized||_cameraPause) {
      if (kDebugMode) print('Camera controller not initialized or null.');
      return;
    }
    try {
      Offset focusPoint = const Offset(0.5, 0.5);
      if (barcodeRect != null) {
        final previewSize = _cameraController!.value.previewSize;
        if (previewSize != null) {
          final centerX = (barcodeRect.left + barcodeRect.right) / 2;
          final centerY = (barcodeRect.top + barcodeRect.bottom) / 2;
          final normalizedX = centerX / previewSize.width;
          final normalizedY = centerY / previewSize.height;
          focusPoint = Offset(
            normalizedX.clamp(0.0, 1.0),
            normalizedY.clamp(0.0, 1.0),
          );
          if (kDebugMode) print('Calculated focus point: $focusPoint');
        } else {
          if (kDebugMode) print('Preview size is null. Cannot calculate focus point.');
          return;
        }
      }
      _cameraController!.setFocusMode(FocusMode.auto);
      _cameraController!.setFocusPoint(focusPoint);
      await Future.delayed(const Duration(milliseconds: 300));
      if (kDebugMode) print('Focus set successfully to: $focusPoint');
      await Future.delayed(const Duration(milliseconds: 300));
      try {
        await _cameraController!.setFocusPoint(focusPoint);
      } catch (e) {
        if (kDebugMode) print('Retry focus failed: $e');
      }
    } catch (e) {
      if (kDebugMode) print('Error setting fixed focus: $e');
    }
  }

  void _startCaptureTimer(Rect? barcodeRect) {
    _captureTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_isCapturing || isZooming || isShaking||_cameraPause) return;
      if (_barcodeSize > 42000) {
        if (mounted) {
          showTopSnackbar(context, "Adjust your distance from the QR code for better clarity.");
        }
        return;
      }
      _setFixedFocus(barcodeRect);
      _captureImage(barcodeRect);
    });
  }

  Future<void> sendImageToApi(Uint8List imageBytes) async {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierDismissible: false,
      pageBuilder: (context, animation, secondaryAnimation) => FadeTransition(
        opacity: animation,
        child: Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text("Fetching...", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    ));
    var uuid = Uuid();
    String scndVal = str3;
    String latLong = await _getCurrentLocation();
    String mobiOs = await _getDeviceOS();
    String uniqId = uuid.v4();
    String scndDtm = DateFormat("yyyy-MM-dd HH-mm-ss").format(DateTime.now());
    String origIp = await _getIpAddress();
    print('${scndVal}--${latLong}--${mobiOs}---${uniqId}--${origIp}');
    final url = Uri.parse('https://scnapi.secuqr.com/api/vldqr');
    final request = http.MultipartRequest('POST', url);
    request.headers.addAll({
      "X-API-Key": "SECUQR",
    });
    request.fields.addAll({
      "scnd_val": str3,
      "lat_long": latLong,
      "mobi_os": mobiOs,
      "uniq_id": uniqId,
      "email_id": "cmgxieavqh@SecuQR.com",
      "scnd_dtm": scndDtm,
      "orig_ip": origIp,
      "usr_fone": "+917658483796",
    });
    request.files.add(
      http.MultipartFile.fromBytes(
        'scnd_img',
        imageBytes,
        filename: 'scanned_image.png',
        contentType: MediaType('image', 'png'),
      ),
    );
    try {
      final response = await request.send();
      final responseData = await http.Response.fromStream(response);
      Navigator.of(context).pop();
      if (responseData.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(responseData.body);
        final int status = data['status'] ?? -1;
        final Uint8List? binObjBytes = data['binobj'] != null
            ? base64Decode(data['binobj'])
            : null;

        String statusLabel;
        if (status == 1) {
          statusLabel = "Genuine";
        } else if (status == 0) {
          statusLabel = "Counterfeit";
        } else {
          statusLabel = "Error";
        }
        setState(() {
          _qrStatus = status;
        });
        if (binObjBytes != null) {
          await saveScanToSharedPreferences(
              statusLabel, scndDtm, binObjBytes);
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext context) {
              return _buildResultContentDialog(context, binObjBytes);
            },
          );
        } else {
          showTopSnackbar(context, "Network Issues");
          _startScanning();
          //_navigateBackToScanner();
        }
      } else {
        showTopSnackbar(context, "Network Issues");
        _startScanning();
        // _navigateBackToScanner();
      }
    } catch (e) {
      print('API Error: $e');
      showTopSnackbar(context, "Network Issues");
      Navigator.of(context).pop();
      _startScanning();
      //_navigateBackToScanner();
    }
  }

  Future<String> _getCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      return "${position.latitude}, ${position.longitude}";
    } catch (e) {
      return "";
    }
  }

  Future<String> _getDeviceOS() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      return "Android ${androidInfo.version.release}";
    } else if (Platform.isIOS) {
      IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
      return "iOS ${iosInfo.systemVersion}";
    }
    return "Unknown";
  }

  Future<String> _getIpAddress() async {
    try {
      final response = await http.get(Uri.parse('https://api64.ipify.org?format=json'));
      if (response.statusCode == 200) {
        return json.decode(response.body)['ip'] ?? "";
      }
    } catch (e) {
      print("IP fetch error: $e");
    }
    return "";
  }

  Widget _buildResultContentDialog(BuildContext context, Uint8List? qrImageBytes) {
    Color resultColor;
    IconData resultIcon;
    IconData resultIcon1 = FontAwesomeIcons.shield;
    String resultTitle;
    String resultMessage1;
    switch (_qrStatus) {
      case 1:
        resultColor = Colors.green;
        resultIcon = Icons.check_circle;
        resultTitle = "Genuine";
        resultMessage1 = "Your Product is Secured & Authenticated by SecuQR";
        break;
      case 0:
        resultColor = Colors.red;
        resultIcon = Icons.cancel;
        resultTitle = "Counterfeit";
        resultMessage1 = "Not an authenticated\n\tSecuQR product";
        break;
      default:
        resultColor = Colors.orange;
        resultIcon = Icons.error;
        resultTitle = "Error";
        resultMessage1 = "\tThis product is not\nRecognized by SecuQR";
        break;
    }
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.all(16),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Icon(resultIcon1, size: 60, color: resultColor),
                  Icon(resultIcon, color: Colors.white, size: 30),
                ],
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  resultTitle,
                  textAlign: TextAlign.left,
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: resultColor),
                ),
              ),
            ],
          ),
          SizedBox(height: 14),
          if (qrImageBytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                qrImageBytes,
                height: 200,
                width: 200,
                fit: BoxFit.cover,
              ),
            ),
          SizedBox(height: 24),
          Text(
            resultMessage1,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
          SizedBox(height: 24),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 150,
                child: ElevatedButton(
                  onPressed: () {},
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Color(0xFF0092B4),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                  ),
                  child: Text("Product Details", style: TextStyle(fontSize: 15)),
                ),
              ),
              SizedBox(height: 12),
              SizedBox(
                width: 150,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    setState(() {
                      isDialogVisible = false;
                    });
                    _startScanning();
                  },
                  icon: Icon(Icons.camera_alt_outlined, color: Colors.black),
                  label: Text("Scan Again", style: TextStyle(fontSize: 15)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade200,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                  ),
                ),
              ),
              SizedBox(height: 12),
            ],
          ),
        ],
      ),
    );
  }

  void _navigateBackToScanner() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const BarcodeScannerView()),
          (route) => false,
    );
  }
  Future<void> saveScanToSharedPreferences(
      String status, String dateTime, Uint8List image) async {
    final prefs = await SharedPreferences.getInstance();
    final historyList = prefs.getStringList('scanHistory') ?? [];

    ScanHistoryItem item =
    ScanHistoryItem(status: status, dateTime: dateTime, image: image);
    historyList.add(jsonEncode(item.toJson()));

    await prefs.setStringList('scanHistory', historyList);
  }
}

class ScanHistoryItem {
  final String status;
  final String dateTime;
  final Uint8List image;

  ScanHistoryItem(
      {required this.status, required this.dateTime, required this.image});

  Map<String, dynamic> toJson() => {
    'status': status,
    'dateTime': dateTime,
    'image': base64Encode(image),
  };

  factory ScanHistoryItem.fromJson(Map<String, dynamic> json) {
    return ScanHistoryItem(
      status: json['status'],
      dateTime: json['dateTime'],
      image: base64Decode(json['image']),
    );
  }
}