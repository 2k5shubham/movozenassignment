import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:rtmp_streaming/camera.dart';

const String ROLL_NO = 'BTECH3500123';
const String FRONT_URL =
    'rtmp://15.207.177.194:1936/hackathon/${ROLL_NO}_front';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const DashcamApp());
}

class DashcamApp extends StatelessWidget {
  const DashcamApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pocket Dashcam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.red,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const DashcamScreen(),
    );
  }
}

class DashcamScreen extends StatefulWidget {
  const DashcamScreen({super.key});
  @override
  State<DashcamScreen> createState() => _DashcamScreenState();
}

class _DashcamScreenState extends State<DashcamScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isInitialized = false;
  bool _isStreaming = false;
  bool _isConnected = false;
  String _status = 'Initializing...';
  Color _statusColor = Colors.grey;
  DateTime? _startTime;
  Timer? _uptimeTimer;
  String _uptime = '00:00';
  int _reconnectAttempts = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uptimeTimer?.cancel();
    _controller?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Keep streaming when app goes to background
    if (state == AppLifecycleState.resumed) {
      if (!_isInitialized) _initCamera();
    }
  }

  Future<void> _initCamera() async {
    // Request permissions
    final camStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();

    if (!camStatus.isGranted || !micStatus.isGranted) {
      setState(() {
        _status = 'Permissions denied!';
        _statusColor = Colors.red;
      });
      return;
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _status = 'No camera found!';
          _statusColor = Colors.red;
        });
        return;
      }

      // Use back camera (index 0 is typically back camera on Android)
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        ResolutionPreset.high,
        enableAudio: true,
      );

      await _controller!.initialize(backCamera);

      // Configure encoder settings
      await _controller!.setAudioSettings(128 * 1024); // 128kbps AAC
      await _controller!.setVideoSettings(bitrate: 1500 * 1024); // 1.5Mbps
      await _controller!.setFrameRate(25);

      if (Platform.isAndroid) {
        await _controller!.setRtmpShouldSendPings(true);
      }

      await _controller!.prepareForVideoStreaming();

      if (mounted) {
        setState(() {
          _isInitialized = true;
          _status = 'Ready';
          _statusColor = Colors.green;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Camera error: $e';
          _statusColor = Colors.red;
        });
      }
    }
  }

  Future<void> _startStream() async {
    if (_controller == null || !_isInitialized) return;

    setState(() {
      _isStreaming = true;
      _reconnectAttempts = 0;
      _status = 'Connecting...';
      _statusColor = Colors.yellow;
      _startTime = DateTime.now();
    });

    await _doStream();
  }

  Future<void> _doStream() async {
    try {
      await _controller!.startVideoStreaming(
        FRONT_URL,
        protocol: StreamingProtocol.rtmp,
      );
      if (mounted) {
        setState(() {
          _status = 'LIVE';
          _statusColor = Colors.red;
          _isConnected = true;
        });
        _startUptimeTimer();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Reconnecting... ($e)';
          _statusColor = Colors.orange;
          _isConnected = false;
        });
        if (_isStreaming && _reconnectAttempts < 20) {
          _reconnectAttempts++;
          Future.delayed(const Duration(seconds: 3), () {
            if (_isStreaming && mounted) _doStream();
          });
        }
      }
    }
  }

  Future<void> _stopStream() async {
    _uptimeTimer?.cancel();
    _reconnectAttempts = 99;
    try {
      await _controller?.stopStreaming();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _isStreaming = false;
        _isConnected = false;
        _status = 'Stopped';
        _statusColor = Colors.grey;
        _uptime = '00:00';
        _startTime = null;
      });
    }
  }

  void _startUptimeTimer() {
    _startTime ??= DateTime.now();
    _uptimeTimer?.cancel();
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_startTime != null && mounted) {
        final diff = DateTime.now().difference(_startTime!);
        final m = diff.inMinutes.toString().padLeft(2, '0');
        final s = (diff.inSeconds % 60).toString().padLeft(2, '0');
        setState(() => _uptime = '$m:$s');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Full screen camera preview
          if (_isInitialized && _controller != null)
            SizedBox.expand(
              child: CameraPreview(_controller!),
            ),

          // Loading overlay
          if (!_isInitialized)
            Container(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.red),
                    const SizedBox(height: 20),
                    Text(
                      _status,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),

          // Top HUD Bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.85),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Roll number
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'POCKET DASHCAM',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 9,
                          letterSpacing: 2,
                        ),
                      ),
                      Text(
                        ROLL_NO,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),

                  // Status badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: _statusColor.withOpacity(0.15),
                      border:
                          Border.all(color: _statusColor, width: 1.5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isConnected)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                        Text(
                          _status,
                          style: TextStyle(
                            color: _statusColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Uptime counter
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'UPTIME',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 9,
                          letterSpacing: 2,
                        ),
                      ),
                      Text(
                        _uptime,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Bottom Controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withOpacity(0.9),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      FRONT_URL,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.35),
                        fontSize: 9,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 16),

                  // Main stream button
                  GestureDetector(
                    onTap: _isInitialized
                        ? (_isStreaming ? _stopStream : _startStream)
                        : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isStreaming ? Colors.red : Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: (_isStreaming ? Colors.red : Colors.white)
                                .withOpacity(0.5),
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: Icon(
                        _isStreaming
                            ? Icons.stop_rounded
                            : Icons.videocam_rounded,
                        color: _isStreaming ? Colors.white : Colors.black,
                        size: 34,
                      ),
                    ),
                  ),

                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
