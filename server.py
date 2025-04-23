import socket
import struct  # For packing/unpacking the length prefix
import sounddevice as sd
import numpy as np
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag
import threading  # Optional: To handle multiple clients, but keep simple for now

# --- Configuration (MUST MATCH FLUTTER APP EXACTLY) ---
HOST = '0.0.0.0'
PORT = 8080  # TCP Port
SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = 'int16'
RECV_BUFFER_SIZE = 4096  # Socket receive buffer size

# --- Encryption Setup (Keep the corrected 32-byte key) ---
shared_key_bytes = b"ThisIsA_Secure32ByteKey12345678"  # Use the CORRECT 32-byte key
NONCE_LENGTH = 12
try:
    aesgcm = AESGCM(shared_key_bytes)
    print("AES-GCM cipher initialized successfully.")
except ValueError as e:
    print(f"Error initializing AESGCM: {e}")
    exit()
print("**************** WARNING: Using hardcoded demo key! ****************")


# --- End Encryption Setup ---

# --- Helper Function to receive exact number of bytes ---
def recvall(sock, n):
    """Helper function to receive exactly n bytes from socket sock"""
    data = bytearray()
    while len(data) < n:
        packet = sock.recv(n - len(data))
        if not packet:
            return None  # Connection closed
        data.extend(packet)
    return bytes(data)


# --- Function to handle a single client connection ---
def handle_client(conn, addr, audio_stream):
    print(f"Handling connection from {addr}")
    expected_len = -1
    packet_buffer = b''

    try:
        while True:
            # --- Read Framed Message ---
            # 1. Read the 4-byte length prefix
            len_bytes = recvall(conn, 4)
            if not len_bytes:
                print(f"Client {addr} disconnected while waiting for length.")
                break  # Client closed connection

            # 2. Unpack the length (using Big Endian as sent from Flutter)
            expected_len = struct.unpack('>I', len_bytes)[
                0]  # >I means big-endian unsigned int (4 bytes)

            # 3. Read the full packet (nonce + ciphertext)
            packet = recvall(conn, expected_len)
            if not packet:
                print(
                    f"Client {addr} disconnected while waiting for payload (expected {expected_len} bytes).")
                break

            # --- Decryption ---
            if len(packet) < NONCE_LENGTH:
                print(f"Received packet too short ({len(packet)} bytes) from {addr}. Discarding.")
                continue

            nonce = packet[:NONCE_LENGTH]
            ciphertext = packet[NONCE_LENGTH:]

            try:
                plaintext = aesgcm.decrypt(nonce, ciphertext, None)
            except InvalidTag:
                print(f"Decryption failed (InvalidTag) from {addr}. Discarding packet.")
                continue  # Discard invalid packet
            except Exception as decrypt_err:
                print(f"Error during decryption from {addr}: {decrypt_err}")
                continue

            # --- Play Audio ---
            try:
                if len(plaintext) % 2 != 0:  # Should be even for int16
                    print(
                        f"Warning: Decrypted odd bytes ({len(plaintext)}) from {addr}. Discarding.")
                    continue
                if not plaintext: continue

                audio_chunk = np.frombuffer(plaintext, dtype=np.int16)
                audio_stream.write(audio_chunk)

                # --- Corrected block ---
            except ValueError as ve:  # Handle potential numpy errors (e.g., frombuffer)
                print(
                    f"Value Error converting/playing decrypted audio (len {len(plaintext)}) from {addr}: {ve}")
                continue  # Skip this problematic chunk
            except Exception as audio_err:  # Handle other playback errors (e.g., sounddevice issues)
                print(f"Error during audio playback for {addr}: {audio_err}")
                continue  # Skip this problematic chunk
            # --- End corrected block ---



    except ConnectionResetError:
        print(f"Connection reset by client {addr}")
    except Exception as e:
        print(f"Error handling client {addr}: {e}")
    finally:
        print(f"Closing connection from {addr}")
        conn.close()


# --- Main Server Setup ---
def main():
    # --- Initialize Audio Output Stream ---
    audio_stream = None
    try:
        audio_stream = sd.OutputStream(samplerate=SAMPLE_RATE, channels=CHANNELS, dtype=DTYPE)
        audio_stream.start()
        print("Audio output stream started.")
    except Exception as e:
        print(f"Failed to initialize audio stream: {e}")
        return  # Exit if audio fails

    # --- Initialize TCP Socket ---
    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server_socket.bind((HOST, PORT))
        server_socket.listen()  # Start listening for incoming connections
        print(f"TCP Server listening on {HOST}:{PORT}...")
    except socket.error as e:
        print(f"Failed to bind/listen on socket: {e}")
        if audio_stream: audio_stream.close()
        return  # Exit if socket fails

    # --- Accept Connections Loop ---
    try:
        while True:
            try:
                # Wait for and accept a new connection
                client_conn, client_addr = server_socket.accept()
                print(f"\nAccepted connection from {client_addr}")
                # In a real server, you'd likely start a new thread or process here
                # For simplicity, handle one client at a time sequentially
                handle_client(client_conn, client_addr, audio_stream)

            except socket.error as accept_err:
                print(f"Error accepting connection: {accept_err}")
                # Decide if error is fatal or if loop can continue

    except KeyboardInterrupt:
        print("\nServer shutting down (Ctrl+C pressed).")
    except Exception as e:
        print(f"An unexpected error occurred in main loop: {e}")
    finally:
        print("Closing server socket and audio stream...")
        if server_socket: server_socket.close()
        if audio_stream:
            try:
                audio_stream.stop()
                audio_stream.close()
                print("Audio stream stopped.")
            except Exception as e:
                print(f"Error stopping audio stream: {e}")
        print("Server stopped.")


if __name__ == "__main__":
    main()
