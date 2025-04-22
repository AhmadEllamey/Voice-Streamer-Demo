import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';
// Import the encrypt package
import 'package:encrypt/encrypt.dart' as encrypt; // Use prefix to avoid conflicts

// Audio parameters (keep consistent)
const int serverSampleRate = 16000;
const int serverNumChannels = 1;

// --- Encryption Setup ---
// INSECURE: Hardcoded Pre-Shared Key (32 bytes for AES-256)
// Use the same key string in Python!
final String sharedKeyString = "ThisIsA_Secure32ByteKey123456780";
// Convert the string key to Key object for the library
final encrypt.Key encryptionKey = encrypt.Key.fromUtf8(sharedKeyString);
// Nonce length for AES-GCM (12 bytes is standard)
const int nonceLength = 12;
// --- End Encryption Setup ---


void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Streamer UDP Encrypted', // Updated title
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
  RawDatagramSocket? _udpSocket;
  InternetAddress? _serverAddress;
  int? _serverPort;

  // AES-GCM Encrypter instance
  // Initialize it once, or ensure key is available when needed
  final encrypter = encrypt.Encrypter(encrypt.AES(encryptionKey, mode: encrypt.AESMode.gcm));

  bool _isStreaming = false;
  bool _isRecorderInitialized = false;
  String _statusText = "Enter Server IP/Port and press Start";

  final TextEditingController _ipController = TextEditingController(text: "192.168.1.53");
  final TextEditingController _portController = TextEditingController(text: "8080");

  @override
  void initState() {
    super.initState();
    // IMPORTANT: Warn about insecure key in debug mode
    if (kDebugMode) {
      debugPrint("***********************************************************");
      debugPrint("WARNING: Using hardcoded encryption key for DEMO purposes.");
      debugPrint("This is INSECURE and should NOT be used in production!");
      debugPrint("***********************************************************");
    }
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
    var micStatus = await Permission.microphone.request();
    if (micStatus != PermissionStatus.granted) {
      throw RecordingPermissionException("Microphone permission not granted");
    }
    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
    debugPrint("Recorder session opened.");
  }

  Future<void> _startStreaming() async {
    // ... (Permission checks, IP/Port parsing, IP lookup - remain the same) ...
    if (_isStreaming) return;
    if (!_isRecorderInitialized) { setState(() { _statusText = "Recorder not ready."; }); return; }
    var micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) { setState(() { _statusText = "Microphone permission needed."; }); return; }

    final String ipStr = _ipController.text.trim();
    final String portStr = _portController.text.trim();
    _serverPort = int.tryParse(portStr);

    if (ipStr.isEmpty || _serverPort == null) { setState(() { _statusText = "Invalid IP or Port"; }); return; }

    try {
      var addresses = await InternetAddress.lookup(ipStr);
      if (addresses.isEmpty) { setState(() { _statusText = "Cannot resolve IP address"; }); return; }
      _serverAddress = addresses.first;
      debugPrint('Resolved server address: ${_serverAddress?.address}');
    } catch (e) { setState(() { _statusText = "Error resolving IP: $e"; }); return; }


    setState(() { _statusText = "Starting Encrypted UDP Stream..."; _isStreaming = true; });

    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      debugPrint('UDP Socket bound to local port: ${_udpSocket?.port}');

      // --- Start flutter_sound recording ---
      StreamController<Uint8List>? recordingDataController = StreamController<Uint8List>();
      _recorderSubscription = recordingDataController.stream.listen(
            (Uint8List? buffer) {
          if (buffer != null && buffer.isNotEmpty && _udpSocket != null && _serverAddress != null && _serverPort != null) {
            try {
              // --- Encryption Step ---
              // 1. Generate a unique nonce for each packet
              final nonce = encrypt.IV.fromSecureRandom(nonceLength); // 12 bytes for GCM

              // 2. Encrypt the audio buffer
              final encryptedData = encrypter.encryptBytes(buffer, iv: nonce);

              // 3. Prepend nonce to ciphertext
              final packetToSend = Uint8List.fromList(nonce.bytes + encryptedData.bytes);
              // --- End Encryption Step ---

              // 4. Send the combined packet (nonce + ciphertext)
              _udpSocket?.send(packetToSend, _serverAddress!, _serverPort!);
              // print('Sent ${packetToSend.length} encrypted bytes'); // Debug

            } catch (e) {
              debugPrint("Error encrypting/sending UDP packet: $e");
              // Consider stopping or adding error handling
            }
          }
        },
        onError: (error) { debugPrint("Recorder Stream Error: $error"); _handleStreamingError("Recorder Stream Error: $error"); },
        onDone: () { debugPrint("Recorder stream finished."); if (_isStreaming) { _handleStreamingError("Audio source finished unexpectedly."); } },
        cancelOnError: true,
      );

      await _recorder.startRecorder(
        toStream: recordingDataController.sink,
        codec: Codec.pcm16,
        numChannels: serverNumChannels,
        sampleRate: serverSampleRate,
      );

      setState(() { _statusText = "Streaming Encrypted via UDP..."; });
      debugPrint("Recording started to stream for Encrypted UDP.");

    } catch (e) {
      debugPrint("UDP Socket/Start Error: $e");
      _handleStreamingError("Failed to start UDP: $e");
    }
  }

  // --- _stopStreaming, _handleStreamingError, build methods remain the same ---
  // ... (paste the previous _stopStreaming, _handleStreamingError, build methods here) ...
  Future<void> _stopStreaming() async {
    if (!_isStreaming && _udpSocket == null && !_recorder.isRecording) {
      debugPrint("Stop called but not streaming/recording.");
      return;
    }

    setState(() { _statusText = "Stopping..."; });

    // 1. Stop the recorder
    try {
      if (_recorder.isRecording) {
        await _recorder.stopRecorder();
        debugPrint("Recorder stopped.");
      }
    } catch (err) {
      debugPrint('Error stopping recorder: $err');
    }

    // 2. Cancel the recorder stream subscription
    await _recorderSubscription?.cancel();
    _recorderSubscription = null;

    // 3. Close the UDP socket
    _udpSocket?.close();
    _udpSocket = null;
    debugPrint("UDP Socket closed.");

    // Reset server address/port
    _serverAddress = null;
    _serverPort = null;

    if (mounted) {
      setState(() {
        _isStreaming = false;
        _statusText = "Stream stopped. Enter Server IP/Port and press Start.";
      });
    }
  }

  void _handleStreamingError(String errorMessage) {
    debugPrint("Streaming Error: $errorMessage");
    if (mounted) {
      setState(() {
        _statusText = "Error: $errorMessage";
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stopStreaming(); // Stop everything cleanly
    });
  }

  @override
  Widget build(BuildContext context) {
    // --- UI remains largely the same ---
    return Scaffold(
      appBar: AppBar(title: const Text("Voice Streamer UDP Encrypted")), // Updated title
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // Add a small note about encryption maybe? (Optional)
            const Padding(
              padding: EdgeInsets.only(bottom: 10.0),
              child: Text(
                "⚠️ Encryption active (Demo Key!)",
                style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
              ),
            ),
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(labelText: 'Server IP Address', border: OutlineInputBorder()),
              keyboardType: TextInputType.url,
              enabled: !_isStreaming,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(labelText: 'Server Port (UDP)', border: OutlineInputBorder()),
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
            Text(_statusText, textAlign: TextAlign.center),
            if (!_isRecorderInitialized)
              const Padding(padding: EdgeInsets.only(top: 20.0), child: CircularProgressIndicator())
          ],
        ),
      ),
    );
  }

} // End of _VoiceStreamerPageState