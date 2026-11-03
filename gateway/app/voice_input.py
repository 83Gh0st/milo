"""Voice-input byte hygiene. Pure stdlib: unit-tested without the network.

The phone streams raw PCM16 mono 24 kHz. Some recorders prepend a WAV header
instead; forwarding header bytes into a PCM_24KHZ session corrupts ASR
silently, so a RIFF/WAVE prefix is stripped to its data chunk here. Anything
else passes through untouched - the gateway never resamples or guesses.
"""
import struct

BYTES_PER_SECOND = 48000  # 24 kHz * 2 bytes (PCM16 mono)
MIN_UTTERANCE_BYTES = 4800  # 0.1 s: shorter is a tap, not speech


def strip_wav_header(data: bytes) -> bytes:
    """Returns the PCM payload of a WAV byte string, or data unchanged."""
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return data
    pos = 12
    while pos + 8 <= len(data):
        chunk_id = data[pos:pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        body = pos + 8
        if chunk_id == b"data":
            return data[body:body + size] if size else data[body:]
        pos = body + size + (size % 2)
    return data


def is_too_short(total_bytes: int) -> bool:
    return total_bytes < MIN_UTTERANCE_BYTES
