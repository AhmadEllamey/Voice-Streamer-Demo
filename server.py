import socket
import sounddevice as sd
import numpy as np
# Import cryptography components
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag

# --- Configuration (MUST MATCH FLUTTER APP EXACTLY) ---
HOST = '0.0.0.0'
PORT = 8080
SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = 'int16'
BUFFER_SIZE = 8192 # Receive buffer size

# --- Encryption Setup ---
# INSECURE: Hardcoded Pre-Shared Key (MUST MATCH FLUTTER APP EXACTLY!)
# Must be bytes. Use .encode() for string literals.
shared_key_bytes = b"ThisIsA_Secure32ByteKey123456780" # 32 bytes for AES-256
# Nonce length used by the client (must match)
NONCE_LENGTH = 12 # 12 bytes (96 bits) is standard for GCM
# Create AES-GCM instance (can be reused)
try:
    aesgcm = AESGCM(shared_key_bytes)
    print("AES-GCM cipher initialized successfully.")
except ValueError as e:
    print(f"Error initializing AESGCM (Invalid Key Length?): {e}")
    exit()

print("***********************************************************")
print("WARNING: Using hardcoded encryption key for DEMO purposes.")
print("This is INSECURE and should NOT be used in production!")
print("***********************************************************")
# --- End Encryption Setup ---


print(f"Starting Encrypted UDP server on {HOST}:{PORT}...")
print(f"Audio Settings: Sample Rate={SAMPLE_RATE}, Channels={CHANNELS}, Dtype={DTYPE}")

# --- Initialize Socket ---
udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    udp_socket.bind((HOST, PORT))
    print(f"UDP Server listening on port {PORT}...")
except socket.error as e:
    print(f"Failed to bind socket: {e}")
    exit()

# --- Initialize Audio Output Stream ---
stream = None # Define outside try block for finally clause
try:
    stream = sd.OutputStream(samplerate=SAMPLE_RATE, channels=CHANNELS, dtype=DTYPE)
    stream.start()
    print("Audio output stream started.")
except sd.PortAudioError as pae:
    print(f"Sounddevice Error: {pae}")
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
        try:
            # Receive the combined packet (nonce + ciphertext)
            packet, addr = udp_socket.recvfrom(BUFFER_SIZE)
            # print(f"Received {len(packet)} encrypted bytes from {addr}") # Debug
        except socket.error as sock_err:
            print(f"Socket error during recvfrom: {sock_err}")
            continue # Attempt to continue receiving

        if not packet or len(packet) <= NONCE_LENGTH:
            print(f"Received invalid/short packet from {addr} (length {len(packet)}). Discarding.")
            continue

        # --- Decryption Step ---
        try:
            # 1. Separate nonce and ciphertext
            nonce = packet[:NONCE_LENGTH]
            ciphertext = packet[NONCE_LENGTH:]

            # 2. Decrypt and verify integrity
            # Pass None for associated_data if not used
            plaintext = aesgcm.decrypt(nonce, ciphertext, None)
            # print(f"Decrypted {len(ciphertext)} bytes to {len(plaintext)} bytes") # Debug

        except InvalidTag:
            # IMPORTANT: This means authentication failed (data tampered, wrong key, etc.)
            print(f"Decryption failed (InvalidTag) from {addr}. Discarding packet.")
            continue # Discard invalid packet
        except Exception as decrypt_err:
            print(f"Error during decryption from {addr}: {decrypt_err}")
            continue # Discard packet on other decryption errors
        # --- End Decryption Step ---


        # --- Process and Play Plaintext Audio ---
        try:
            # Ensure we have an even number of bytes for int16 conversion
            # (Should be guaranteed by sender if encryption worked)
            if len(plaintext) % 2 != 0:
                # This shouldn't happen if encryption/decryption is correct
                print(f"Warning: Decrypted odd number of bytes ({len(plaintext)}) from {addr}. Discarding.")
                continue

            if not plaintext:
                continue

            # Convert the *decrypted* bytes into a NumPy array
            audio_chunk = np.frombuffer(plaintext, dtype=np.int16)

            # Write the audio chunk to the output stream
            stream.write(audio_chunk)

        except ValueError as ve:
            print(f"Value Error converting decrypted audio (len {len(plaintext)}) from {addr}: {ve}")
            continue
        except Exception as audio_err:
            print(f"Error playing audio chunk from {addr}: {audio_err}")
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
        except Exception as e: print(f"Error stopping audio stream: {e}")
    if udp_socket:
        udp_socket.close()
        print("UDP socket closed.")
    print("Server stopped.")