import 'dart:async';
import 'dart:io'; // For RawDatagramSocket, InternetAddress
import 'dart:typed_data'; // For Uint8List
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_sound/flutter_sound.dart';

// Audio parameters (keep consistent)
const int serverSampleRate = 16000;
const int serverNumChannels = 1;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Streamer UDP (flutter_sound)',
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
  // --- UDP Changes ---
  RawDatagramSocket? _udpSocket; // Use RawDatagramSocket for UDP
  InternetAddress? _serverAddress; // Store resolved server address
  int? _serverPort; // Store server port
  // --- End UDP Changes ---

  bool _isStreaming = false;
  bool _isRecorderInitialized = false;
  String _statusText = "Enter Server IP/Port and press Start";

  final TextEditingController _ipController =
  TextEditingController(text: "192.168.1.53"); // Default IP
  final TextEditingController _portController =
  TextEditingController(text: "8080"); // Default Port (UDP)

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
    _recorder.closeRecorder().catchError((err) {
      debugPrint("Error closing recorder: $err");
    });
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

  // --- UDP Streaming Logic ---
  Future<void> _startStreaming() async {
    if (_isStreaming) return;
    if (!_isRecorderInitialized) {
      setState(() { _statusText = "Recorder not ready."; });
      return;
    }
    var micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      setState(() { _statusText = "Microphone permission needed."; });
      return;
    }

    final String ipStr = _ipController.text.trim();
    final String portStr = _portController.text.trim();
    _serverPort = int.tryParse(portStr);

    if (ipStr.isEmpty || _serverPort == null) {
      setState(() { _statusText = "Invalid IP or Port"; });
      return;
    }

    // Resolve IP address string to InternetAddress object
    try {
      var addresses = await InternetAddress.lookup(ipStr);
      if (addresses.isEmpty) {
        setState(() { _statusText = "Cannot resolve IP address"; });
        return;
      }
      // Use the first resolved address
      _serverAddress = addresses.first;
      debugPrint('Resolved server address: ${_serverAddress?.address}');

    } catch (e) {
      setState(() { _statusText = "Error resolving IP: $e"; });
      return;
    }


    setState(() {
      _statusText = "Starting UDP Stream...";
      _isStreaming = true; // Tentatively set streaming state
    });

    try {
      // Bind the UDP socket to any available local IP and port 0 (OS chooses port)
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      debugPrint('UDP Socket bound to local port: ${_udpSocket?.port}');

      // Optional: Listen for incoming datagrams (e.g., ACKs from server)
      // _udpSocket?.listen((RawSocketEvent event) {
      //   if (event == RawSocketEvent.read) {
      //     Datagram? dg = _udpSocket?.receive();
      //     if (dg != null) {
      //       debugPrint('Received from server: ${String.fromCharCodes(dg.data)}');
      //     }
      //   }
      // });


      // --- Start flutter_sound recording ---
      StreamController<Uint8List>? recordingDataController = StreamController<Uint8List>();
      _recorderSubscription = recordingDataController.stream.listen(
            (Uint8List? buffer) {
          if (buffer != null && buffer.isNotEmpty && _udpSocket != null && _serverAddress != null && _serverPort != null) {
            // Send data using UDP socket
            try {
              _udpSocket?.send(buffer, _serverAddress!, _serverPort!);
              // print('Sent ${buffer.length} bytes'); // Can be noisy
            } catch (e) {
              // Handle potential send errors (less common for UDP send itself)
              debugPrint("Error sending UDP packet: $e");
              // Optional: Implement some backoff or stop streaming
            }
          }
        },
        onError: (error) {
          debugPrint("Recorder Stream Error: $error");
          _handleStreamingError("Recorder Stream Error: $error");
        },
        onDone: () {
          debugPrint("Recorder stream finished.");
          if (_isStreaming) {
            _handleStreamingError("Audio source finished unexpectedly.");
          }
        },
        cancelOnError: true,
      );

      await _recorder.startRecorder(
        toStream: recordingDataController.sink,
        codec: Codec.pcm16,
        numChannels: serverNumChannels,
        sampleRate: serverSampleRate,
      );

      setState(() { _statusText = "Streaming via UDP..."; });
      debugPrint("Recording started to stream for UDP.");

    } catch (e) {
      debugPrint("UDP Socket/Start Error: $e");
      _handleStreamingError("Failed to start UDP: $e");
    }
  }

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
      appBar: AppBar(title: const Text("Voice Streamer UDP (flutter_sound)")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
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