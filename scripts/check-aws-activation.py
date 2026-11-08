#!/usr/bin/env python3
"""Reject placeholder, malformed or expired activation files without AWS calls."""
import argparse,base64,datetime,pathlib,subprocess

def validate(key_file,licence_dir):
    try:
        check=subprocess.run(['openssl','pkey','-in',str(key_file),'-noout','-passin','pass:'],capture_output=True,timeout=10)
    except (OSError,subprocess.TimeoutExpired):
        raise ValueError('OpenSSL is required to validate the customer private key.')
    if check.returncode:
        raise ValueError('Customer private key is missing, encrypted or invalid. Replace example files with the vendor-compatible customer key.')
    today=datetime.datetime.now(datetime.timezone.utc).date()
    for service in ['authz','tokensvc','gateway','web']:
        path=pathlib.Path(licence_dir)/(service+'.token')
        try:
            envelope=path.read_text().strip().split(':',1)[0]
            decoded=base64.urlsafe_b64decode(envelope+'='*(-len(envelope)%4)).decode()
            fields=decoded.split(':')
            expiry=datetime.date.fromisoformat(fields[0])
            if len(fields)<5 or not fields[-1]: raise ValueError()
        except (OSError,ValueError,UnicodeError):
            raise ValueError(f'{service}.token is missing or malformed. Obtain a genuine vendor-issued licence; example tokens cannot start the application.')
        if expiry<=today:
            raise ValueError(f'{service}.token expired on {expiry}; obtain a renewed vendor-issued licence.')
    print('Activation file structure and expiry checks passed; runtime still verifies vendor signatures and image compatibility.')

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--key',required=True,type=pathlib.Path);p.add_argument('--licences',required=True,type=pathlib.Path);a=p.parse_args()
    try: validate(a.key,a.licences)
    except ValueError as error:raise SystemExit(str(error))
if __name__=='__main__':main()
