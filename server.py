import socket
import sounddevice as sd
import numpy as np
import queue # For potential buffering improvements later (optional)

# --- Configuration (MUST MATCH FLUTTER APP EXACTLY) ---
HOST = '0.0.0.0'  # Listen on all interfaces
PORT = 8080       # Port number (must match Flutter app)

# Audio parameters from Flutter app (flutter_sound example)
SAMPLE_RATE = 16000 # const int serverSampleRate = 16000;
CHANNELS = 1        # const int serverNumChannels = 1; (Mono)
# Codec.pcm16 sends signed 16-bit integers
# Use 'int16' for numpy/sounddevice
DTYPE = 'int16'

# Network buffer size (how much data to receive at once)
# Should be appropriate for the data rate, 4096 is a common starting point
BUFFER_SIZE = 4096
# --- End Configuration ---

print(f"Starting server on {HOST}:{PORT}...")
print(f"Audio Settings: Sample Rate={SAMPLE_RATE}, Channels={CHANNELS}, Dtype={DTYPE}")
print("Ensure the Flutter app is sending audio with these exact settings.")

# --- Main Server Loop ---
while True: # Loop to allow reconnects after client disconnects
    conn = None # Define connection outside try block for cleanup
    stream = None # Define stream outside try block for cleanup
    try:
        # --- Set up Socket ---
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1) # Allow address reuse
            s.bind((HOST, PORT))
            s.listen()
            print(f"\nServer listening on port {PORT}... Waiting for connection.")

            conn, addr = s.accept()
            print(f"Connected by {addr}")

            # --- Configure and Start Audio Output Stream ---
            # The 'with' statement ensures the stream is properly closed
            with sd.OutputStream(samplerate=SAMPLE_RATE,
                                 channels=CHANNELS,
                                 dtype=DTYPE) as stream:

                print("Audio output stream started. Playing received audio...")
                # stream.start() is called automatically by 'with' context

                while True:
                    # --- Receive Data ---
                    data = conn.recv(BUFFER_SIZE)
                    if not data:
                        print(f"Connection closed by {addr}")
                        break # Exit inner loop for this client

                    # --- Process and Play Audio ---
                    try:
                        # Ensure we have an even number of bytes for int16 conversion
                        if len(data) % 2 != 0:
                            print(f"Warning: Received odd number of bytes ({len(data)}). Discarding last byte.")
                            data = data[:-1] # Truncate the last byte

                        # Check if data is empty after potential truncation
                        if not data:
                            continue

                        # Convert the raw bytes into a NumPy array of the correct data type
                        audio_chunk = np.frombuffer(data, dtype=np.int16)

                        # Write the audio chunk to the output stream to play it
                        stream.write(audio_chunk)

                        # Optional: Print status (can be noisy)
                        # print(f"Played {len(audio_chunk)} samples ({len(data)} bytes)")

                    except ValueError as ve:
                        # Might happen if buffer size and dtype don't align perfectly,
                        # or if received data is somehow corrupted.
                        print(f"Value Error converting audio buffer (length {len(data)}): {ve}")
                        continue # Skip this chunk
                    except Exception as audio_err:
                        print(f"Error processing/playing audio chunk: {audio_err}")
                        # Depending on the error, you might want to 'break' or 'continue'
                        continue

    # --- Error Handling & Cleanup ---
    except socket.error as e:
        print(f"Socket error: {e}")
    except sd.PortAudioError as pae:
        # Common errors: Invalid device, sample rate not supported, etc.
        print(f"Sounddevice Error: {pae}")
        print("Check your Mac's audio output device and the script's audio settings.")
        break # Exit outer loop if audio device fails critically
    except KeyboardInterrupt:
        print("\nServer shutting down (Ctrl+C pressed).")
        break # Exit the outer loop
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
    finally:
        # Ensure resources are cleaned up
        # The sd.OutputStream is closed automatically by the 'with' block
        if conn:
            conn.close()
            print("Connection closed.")
        print("Waiting for new connection...")
        # Optional small delay before restarting listening loop
        # import time
        # time.sleep(1)

print("Server stopped.")
