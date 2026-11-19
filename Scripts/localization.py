#!/usr/bin/env python3
"""Review native String Catalogs in Markdown. Blank cells never become translations."""
import argparse
import copy
import hashlib
import html
import json
import pathlib
import os
import subprocess
import re
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / 'SpektraCam'
RESOURCES = APP / 'Resources'
TABLES = ('Localizable', 'InfoPlist')
KEY = re.compile(r'String\s*\(\s*localized:\s*"([^"\n]+)"')
FORMAT = re.compile(r'%(?:(\d+)\$)?([-+#0 \']*(?:\d+)?(?:\.\d+)?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp])')


def catalogs():
    return {name: json.loads((RESOURCES / (name + '.xcstrings')).read_text()) for name in TABLES}


def source_refs():
    refs = {}
    for path in sorted(APP.rglob('*.swift')):
        text = path.read_text()
        for match in KEY.finditer(text):
            refs.setdefault(match[1], []).append((path.relative_to(APP).as_posix(), text.count('\n', 0, match.start()) + 1))
    return refs


def english(entry):
    node = entry['localizations']['en']
    if 'stringUnit' in node:
        return node['stringUnit']['value']
    return node['variations']['plural']['other']['stringUnit']['value']


def chinese(entry):
    node = entry.get('localizations', {}).get('zh-Hans', {})
    return node.get('stringUnit', node.get('variations', {}).get('plural', {}).get('other', {}).get('stringUnit', {})).get('value', '')


def fingerprint(entry):
    def values(node):
        return {key: values(value) if isinstance(value, dict) else value for key, value in node.items() if key != 'state'}
    payload = {'en': values(entry['localizations']['en']), 'context': entry.get('comment', '')}
    return hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:16]


def inventory(data):
    return {table + '/' + key: entry for table, catalog in data.items() for key, entry in catalog['strings'].items() if entry.get('shouldTranslate', True)}


def encode(text):
    return html.escape(text, quote=False).replace('|', '&#124;').replace('\n', '<br>')


def decode(text):
    return html.unescape(text.replace('<br>', '\n').replace('\\|', '|'))


def read_rows(path):
    rows = {}
    for line in path.read_text().splitlines():
        if not line.startswith('| `'):
            continue
        cells = re.split(r'(?<!\\)\|', line)[1:-1]
        if len(cells) != 4:
            raise ValueError('Each row must have four cells. Escape a literal pipe as &#124;.')
        key = cells[0].strip().strip('`')
        if key in rows:
            raise ValueError('Duplicate key: ' + key)
        marker = re.search(r'<!-- source:([a-f0-9]{16}) -->', cells[3])
        if not marker:
            raise ValueError('Missing source marker: ' + key)
        rows[key] = (decode(cells[1].strip()), decode(cells[2].strip()), marker[1])
    if not rows:
        raise ValueError('The worksheet has no translation rows.')
    return rows


def placeholders(text):
    if text == '%':  # A unit label, not a formatted message.
        return []
    result = []
    sequential = 0
    offset = 0
    while offset < len(text):
        if text[offset] != '%':
            offset += 1
            continue
        if text.startswith('%%', offset):
            offset += 2
            continue
        match = FORMAT.match(text, offset)
        if not match:
            raise ValueError('Unknown format token. Keep source placeholders; use %% for a literal percent.')
        sequential += 1
        result.append((int(match[1]) if match[1] else sequential, match[2]))
        offset = match.end()
    return sorted(result)


def validate_rows(entries, rows):
    if set(rows) != set(entries):
        missing = set(entries) - set(rows)
        extra = set(rows) - set(entries)
        raise ValueError(f'Worksheet keys differ: {len(missing)} missing, {len(extra)} obsolete. Export a new worksheet first.')
    for key, (source, target, stamp) in rows.items():
        entry = entries[key]
        if source != english(entry) or stamp != fingerprint(entry):
            raise ValueError('English or context changed; review this row before import: ' + key)
        if target and placeholders(source) != placeholders(target):
            raise ValueError('Placeholder mismatch: ' + key)


def verify_sources(data, extracted=None):
    refs = source_refs()
    local = data['Localizable']['strings']
    missing = set(refs) - set(local)
    unused = {key for key, entry in local.items() if entry.get('shouldTranslate', True)} - set(refs)
    if missing or unused:
        raise ValueError(f'Catalog/source mismatch: {len(missing)} missing, {len(unused)} unused keys.')
    project = (ROOT / 'SpektraCam.xcodeproj/project.xcproj').read_text()
    permissions = dict(re.findall(r'"INFOPLIST_KEY_(NS\w+UsageDescription)": "([^"]*)"', project))
    for key, entry in data['InfoPlist']['strings'].items():
        if not entry.get('shouldTranslate', True):
            continue
        if key.startswith('NS') and key.endswith('UsageDescription') and permissions.get(key) != english(entry):
            raise ValueError('Permission explanation changed: ' + key)
    if extracted:
        seen = {}
        for path in pathlib.Path(extracted).glob('*.stringsdata'):
            document = json.loads(path.read_text())
            source = pathlib.Path(document['source'])
            if not source.is_relative_to(APP) or not source.exists():
                continue
            items = document.get('tables', {}).get('Localizable', [])
            active = [item for item in items if item['key'] in refs]
            for item in active:
                if item.get('value', item['key']) != english(local[item['key']]):
                    raise ValueError('Default English and catalog differ; align them and refresh the worksheet: ' + item['key'])
                seen[item['key']] = True
        if set(seen) != set(refs):
            raise ValueError('Build before import; compiler extraction is incomplete.')
    return refs


def build_for_import(extracted):
    build = next((path for path in extracted.parents if path.name == 'Build'), None)
    if build is None or 'Release-iphoneos' not in extracted.parts:
        raise ValueError('Use the Release-iphoneos stringsdata directory from the native build.')
    developer = '/Applications/Xcode.app/Contents/Developer'
    env = dict(os.environ, DEVELOPER_DIR=developer)
    log = pathlib.Path(tempfile.gettempdir()) / 'spektracam-localization-import-build.log'
    command = [developer + '/usr/bin/xcodebuild', '-project', str(ROOT / 'SpektraCam.xcodeproj'),
               '-scheme', 'SpektraCam', '-configuration', 'Release',
               '-destination', 'generic/platform=iOS', '-derivedDataPath', str(build.parent),
               'CODE_SIGNING_ALLOWED=NO', 'build']
    print('Refresh compiler extraction with a native build. Log:', log, flush=True)
    with log.open('w') as output:
        result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ValueError('Native build failed; no translations were imported. Read ' + str(log))


INTRO = '''---
updated: 2026-11-02
source_language: en
target_language: zh-Hans
---
# SpektraCam · English → 简体中文

Translate only the **简体中文** column. Use this sheet for Chinese edits; do not edit it and the catalog in parallel. Leave cells blank until you have reviewed them. Do not change keys, English or the hidden source markers. Rows may move; keys identify messages. Source line numbers are navigation hints, not identity. In Xcode, Find in Workspace for the key after `Localizable/` to find every use.

## Workflow

1. Fill this sheet in Obsidian. Save the file. No automatic translation or app update occurs.
2. Ask Codex to check and import it. Import first refreshes compiler extraction, then rejects missing/duplicate keys, changed English/context, catalog/default-value drift and changed placeholders. Blank cells are never imported as empty text.
3. Build and check English and Chinese on iPhone: normal/large text, VoiceOver, permission prompts, counts, errors and all editor panels. Chinese is not ready to ship until review is complete.

Use iOS’s per-app language choice once both languages are ready; no custom language picker or translation service is needed.

The native `.xcstrings` files under app `Resources` are the app source of truth; this is a generated review sheet. English `defaultValue` stays beside each permanent key in Swift. The importer first builds to refresh compiler extraction; it does not trust file timestamps. English edits keep the key and require translation review. Moving files or lines does not change the key. Never translate recipe IDs, enum raw values, symbols, filenames, URLs or model data.

Keep placeholders such as `%@`, `%lld`, `%llu` and `%.0f`. To reorder different arguments, use numbered forms: `%1$@`, `%2$lld`. Do not translate the placeholder itself. Use `%%` for a literal percent in a formatted message. Keep technical units (EV, K, µm, µm², px, CC), ratios and product names. Use `&#124;` for a literal pipe inside a cell. English plurals are shown in context; Chinese uses the `other` form only. The marker covers all English plural forms.

Terms: **Develop** means photographic film processing; **Print** means photographic paper/print film. **Density** is optical density. **Halation** is colored highlight scatter; **Diffusion** is optical light spread. **Lift/Gain** currently contains Highlights/Shadows, not Resolve color wheels. **Rendered** means non-RAW. **B&W Grain** changes grain only. Delete/Revert affect app copies/edits, not Photos originals. Set your own Chinese terms; none are prefilled.

Apple recommends [String Catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) and [comments/context](https://developer.apple.com/documentation/xcode/preparing-your-apps-text-for-translation). Xcode can also [export/import XLIFF](https://developer.apple.com/documentation/xcode/exporting-localizations) if a translator joins later. We use English (`en`) and Simplified Chinese (`zh-Hans`); Traditional Chinese is a separate localization. Native Photos/Files/share interfaces and system prompt buttons are translated by iOS. This sheet covers app text, generated parameter labels, errors, accessibility and permission explanations. Stock/product names, data/units, diagnostics and system text are excluded. Generated parameter labels include advanced or currently hidden controls.

Commands for Codex, from the repo:

```sh
python3 Scripts/localization.py export --worksheet <this-file>
python3 Scripts/localization.py check --worksheet <this-file>
python3 Scripts/localization.py import --worksheet <this-file> --extracted <fresh-stringsdata-directory>
# Import is a dry run. Add --apply only after review. Full coverage is required unless --allow-partial is explicit.
```

## Translation table

'''


def refresh_review_sheet(text, rendered):
    """Update owned rows only. Keep the reviewer's prose, checklist and row order."""
    pending = dict(rendered)
    lines = []
    for line in text.splitlines(keepends=True):
        if line.startswith('| `'):
            key = line.split('|', 2)[1].strip().strip('`')
            if key in pending:
                lines.append(pending.pop(key) + '\n')
            # A removed blank row can go; translated removed rows are rejected first.
        else:
            lines.append(line)
    result = ''.join(lines)
    if pending:
        start = result.find('## Translation table')
        following = re.search(r'^## ', result[start + len('## Translation table'):] if start >= 0 else '', re.M)
        offset = start + len('## Translation table') + following.start() if following else len(result)
        added = '\n### Added messages\n\n| Key | English | 简体中文 | Context / source |\n| --- | --- | --- | --- |\n'
        added += '\n'.join(pending.values()) + '\n\n'
        result = result[:offset].rstrip('\n') + '\n' + added + result[offset:]
    return result


def export_sheet(data, path):
    entries = inventory(data)
    refs = verify_sources(data)
    old = read_rows(path) if path.exists() else {}
    for key, (source, target, stamp) in old.items():
        if target and (key not in entries or source != english(entries[key]) or stamp != fingerprint(entries[key])):
            raise ValueError('Keep the existing sheet and review the changed/removed translated row: ' + key)
    lines = [INTRO, f'{len(entries)} app-owned messages. All Chinese cells are blank in the initial export.\n']
    rendered = {}
    group = None
    for key, entry in entries.items():
        table, native_key = key.split('/', 1)
        section = 'Permissions' if table == 'InfoPlist' else native_key.split('.')[0].replace('_', ' ').title()
        if section != group:
            lines += ['\n### ' + section, '\n| Key | English | 简体中文 | Context / source |', '| --- | --- | --- | --- |']
            group = section
        context = entry.get('comment', '')
        plural = entry['localizations']['en'].get('variations', {}).get('plural')
        if plural:
            context += ' English one: ' + plural['one']['stringUnit']['value']
            if not context.endswith(('.', '?', '!')): context += '.'
        uses = refs.get(native_key, [])
        if uses:
            filename, line = uses[0]
            context += f' Source: {filename}:{line} ({len(uses)} use' + ('s).' if len(uses) != 1 else ').')
        elif native_key.startswith('NS') and native_key.endswith('UsageDescription'):
            context += ' Source: project.xcproj / INFOPLIST_KEY_' + native_key + '.'
        else:
            context += ' Source: Configuration/SpektraCam-Info.plist (document/type description).'
        target = old.get(key, ('', '', ''))[1] or chinese(entry)
        rendered[key] = f'| `{key}` | {encode(english(entry))} | {encode(target)} | {encode(context)} <!-- source:{fingerprint(entry)} --> |'
        lines.append(rendered[key])
    output = refresh_review_sheet(path.read_text(), rendered) if old else '\n'.join(lines) + '\n'
    path.write_text(output)
    print(f'Exported {len(entries)} rows; preserved reviewed cells and notes.')


def import_sheet(data, rows):
    result = copy.deepcopy(data)
    for key, (_, target, _) in rows.items():
        if not target:
            continue
        table, native_key = key.split('/', 1)
        entry = result[table]['strings'][native_key]
        unit = {'stringUnit': {'state': 'translated', 'value': target}}
        entry['localizations']['zh-Hans'] = {'variations': {'plural': {'other': unit}}} if 'variations' in entry['localizations']['en'] else unit
    return result


def self_test():
    entry = {'comment': 'Count', 'localizations': {'en': {'stringUnit': {'state': 'translated', 'value': '%@ / %lld'}}}}
    entries = {'Localizable/test.message': entry}
    good = ('%@ / %lld', '%2$lld / %1$@', fingerprint(entry))
    validate_rows(entries, {'Localizable/test.message': good})
    for bad in [('%@ / %lld', '%@', fingerprint(entry)), ('%@ / %lld', '%@ / %lld %n', fingerprint(entry)), ('Changed', '%@ / %lld', fingerprint(entry)), ('%@ / %lld', '%@ / %lld', '0'*16)]:
        try:
            validate_rows(entries, {'Localizable/test.message': bad})
        except ValueError:
            pass
        else:
            raise AssertionError('Unsafe import was accepted')
    assert placeholders('%') == []
    assert placeholders('%.0f percent zoom') == placeholders('缩放 %.0f%%')
    assert decode(encode('A | B\n<source> & text')) == 'A | B\n<source> & text'
    notes = '# Human notes\n\n## Translation table\n\n| `Localizable/b` | old | 乙 | context |\n> Keep this note.\n| `Localizable/a` | old | 甲 | context |\n\n## 待确认清单\n\n- Final human choice.\n'
    refreshed = refresh_review_sheet(notes, {'Localizable/a': '| `Localizable/a` | new | 甲 | context |',
                                            'Localizable/b': '| `Localizable/b` | new | 乙 | context |',
                                            'Localizable/c': '| `Localizable/c` | new | 丙 | context |'})
    assert refreshed.startswith('# Human notes\n\n## Translation table\n')
    assert '> Keep this note.\n' in refreshed
    assert refreshed.endswith('## 待确认清单\n\n- Final human choice.\n')
    assert refreshed.index('`Localizable/b`') < refreshed.index('`Localizable/a`') < refreshed.index('`Localizable/c`') < refreshed.index('## 待确认清单')
    assert refresh_review_sheet(refreshed, {'Localizable/' + key: '| `Localizable/' + key + '` | new | ' + target + ' | context |' for key, target in [('a', '甲'), ('b', '乙'), ('c', '丙')]}) == refreshed
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / 'sheet.md'
        line = '| `Localizable/test.message` | %@ / %lld | | Context <!-- source:' + fingerprint(entry) + ' --> |\n'
        path.write_text(line + line)
        try:
            read_rows(path)
        except ValueError:
            pass
        else:
            raise AssertionError('Duplicate rows were accepted')
    data = {'Localizable': {'strings': {'test.message': entry}}}
    blank = {'Localizable/test.message': ('%@ / %lld', '', fingerprint(entry))}
    assert import_sheet(data, blank) == data
    translated = import_sheet(data, {'Localizable/test.message': good})
    assert translated['Localizable']['strings']['test.message']['localizations']['zh-Hans']['stringUnit']['value'] == good[1]
    # Identical English with different meanings must follow IDs, never row order or wording.
    first = {'comment': 'Aspect ratio', 'localizations': {'en': {'stringUnit': {'state': 'translated', 'value': 'Original'}}}}
    second = {'comment': 'Source file', 'localizations': {'en': {'stringUnit': {'state': 'translated', 'value': 'Original'}}}}
    separate = {'Localizable/aspect.original': first, 'Localizable/photo.original': second}
    reversed_rows = {'Localizable/photo.original': ('Original', 'PHOTO_TEST', fingerprint(second)),
                     'Localizable/aspect.original': ('Original', 'ASPECT_TEST', fingerprint(first))}
    validate_rows(separate, reversed_rows)
    translated = import_sheet({'Localizable': {'strings': {'aspect.original': first, 'photo.original': second}}}, reversed_rows)
    assert chinese(translated['Localizable']['strings']['aspect.original']) == 'ASPECT_TEST'
    assert chinese(translated['Localizable']['strings']['photo.original']) == 'PHOTO_TEST'
    plural = {'comment': 'Count', 'localizations': {'en': {'variations': {'plural': {
        'one': {'stringUnit': {'state': 'translated', 'value': '%lld photo'}},
        'other': {'stringUnit': {'state': 'translated', 'value': '%lld photos'}}}}}}}
    result = import_sheet({'Localizable': {'strings': {'count': plural}}}, {'Localizable/count': ('%lld photos', '%lld TEST', fingerprint(plural))})
    assert set(result['Localizable']['strings']['count']['localizations']['zh-Hans']['variations']['plural']) == {'other'}
    print('PASS: stable-key import, argument reorder, stale English/context rejection, duplicate rejection, cell escaping and blank no-op.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['export', 'check', 'import', 'self-test'])
    parser.add_argument('--worksheet', type=pathlib.Path)
    parser.add_argument('--extracted', type=pathlib.Path)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--allow-partial', action='store_true')
    args = parser.parse_args()
    if args.command == 'self-test':
        self_test()
        return
    if not args.worksheet:
        parser.error('--worksheet is required')
    data = catalogs()
    if args.command == 'export':
        export_sheet(data, args.worksheet)
        return
    if args.command == 'import':
        if not args.extracted:
            parser.error('Import requires --extracted from a native build.')
        build_for_import(args.extracted)
        data = catalogs()
    entries = inventory(data)
    verify_sources(data, args.extracted)
    rows = read_rows(args.worksheet)
    validate_rows(entries, rows)
    filled = sum(bool(row[1]) for row in rows.values())
    print(f'Valid keys/source/placeholders. Reviewed: {filled}/{len(rows)}.')
    if args.command == 'import':
        if not args.extracted:
            parser.error('Import requires --extracted from a fresh native build.')
        if args.apply:
            if filled != len(rows) and not args.allow_partial:
                raise ValueError('Finish the worksheet before applying, or use --allow-partial for a test build.')
            if filled:
                for table, catalog in import_sheet(data, rows).items():
                    (RESOURCES / (table + '.xcstrings')).write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
                project = ROOT / 'SpektraCam.xcodeproj/project.xcproj'
                text = project.read_text()
                region = re.search(r'"supported":\s*\[([^]]*)\]', text)
                if '"zh-Hans"' not in region[1]:
                    locales = re.findall(r'"([^"]+)"', region[1]) + ['zh-Hans']
                    content = '\n' + ''.join('      ' + json.dumps(locale) + ',\n' for locale in locales) + '    '
                    text = text[:region.start(1)] + content + text[region.end(1):]
                    project.write_text(text)
                print('Applied reviewed Chinese text. Build and test both languages before release.')
        else:
            print('Dry run only; no files changed.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError) as error:
        raise SystemExit(str(error))
