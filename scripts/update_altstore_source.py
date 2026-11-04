#!/usr/bin/env python3
"""Regenerate altstore.json from this fork's GitHub Releases.

Run by .github/workflows/build-and-release.yml after each release; can also
be run locally (needs `gh` authenticated). Rules:
- Only fork releases (tags v<version>-fork.<n>) with an -unsigned.ipa asset.
- One entry per app version: the highest fork.<n> wins (older fork builds of
  the same upstream version are superseded).
- Keep the newest 5 app versions.
- minOSVersion: preserved from the existing altstore.json entry when the
  version is already listed, otherwise read from the project's
  IPHONEOS_DEPLOYMENT_TARGET (so the fork's lowered floor survives upstream
  syncs, which never touch this file or the deployment-target line unless
  upstream edits that exact line).
"""
import json
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
SOURCE_PATH = root / 'altstore.json'
PROJECT_PATH = root / 'SpektraCam.xcodeproj' / 'project.xcproj'
MAX_VERSIONS = 5
BUNDLE_ID = 'io.github.runzeni.andreavolpato-spektrafilm'
ICON = ('https://raw.githubusercontent.com/lukaschan/SpektraCam'
        '/refs/heads/main/assets/app-icon.png')


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def repo_slug():
    remote = run('git', '-C', str(root), 'remote', 'get-url', 'origin').strip()
    m = re.search(r'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$', remote)
    if not m:
        raise SystemExit('cannot infer GitHub repo from origin remote')
    return f'{m.group(1)}/{m.group(2)}'


def deployment_target():
    text = PROJECT_PATH.read_text()
    m = re.search(r'"IPHONEOS_DEPLOYMENT_TARGET":\s*"([0-9.]+)"', text)
    return m.group(1) if m else '26.0'


def existing_min_os():
    if not SOURCE_PATH.exists():
        return {}
    try:
        data = json.loads(SOURCE_PATH.read_text())
        return {v['version']: v.get('minOSVersion')
                for app in data.get('apps', [])
                for v in app.get('versions', [])}
    except Exception:
        return {}


def collect_versions(slug):
    raw = run('gh', 'api', f'repos/{slug}/releases', '--paginate')
    releases = json.loads(raw)
    best = {}  # version -> (fork_n, entry)
    for rel in releases:
        m = re.match(r'^v(.+)-fork\.(\d+)$', rel.get('tag_name', ''))
        if not m or rel.get('draft'):
            continue
        version, fork_n = m.group(1), int(m.group(2))
        asset = next((a for a in rel.get('assets', [])
                      if a['name'].endswith('-unsigned.ipa')), None)
        if not asset:
            continue
        entry = {
            'version': version,
            'date': (rel.get('published_at') or '')[:10],
            'localizedDescription': (rel.get('body') or '').strip()[:500]
                                    or f'SpektraCam {version}（fork 自动构建）',
            'downloadURL': asset['browser_download_url'],
            'size': asset['size'],
            '_published': rel.get('published_at') or '',
            '_fork_n': fork_n,
        }
        if version not in best or fork_n > best[version]['_fork_n']:
            best[version] = entry
    versions = sorted(best.values(), key=lambda e: e['_published'],
                      reverse=True)[:MAX_VERSIONS]
    return versions


def main():
    slug = repo_slug()
    min_os_by_version = existing_min_os()
    default_min_os = deployment_target()
    versions = collect_versions(slug)
    if not versions:
        raise SystemExit('no fork releases with an unsigned IPA found')
    for v in versions:
        v['minOSVersion'] = (min_os_by_version.get(v['version'])
                             or default_min_os)
        del v['_published'], v['_fork_n']
    source = {
        'name': 'SpektraCam (fork)',
        'identifier': 'com.lukaschan.spektracam.source',
        'subtitle': 'SpektraCam 的 AltStore 订阅源（fork 自动构建）',
        'description': ('上游 runzeni/SpektraCam 的 fork 订阅源：未签名 IPA 随 '
                        'GitHub Release 自动更新，最低系统已降至 iOS 26.0，'
                        '可用于 AltStore、SideStore 等兼容应用。'),
        'iconURL': ICON,
        'website': f'https://github.com/{slug}',
        'apps': [{
            'name': 'SpektraCam',
            'bundleIdentifier': BUNDLE_ID,
            'developerName': 'runzeni（fork 构建：lukaschan）',
            'subtitle': '胶片模拟照片编辑器 · spektrafilm 原生移植',
            'localizedDescription': ('基于 spektrafilm 的 iPhone 照片编辑器：胶片与印相模拟、'
                                     '裁剪、调整、颗粒、光晕与柔光，支持 .cube LUT 与 RAW 拍摄。'
                                     'fork 版最低支持 iOS 26.0。'),
            'iconURL': ICON,
            'versions': versions,
        }],
    }
    text = json.dumps(source, ensure_ascii=False, indent=2) + '\n'
    if SOURCE_PATH.exists() and SOURCE_PATH.read_text() == text:
        print('altstore.json unchanged')
        return
    SOURCE_PATH.write_text(text)
    print(f'altstore.json updated: {len(versions)} version(s), '
          f'latest {versions[0]["version"]}')


if __name__ == '__main__':
    sys.exit(main())
