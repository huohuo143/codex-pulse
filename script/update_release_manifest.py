#!/usr/bin/env python3
"""Prepare quota-independent update metadata from an already-published release.
Run after verifying every release attachment, then commit updates/latest.json.
Uses the maintainer's existing gh login; the app never reads GitHub credentials.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

REPOSITORY = 'huohuo143/codex-pulse'
BASE = 'https://github.com/' + REPOSITORY

def version(value):
    match = re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)', value or '')
    if not match:
        raise ValueError('Expected a stable semantic version')
    return tuple(map(int, match.groups()))

def prepare(release):
    tag = release['tag_name']
    version(tag)
    if release.get('draft') or release.get('prerelease') or not release.get('published_at'):
        raise ValueError('Only a published stable release may enter the public manifest')
    if release.get('html_url') != BASE + '/releases/tag/' + tag:
        raise ValueError('Release page does not belong to this repository and tag')
    assets = []
    for item in release.get('assets', []):
        if item.get('state') != 'uploaded':
            raise ValueError('A release attachment has not finished uploading')
        url = item['browser_download_url']
        parsed = urlsplit(url)
        if parsed.scheme != 'https' or parsed.hostname != 'github.com' or parsed.username or parsed.password or not url.startswith(BASE + '/releases/download/' + tag + '/'):
            raise ValueError('Attachment address is outside this repository and tag')
        assets.append({key: item[key] for key in ['name', 'browser_download_url', 'size', 'state']})
    if not assets:
        raise ValueError('Release has no completed attachments')
    result = {key: release.get(key) for key in ['tag_name', 'name', 'body', 'html_url', 'published_at', 'draft', 'prerelease']}
    result['schemaVersion'] = 1
    result['assets'] = assets
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', type=Path, default=Path('updates/latest.json'))
    args = parser.parse_args()
    version(args.tag)
    release = json.loads(subprocess.check_output(['gh', 'api', 'repos/' + REPOSITORY + '/releases/tags/' + args.tag], text=True))
    result = prepare(release)
    if args.output.exists():
        current = json.loads(args.output.read_text())
        if version(current.get('tag_name')) > version(result['tag_name']):
            raise ValueError('Refusing to replace a newer manifest with an older release')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(args.output)
    print('Prepared ' + result['tag_name'] + ' metadata: ' + str(args.output))

if __name__ == '__main__':
    main()
