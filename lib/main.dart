import 'dart:async';
import 'dart:io'; // For Socket
import 'dart:typed_data'; // For Uint8List
// import 'package.flutter/foundation.dart'; // For kIsWeb
// import 'package.flutter/material.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';

// Define the sample rate and number of channels expected by your server
// Common values: 16000, 44100, 48000
const int serverSampleRate = 16000;
// 1 for mono, 2 for stereo
const int serverNumChannels = 1;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Streamer (flutter_sound)',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const VoiceStreamerPage(),
    );
  }
}

class VoiceStreamerPage extends StatefulWidget {
  const VoiceStreamerPage({super.key});

  @override
  State<VoiceStreamerPage> createState() => _VoiceStreamerPageState();
}

class _VoiceStreamerPageState extends State<VoiceStreamerPage> {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  StreamSubscription? _recorderSubscription;
  StreamSubscription? _socketSubscription;
  Socket? _socket;

  bool _isStreaming = false;
  bool _isRecorderInitialized = false;
  String _statusText = "Enter Server IP/Port and press Start";

  final TextEditingController _ipController =
  TextEditingController(text: "192.168.1.53"); // Default IP
  final TextEditingController _portController =
  TextEditingController(text: "8080"); // Default Port

  @override
  void initState() {
    super.initState();
    _openRecorderSession().then((_) {
      setState(() {
        _isRecorderInitialized = true;
        _statusText = "Recorder ready. Enter Server IP/Port and press Start.";
      });
    }).catchError((err) {
      setState(() {
        _statusText = "Recorder Init Error: $err";
        _isRecorderInitialized = false;
      });
    });
  }

  @override
  void dispose() {
    _stopStreaming();
    _recorder.closeRecorder().catchError((err){
      debugPrint("Error closing recorder: $err");
    });
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  // --- Recorder Session Management ---
  Future<void> _openRecorderSession() async {
    var micStatus = await Permission.microphone.request();
    if (micStatus != PermissionStatus.granted) {
      throw RecordingPermissionException("Microphone permission not granted");
    }
    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
    debugPrint("Recorder session opened.");
  }


  // --- Streaming Logic ---
  Future<void> _startStreaming() async {
    if (_isStreaming) return;
    if (!_isRecorderInitialized) {
      setState(() {
        _statusText = "Recorder not initialized yet. Please wait or restart.";
      });
      return;
    }

    var micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      setState(() { _statusText = "Microphone permission revoked."; });
      return;
    }

    final String ip = _ipController.text.trim();
    final String portStr = _portController.text.trim();
    int? port = int.tryParse(portStr);

    if (ip.isEmpty || port == null) {
      setState(() { _statusText = "Invalid IP or Port"; });
      return;
    }

    setState(() {
      _statusText = "Connecting to $ip:$port...";
      _isStreaming = true;
    });

    try {
      _socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
      debugPrint("Connected to server: ${_socket?.remoteAddress.address}:${_socket?.remotePort}");
      setState(() { _statusText = "Connected. Starting stream..."; });

      _socketSubscription = _socket?.listen(
            (data) { debugPrint("Received from server: ${String.fromCharCodes(data)}"); },
        onError: (error) {
          debugPrint("Socket Error: $error");
          _handleStreamingError("Socket Error: $error");
        },
        onDone: () {
          debugPrint("Socket closed by server.");
          _handleStreamingError("Server disconnected.");
        },
        cancelOnError: true,
      );

      // --- Start flutter_sound recording to a Stream (Updated Part) ---
      // 1. StreamController now handles nullable Uint8List directly
      StreamController<Uint8List>? recordingDataController = StreamController<Uint8List>();

      // 2. Listener now expects Uint8List? directly
      _recorderSubscription = recordingDataController.stream.listen(
              (Uint8List? buffer) { // Receive buffer directly
            // 3. Check if the buffer is not null and not empty before sending
            if (buffer != null && buffer.isNotEmpty) {
              if (_socket != null) {
                try {
                  _socket?.add(buffer); // Send the buffer
                } catch (e) {
                  debugPrint("Error sending data: $e");
                  _handleStreamingError("Error sending data: $e");
                }
              }
            }
          },
          onError: (error){
            debugPrint("Recorder Stream Error: $error");
            _handleStreamingError("Recorder Stream Error: $error");
          },
          onDone: (){
            debugPrint("Recorder stream finished.");
            if (_isStreaming) {
              _handleStreamingError("Audio source finished unexpectedly.");
            }
          },
          cancelOnError: true
      );

      // Start recording
      await _recorder.startRecorder(
        // 4. The sink type matches the StreamController (StreamSink<Uint8List?>)
        toStream: recordingDataController.sink,
        codec: Codec.pcm16, // Raw 16-bit PCM audio
        numChannels: serverNumChannels,
        sampleRate: serverSampleRate,
      );

      setState(() { _statusText = "Streaming..."; });
      debugPrint("Recording started to stream.");

    } catch (e) {
      debugPrint("Connection or Start Error: $e");
      _handleStreamingError("Failed to start: $e");
    }
  }

  Future<void> _stopStreaming() async {
    if (!_isStreaming && _socket == null && _recorderSubscription == null && !_recorder.isRecording) {
      debugPrint("Stop called but not streaming/recording.");
      return;
    }

    setState(() { _statusText = "Stopping..."; });

    try {
      if (_recorder.isRecording) {
        await _recorder.stopRecorder();
        debugPrint("Recorder stopped.");
      } else {
        debugPrint("Recorder was not recording.");
      }
    } catch (err) {
      debugPrint('Error stopping recorder: $err');
    }

    await _recorderSubscription?.cancel();
    _recorderSubscription = null;

    await _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.close();
    _socket = null;
    debugPrint("Socket closed.");

    if(mounted) {
      setState(() {
        _isStreaming = false;
        _statusText = "Stream stopped. Enter Server IP/Port and press Start.";
      });
    }
  }

  void _handleStreamingError(String errorMessage) {
    debugPrint("Streaming Error: $errorMessage");
    if(mounted) {
      setState(() {
        _statusText = "Error: $errorMessage";
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stopStreaming();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Voice Streamer (flutter_sound)"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'Server IP Address',
                border: OutlineInputBorder(),
              ),
              onTapOutside: (_) {
                FocusManager.instance.primaryFocus?.unfocus();
              },
              keyboardType: TextInputType.url,
              enabled: !_isStreaming,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Server Port',
                border: OutlineInputBorder(),
              ),
              onTapOutside: (_) {
                FocusManager.instance.primaryFocus?.unfocus();
              },
              keyboardType: TextInputType.number,
              enabled: !_isStreaming,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isRecorderInitialized && !_isStreaming
                  ? _startStreaming
                  : (_isStreaming ? _stopStreaming : null),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isStreaming ? Colors.red : Colors.green,
                padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 15),
              ),
              child: Text(
                _isStreaming ? 'Stop Streaming' : 'Start Streaming',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _statusText,
              textAlign: TextAlign.center,
            ),
            if (!_isRecorderInitialized)
              const Padding(
                padding: EdgeInsets.only(top: 20.0),
                child: CircularProgressIndicator(),
              )
          ],
        ),
      ),
    );
  }
}