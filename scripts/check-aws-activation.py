#!/usr/bin/env python3
"""Reject invalid activation files or key/licence/image mismatches without AWS calls."""
import argparse
import base64
import datetime
import json
import pathlib
import re
import subprocess

SERVICES = ('authz', 'tokensvc', 'gateway', 'web')


def verify_image_activation(key_file, licence_dir, release_file):
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

        licence_file = pathlib.Path(licence_dir) / f'{service}.token'
        command = [
            'docker', 'run', '--rm', '--platform', 'linux/arm64', '--network', 'none',
            '--read-only', '--tmpfs', '/tmp:rw,nosuid,size=64m',
            '--entrypoint', '/usr/local/bin/unpack',
            '-v', f'{pathlib.Path(key_file).resolve()}:/tmp/customer.key:ro',
            '-v', f'{licence_file.resolve()}:/tmp/license.token:ro',
            image,
            '-zip', '/app/service.enc', '-priv', '/tmp/customer.key',
            '-license-token', '/tmp/license.token', '-out', '/tmp/out', '-work', '/tmp/work',
        ]
        try:
            result = subprocess.run(command, capture_output=True, timeout=300)
        except FileNotFoundError as error:
            raise ValueError('Docker is required to verify activation against the selected release images.') from error
        except subprocess.TimeoutExpired as error:
            raise ValueError(f'{service} image activation check timed out; verify Docker can pull and run ARM64 images.') from error
        except OSError as error:
            raise ValueError(f'Docker could not verify activation for the {service} image.') from error
        if result.returncode:
            raise ValueError(
                f'{service} image activation failed with the configured customer key and licence. '
                'Use the matching customer key and vendor-issued service licences for this release.'
            )


def validate(key_file, licence_dir, release_file):
    try:
        check = subprocess.run(
            ['openssl', 'pkey', '-in', str(key_file), '-noout', '-passin', 'pass:'],
            capture_output=True,
            timeout=10,
        )
    except FileNotFoundError as error:
        raise ValueError('OpenSSL is required to validate the customer private key.') from error
    except subprocess.TimeoutExpired as error:
        raise ValueError('OpenSSL timed out while validating the customer private key.') from error
    except OSError as error:
        raise ValueError('OpenSSL could not validate the customer private key.') from error
    if check.returncode:
        raise ValueError('Customer private key is missing, encrypted or invalid. Replace example files with the vendor-compatible customer key.')

    today = datetime.datetime.now(datetime.timezone.utc).date()
    for service in SERVICES:
        path = pathlib.Path(licence_dir) / f'{service}.token'
        try:
            envelope = path.read_text().strip().split(':', 1)[0]
            decoded = base64.urlsafe_b64decode(envelope + '=' * (-len(envelope) % 4)).decode()
            fields = decoded.split(':')
            expiry = datetime.date.fromisoformat(fields[0])
            if len(fields) < 5 or not fields[-1]:
                raise ValueError()
        except (OSError, ValueError, UnicodeError):
            raise ValueError(f'{service}.token is missing or malformed. Obtain a genuine vendor-issued licence; example tokens cannot start the application.')
        if expiry <= today:
            raise ValueError(f'{service}.token expired on {expiry}; obtain a renewed vendor-issued licence.')

    verify_image_activation(key_file, licence_dir, release_file)
    print('Activation structure, expiry and release image compatibility checks passed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key', required=True, type=pathlib.Path)
    parser.add_argument('--licences', required=True, type=pathlib.Path)
    parser.add_argument('--release', required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        validate(args.key, args.licences, args.release)
    except ValueError as error:
        raise SystemExit(str(error))


if __name__ == '__main__':
    main()
