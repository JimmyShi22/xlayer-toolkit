#!/usr/bin/env python3
"""Derive a libp2p peer ID (base58btc, no CID wrapping) from a raw public key.

Usage: derive-peer-id.py <ed25519|secp256k1> <hex-pubkey>

ed25519:   hex-pubkey is the raw 32-byte public key.
secp256k1: hex-pubkey is the compressed 33-byte public key
           (0x02/0x03 prefix + 32-byte x-coordinate).
"""
import sys

KEY_TYPE_CODES = {"ed25519": 1, "secp256k1": 2}
BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def encode_varint(value):
    out = b""
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out += bytes([byte | 0x80])
        else:
            out += bytes([byte])
            return out


def base58_encode(data):
    number = int.from_bytes(data, "big")
    encoded = ""
    while number > 0:
        number, remainder = divmod(number, 58)
        encoded = BASE58_ALPHABET[remainder] + encoded
    leading_zeros = 0
    for byte in data:
        if byte == 0:
            leading_zeros += 1
        else:
            break
    return BASE58_ALPHABET[0] * leading_zeros + encoded


def derive_peer_id(key_type, pubkey_hex):
    key_type_code = KEY_TYPE_CODES[key_type]
    pubkey_bytes = bytes.fromhex(pubkey_hex)
    # libp2p PublicKey protobuf: field 1 (Type, varint) + field 2 (Data, bytes)
    protobuf = bytes([0x08, key_type_code, 0x12]) + encode_varint(len(pubkey_bytes)) + pubkey_bytes
    # multihash with the "identity" function (0x00) since protobuf <= 42 bytes
    multihash = encode_varint(0x00) + encode_varint(len(protobuf)) + protobuf
    return base58_encode(multihash)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in KEY_TYPE_CODES:
        print("Usage: derive-peer-id.py <ed25519|secp256k1> <hex-pubkey>", file=sys.stderr)
        sys.exit(1)
    print(derive_peer_id(sys.argv[1], sys.argv[2]))


if __name__ == "__main__":
    main()
