#!/usr/bin/env python3
"""Repeat the v0.3 Darkroom contract, renderer, persistence and focused native UI checks.

Requires the existing UI-check simulator to be booted. No second Xcode project or device install.
"""
import json
import os
from pathlib import Path
import subprocess
import time

import localization

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = Path('/private/tmp/spektrafilm-build')
XCODE = Path('/Applications/Xcode.app/Contents/Developer')
SIMULATOR = '5208EE70-99A9-46FB-827E-8AC10F2B547B'


def main():
    env = os.environ.copy()
    env['DEVELOPER_DIR'] = str(XCODE)
    env.setdefault('SPEKTRACAM_SIMULATOR_ID', SIMULATOR)
    devices = json.loads(subprocess.check_output(
        [str(XCODE / 'usr/bin/simctl'), 'list', 'devices', 'available', '--json'], env=env, text=True))
    if not any(d['udid'] == env['SPEKTRACAM_SIMULATOR_ID'] and d['state'] == 'Booted'
               for group in devices['devices'].values() for d in group):
        raise SystemExit('Boot SpektraCam UI Checks first, or set SPEKTRACAM_SIMULATOR_ID to a booted simulator.')

    catalogs, refs = localization.catalogs(), localization.source_refs()
    strings = catalogs['Localizable']['strings']
    assert not set(refs) - set(strings), 'Source has missing localization keys'
    known_unused = {'%lld px', 'about.preview', 'export.this_may_take_longer_if_memory_runs',
                    'export.try_export_anyway', 'export.try_export_anyway_7304a4'}
    unused = {k for k, entry in strings.items() if entry.get('shouldTranslate', True)} - set(refs)
    assert not unused - known_unused, f'New unused messages: {unused - known_unused}'
    for key in refs:
        if key.startswith('darkroom.'):
            for language in ['en', 'zh-Hans']:
                assert strings[key]['localizations'][language]['stringUnit']['value'], (key, language)
    print('PASS: Darkroom English/Chinese source coverage; five legacy unused keys allowed', flush=True)

    def native(*checks, simulator=False):
        subprocess.run(['python3', str(ROOT / 'Scripts/core-checks.py'), *checks]
                       + (['--simulator'] if simulator else []), cwd=ROOT, env=env, check=True)

    native('recipe', 'darkroom', 'metal-film', 'geometry', 'source', 'library')
    native('film-edge', 'darkroom-orientation', 'editor-session-benchmark', simulator=True)
    OUTPUT.mkdir(exist_ok=True)
    stamp = str(time.time_ns())
    result = OUTPUT / ('darkroom-workflow-' + stamp + '.xcresult')
    log = OUTPUT / ('darkroom-workflow-' + stamp + '.log')
    command = [str(XCODE / 'usr/bin/xcodebuild'), '-project', str(ROOT / 'SpektraCam.xcodeproj'),
               '-scheme', 'SpektraCam', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
               '-destination', 'id=' + env['SPEKTRACAM_SIMULATOR_ID'], '-derivedDataPath', str(OUTPUT),
               'CODE_SIGNING_ALLOWED=NO', '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(result)]
    for test in ['testDarkroomPortraitPaperFollowsCrop', 'testFilmEdgeSelectionExportAndRestart', 'testDarkroomLayoutHistoryAndReopening',
                 'testDarkroomChineseLargeText', 'testWorkspaceToolbarAndSharedPills',
                 'testExportOptionsAndCancellation']:
        command.append('-only-testing:SpektraCamUITests/EditorInteractionTests/' + test)
    command.append('test')
    print('UI result:', result, flush=True)
    with log.open('w') as stream:
        status = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT)
    for line in log.read_text().splitlines():
        if any(key in line for key in [': error:', ': warning:', 'Test Case', 'Executed', '** TEST']):
            print(line)
    print('UI log:', log)
    if status.returncode:
        raise SystemExit(status.returncode)
    print('PASS: complete first Darkroom workflow. Visually inspect xcresult attachments before signing off.')


if __name__ == '__main__':
    main()
