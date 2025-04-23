import 'dart:async';
import 'dart:io'; // For Socket, InternetAddress
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

// Audio parameters
const int serverSampleRate = 16000;
const int serverNumChannels = 1;

// --- Encryption Setup (Keep the corrected 32-byte key) ---
final String sharedKeyString = "ThisIsA_Secure32ByteKey123456780"; // Use the CORRECT 32-byte key
final encrypt.Key encryptionKey = encrypt.Key.fromUtf8(sharedKeyString);
const int nonceLength = 12; // 12 bytes for GCM
// --- End Encryption Setup ---

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Streamer TCP Encrypted', // Updated title
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
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
  // --- TCP Changes ---
  Socket? _socket; // Use Socket for TCP
  StreamSubscription? _socketSubscription; // For listening to socket events
  // --- End TCP Changes ---

  final encrypter = encrypt.Encrypter(encrypt.AES(encryptionKey, mode: encrypt.AESMode.gcm));

  bool _isStreaming = false;
  bool _isConnecting = false; // Track connection state
  bool _isRecorderInitialized = false;
  String _statusText = "Enter Server IP/Port and press Start";

  final TextEditingController _ipController = TextEditingController(text: "192.168.1.53");
  final TextEditingController _portController = TextEditingController(text: "8080"); // TCP Port

  @override
  void initState() {
    super.initState();
    if (kDebugMode) { /* Print insecure key warning */ }
    _openRecorderSession().then((_) {
      setState(() { _isRecorderInitialized = true; _statusText = "Recorder ready."; });
    }).catchError((err) {
      setState(() { _statusText = "Recorder Init Error: $err"; _isRecorderInitialized = false; });
    });
  }

  @override
  void dispose() {
    _stopStreaming();
    _recorder.closeRecorder().catchError((err) { debugPrint("Error closing recorder: $err"); });
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _openRecorderSession() async {
    // ... (same as before) ...
    var micStatus = await Permission.microphone.request();
    if (micStatus != PermissionStatus.granted) {
      throw RecordingPermissionException("Microphone permission not granted");
    }
    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
    debugPrint("Recorder session opened.");
  }


  // --- TCP Streaming Logic ---
  Future<void> _startStreaming() async {
    if (_isStreaming || _isConnecting) return; // Prevent multiple attempts
    if (!_isRecorderInitialized) { /* Handle recorder not ready */ return; }
    if (!await _checkMicPermission()) return; // Helper function below

    final String ipStr = _ipController.text.trim();
    final String portStr = _portController.text.trim();
    int? port = int.tryParse(portStr);

    if (ipStr.isEmpty || port == null) { /* Handle invalid input */ return; }

    setState(() { _isConnecting = true; _statusText = "Connecting to $ipStr:$port..."; });

    try {
      // --- Connect TCP Socket ---
      _socket = await Socket.connect(ipStr, port, timeout: const Duration(seconds: 5));
      debugPrint("TCP Socket Connected to ${_socket?.remoteAddress.address}:${_socket?.remotePort}");
      setState(() { _isConnecting = false; _isStreaming = true; _statusText = "Connected. Starting stream..."; });

      // --- Listen for server disconnects / errors ---
      _socketSubscription = _socket?.listen(
            (data) {
          // Optional: Handle any data received FROM server
          debugPrint("Received from server: ${String.fromCharCodes(data)}");
        },
        onError: (error) {
          debugPrint("TCP Socket Error: $error");
          _handleStreamingError("Socket Error: $error");
        },
        onDone: () {
          debugPrint("TCP Socket closed by server.");
          _handleStreamingError("Server disconnected.");
        },
        cancelOnError: true, // Auto-cancel on error
      );

      // --- Start flutter_sound recording ---
      StreamController<Uint8List>? recordingDataController = StreamController<Uint8List>();
      _recorderSubscription = recordingDataController.stream.listen(
            (Uint8List? buffer) {
          if (buffer != null && buffer.isNotEmpty && _socket != null && _isStreaming) {
            try {
              // --- Encryption Step ---
              final nonce = encrypt.IV.fromSecureRandom(nonceLength);
              final encryptedData = encrypter.encryptBytes(buffer, iv: nonce);
              final payload = nonce.bytes + encryptedData.bytes;
              // --- End Encryption Step ---

              // --- Framing Step ---
              // 1. Get payload length
              final payloadLength = payload.length;
              // 2. Convert length to 4 bytes (e.g., Big Endian)
              final lengthBytes = ByteData(4)..setUint32(0, payloadLength, Endian.big);
              // 3. Prepend length bytes to payload
              final packetToSend = Uint8List.fromList(lengthBytes.buffer.asUint8List() + payload);
              // --- End Framing Step ---

              // 4. Send the framed packet over TCP
              _socket?.add(packetToSend);
              // Optional: Flush if experiencing delays, usually not needed immediately
              // _socket?.flush();
              // print('Sent ${packetToSend.length} framed encrypted bytes'); // Debug

            } catch (e) {
              debugPrint("Error encrypting/sending TCP packet: $e");
              _handleStreamingError("Error sending data: $e"); // Stop on send error
            }
          }
        },
        onError: (error) { /* Handle recorder error */ _handleStreamingError("Recorder Stream Error: $error"); },
        onDone: () { /* Handle recorder done */ if (_isStreaming) { _handleStreamingError("Audio source finished."); } },
        cancelOnError: true,
      );

      await _recorder.startRecorder(
        toStream: recordingDataController.sink,
        codec: Codec.pcm16,
        numChannels: serverNumChannels,
        sampleRate: serverSampleRate,
      );

      setState(() { _statusText = "Streaming Encrypted via TCP..."; });
      debugPrint("Recording started to stream for Encrypted TCP.");

    } catch (e) {
      debugPrint("TCP Connection/Start Error: $e");
      setState(() { _isConnecting = false; _isStreaming = false; _statusText = "Connection Failed: $e"; });
      _cleanupSocket(); // Ensure socket is cleaned up on connection failure
    }
  }

  Future<void> _stopStreaming() async {
    // Don't check _isStreaming here, allow stopping even if only connecting
    if (!_isStreaming && !_isConnecting) {
      debugPrint("Stop called but not streaming/connecting.");
      return;
    }
    setState(() { _statusText = "Stopping..."; });

    // 1. Stop the recorder
    try {
      if (_recorder.isRecording) {
        await _recorder.stopRecorder();
        debugPrint("Recorder stopped.");
      }
    } catch (err) { /* Log recorder stop error */ }

    // 2. Cancel recorder subscription
    await _recorderSubscription?.cancel();
    _recorderSubscription = null;

    // 3. Close socket and cancel its subscription
    _cleanupSocket();

    if (mounted) {
      setState(() {
        _isStreaming = false;
        _isConnecting = false; // Ensure connecting flag is reset
        _statusText = "Stream stopped. Enter Server IP/Port and press Start.";
      });
    }
  }

  // Helper to close socket and subscription
  void _cleanupSocket() {
    _socketSubscription?.cancel();
    _socketSubscription = null;
    // Use destroy() for immediate closure, close() is more graceful
    _socket?.destroy();
    _socket = null;
    debugPrint("TCP Socket closed.");
  }

  void _handleStreamingError(String errorMessage) {
    debugPrint("Streaming Error: $errorMessage");
    if (mounted) {
      setState(() {
        // Keep _isStreaming or _isConnecting true until cleanup finishes
        _statusText = "Error: $errorMessage. Stopping...";
      });
    }
    // Use WidgetsBinding to ensure cleanup runs after current frame/build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stopStreaming(); // Stop everything cleanly
    });
  }

  // Helper for mic permission check
  Future<bool> _checkMicPermission() async {
    var micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      setState(() { _statusText = "Microphone permission needed."; });
      // Optionally request again: await Permission.microphone.request();
      return false;
    }
    return true;
  }


  @override
  Widget build(BuildContext context) {
    // Determine if the button should be enabled
    final bool canStart = _isRecorderInitialized && !_isStreaming && !_isConnecting;
    final bool canStop = _isStreaming || _isConnecting; // Allow stopping during connection attempt

    return Scaffold(
      appBar: AppBar(title: const Text("Voice Streamer TCP Encrypted")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // ... (Warning text) ...
            const Padding(
              padding: EdgeInsets.only(bottom: 10.0),
              child: Text(
                "⚠️ Encryption active (Demo Key!)",
                style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
              ),
            ),
            TextField( /* IP Input */ controller: _ipController, enabled: !_isStreaming && !_isConnecting, decoration: const InputDecoration(labelText: 'Server IP Address', border: OutlineInputBorder()), keyboardType: TextInputType.url,),
            const SizedBox(height: 10),
            TextField( /* Port Input */ controller: _portController, enabled: !_isStreaming && !_isConnecting, decoration: const InputDecoration(labelText: 'Server Port (TCP)', border: OutlineInputBorder()), keyboardType: TextInputType.number,),
            const SizedBox(height: 20),
            ElevatedButton( /* Start/Stop Button */
              onPressed: canStart ? _startStreaming : (canStop ? _stopStreaming : null),
              style: ElevatedButton.styleFrom(
                backgroundColor: (_isStreaming || _isConnecting) ? Colors.red : Colors.green,
                padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 15),
              ),
              child: Text(
                (_isStreaming || _isConnecting) ? 'Stop Streaming' : 'Start Streaming',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(height: 20),
            Text(_statusText, textAlign: TextAlign.center),
            if (!_isRecorderInitialized || _isConnecting) // Show progress if initializing or connecting
              const Padding(padding: EdgeInsets.only(top: 20.0), child: CircularProgressIndicator())
          ],
        ),
      ),
    );
  }
}