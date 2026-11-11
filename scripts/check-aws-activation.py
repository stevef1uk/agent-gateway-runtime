#!/usr/bin/env python3
"""Verify signed licences locally without AWS calls or container decryption."""
import argparse
import base64
import datetime
import json
import pathlib
import re
import subprocess
import tempfile

SERVICES = ('authz', 'tokensvc', 'gateway', 'web')
MAX_MATERIAL_SIZE = 64 * 1024


def _check_public_key(path):
    try:
        result = subprocess.run(
            ['openssl', 'pkey', '-pubin', '-in', str(path), '-noout'],
            capture_output=True,
            timeout=10,
        )
    except FileNotFoundError as error:
        raise ValueError('OpenSSL is required to validate the vendor public key.') from error
    except subprocess.TimeoutExpired as error:
        raise ValueError('OpenSSL timed out while validating the vendor public key.') from error
    except OSError as error:
        raise ValueError('OpenSSL could not validate the vendor public key.') from error
    if result.returncode:
        raise ValueError('Vendor public key is missing or invalid.')


def _verify_customer_key(path):
    try:
        result = subprocess.run(
            ['openssl', 'pkey', '-in', str(path), '-noout', '-passin', 'pass:'],
            capture_output=True,
            timeout=10,
        )
    except FileNotFoundError as error:
        raise ValueError('OpenSSL is required to validate the customer key used by Emotion.') from error
    except subprocess.TimeoutExpired as error:
        raise ValueError('OpenSSL timed out while validating the customer key used by Emotion.') from error
    except OSError as error:
        raise ValueError('OpenSSL could not validate the customer key used by Emotion.') from error
    if result.returncode:
        raise ValueError('Customer private key used by Emotion is missing, encrypted or invalid.')


def verify_signed_licence(token_file, vendor_public_key, service, today=None):
    path = pathlib.Path(token_file)
    try:
        token = path.read_bytes()
    except OSError as error:
        raise ValueError(f'{service}.token is missing or unreadable.') from error
    if not token or len(token) > MAX_MATERIAL_SIZE:
        raise ValueError(f'{service}.token is empty or too large.')
    try:
        envelope = base64.b64decode(token.strip(), altchars=b'-_', validate=True)
        fields = envelope.decode('utf-8').split(':')
        if len(fields) != 5 or not fields[1] or not fields[2] or fields[3] != 'NOFERNET':
            raise ValueError()
        expiry = datetime.date.fromisoformat(fields[0])
        if expiry.isoformat() != fields[0]:
            raise ValueError()
        signature = base64.b64decode(fields[4], altchars=b'-_', validate=True)
        if not signature:
            raise ValueError()
    except (ValueError, UnicodeError) as error:
        raise ValueError(f'{service}.token is malformed; obtain a genuine vendor-issued signed licence.') from error
    if expiry <= (today or datetime.datetime.now(datetime.timezone.utc).date()):
        raise ValueError(f'{service}.token expired on {expiry}; obtain a renewed vendor-issued licence.')

    with tempfile.TemporaryDirectory(prefix='agw-license-check-') as directory:
        payload_path = pathlib.Path(directory) / 'payload'
        signature_path = pathlib.Path(directory) / 'signature'
        payload_path.write_bytes(':'.join(fields[:4]).encode('utf-8'))
        signature_path.write_bytes(signature)
        try:
            result = subprocess.run(
                [
                    'openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', str(vendor_public_key),
                    '-rawin', '-digest', 'sha256', '-in', str(payload_path),
                    '-sigfile', str(signature_path), '-pkeyopt', 'rsa_padding_mode:pss',
                    '-pkeyopt', 'rsa_pss_saltlen:auto',
                ],
                capture_output=True,
                timeout=10,
            )
        except FileNotFoundError as error:
            raise ValueError('OpenSSL is required to verify vendor licence signatures.') from error
        except subprocess.TimeoutExpired as error:
            raise ValueError(f'OpenSSL timed out while verifying {service}.token.') from error
        except OSError as error:
            raise ValueError(f'OpenSSL could not verify {service}.token.') from error
    if result.returncode:
        raise ValueError(f'{service}.token has an invalid vendor signature.')
    return expiry


def validate_release_images(release_file):
    try:
        manifest = json.loads(pathlib.Path(release_file).read_text())
        images = manifest['images']
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise ValueError('Selected AWS release manifest does not contain the four product images.') from error
    if not isinstance(images, dict):
        raise ValueError('Selected AWS release manifest does not contain the four product images.')
    for service in SERVICES:
        item = images.get(service)
        image = item.get('immutable_image') if isinstance(item, dict) else None
        expected = rf'stevef1uk/agent-gateway-{service}_l@sha256:[0-9a-f]{{64}}'
        if not isinstance(image, str) or not re.fullmatch(expected, image):
            raise ValueError(f'Selected AWS release has no valid immutable {service} image.')


def validate(key_file, vendor_public_key, licence_dir, release_file):
    _verify_customer_key(key_file)
    _check_public_key(vendor_public_key)
    validate_release_images(release_file)
    for service in SERVICES:
        verify_signed_licence(pathlib.Path(licence_dir) / f'{service}.token', vendor_public_key, service)
    print('Customer key, signed licence tokens, and release image references passed local checks.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key', required=True, type=pathlib.Path, help='Customer private key used only by the optional Emotion backend.')
    parser.add_argument('--vendor-public-key', required=True, type=pathlib.Path)
    parser.add_argument('--licences', required=True, type=pathlib.Path)
    parser.add_argument('--release', required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        validate(args.key, args.vendor_public_key, args.licences, args.release)
    except ValueError as error:
        raise SystemExit(str(error))


if __name__ == '__main__':
    main()
