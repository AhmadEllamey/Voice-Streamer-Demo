import socket
import sounddevice as sd
import numpy as np

# --- Configuration (MUST MATCH FLUTTER APP EXACTLY) ---
HOST = '0.0.0.0'  # Listen on all interfaces
PORT = 8080       # Port number (must match Flutter app)

# Audio parameters from Flutter app (flutter_sound example)
SAMPLE_RATE = 16000 # const int serverSampleRate = 16000;
CHANNELS = 1        # const int serverNumChannels = 1; (Mono)
DTYPE = 'int16'     # Codec.pcm16 -> signed 16-bit int

# Network buffer size - Make it large enough for typical UDP datagrams
# Consider potential fragmentation if too large, but 4096-8192 is usually fine
# Max UDP payload is ~65507 bytes, but practically limited by MTU (~1500 bytes)
BUFFER_SIZE = 8192
# --- End Configuration ---

print(f"Starting UDP server on {HOST}:{PORT}...")
print(f"Audio Settings: Sample Rate={SAMPLE_RATE}, Channels={CHANNELS}, Dtype={DTYPE}")

# --- Initialize Socket ---
# Use SOCK_DGRAM for UDP
udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    udp_socket.bind((HOST, PORT))
    print(f"UDP Server listening on port {PORT}...")
except socket.error as e:
    print(f"Failed to bind socket: {e}")
    exit() # Can't continue if binding fails

# --- Initialize Audio Output Stream ---
try:
    # Keep the stream open as long as the server runs
    stream = sd.OutputStream(samplerate=SAMPLE_RATE,
                             channels=CHANNELS,
                             dtype=DTYPE)
    stream.start() # Start the stream explicitly
    print("Audio output stream started.")
except sd.PortAudioError as pae:
    print(f"Sounddevice Error: {pae}")
    print("Check audio output device/settings.")
    udp_socket.close()
    exit()
except Exception as e:
    print(f"Error initializing audio stream: {e}")
    udp_socket.close()
    exit()


# --- Main Receiving Loop ---
try:
    while True:
        # --- Receive Data ---
        # recvfrom waits for the next UDP datagram
        # It returns the data and the address (ip, port) of the sender
        data, addr = udp_socket.recvfrom(BUFFER_SIZE)

        # Optional: Print sender info (can be noisy)
        # print(f"Received {len(data)} bytes from {addr}")

        if not data:
            # Should not happen often with UDP unless 0-byte packet sent
            print("Received empty packet.")
            continue

        # --- Process and Play Audio ---
        try:
            # Ensure we have an even number of bytes for int16 conversion
            if len(data) % 2 != 0:
                print(f"Warning: Received odd number of bytes ({len(data)}) from {addr}. Discarding last byte.")
                data = data[:-1]

            if not data: # Check if data became empty after truncation
                continue

            # Convert the raw bytes into a NumPy array
            audio_chunk = np.frombuffer(data, dtype=np.int16)

            # Write the audio chunk to the output stream
            stream.write(audio_chunk)

        except ValueError as ve:
            print(f"Value Error converting audio buffer (length {len(data)}) from {addr}: {ve}")
            continue # Skip this chunk
        except Exception as audio_err:
            print(f"Error processing/playing audio chunk from {addr}: {audio_err}")
            continue

# --- Cleanup on Exit ---
except KeyboardInterrupt:
    print("\nServer shutting down (Ctrl+C pressed).")
except Exception as e:
    print(f"An unexpected error occurred in recv loop: {e}")
finally:
    print("Stopping audio stream and closing socket...")
    if stream:
        try:
            stream.stop()
            stream.close()
            print("Audio stream stopped.")
        except Exception as e:
            print(f"Error stopping audio stream: {e}")
    if udp_socket:
        udp_socket.close()
        print("UDP socket closed.")
    print("Server stopped.")
