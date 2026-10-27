#!/usr/bin/env python3
"""Record a published component in the canonical VOS release spreadsheet."""
import argparse
import json
import os
from pathlib import Path
from urllib.request import Request, urlopen

TOKEN = 'Htotsn3oahO1zxt73YMcaB1zn8e'
BASE = 'https://open.feishu.cn/open-apis'


def request(path, token=None, body=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = Request(BASE + path, data=None if body is None else json.dumps(body).encode(),
                  headers=headers, method=method)
    with urlopen(req, timeout=30) as response:
        result = json.load(response)
    if result.get('code') != 0:
        raise RuntimeError('Feishu request failed: ' + path.split('?')[0])
    return result


def column(number):
    value = ''
    while number:
        number, rem = divmod(number - 1, 26)
        value = chr(65 + rem) + value
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sheet', required=True)
    parser.add_argument('--component', required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--tag')
    parser.add_argument('--resolve', action='store_true')
    args = parser.parse_args()
    defaults = ['.feishu.components.json', '.feishu.json'] if args.resolve else ['.feishu.json']
    paths = [os.environ.get('FEISHU_CONFIG_FILE')] + [str(Path.home()/name) for name in defaults]
    credentials = None
    for path in paths:
        try:
            data = json.loads(Path(path).read_text()) if path else {}
        except (OSError, ValueError):
            continue
        if data.get('feishu_app_id') and data.get('feishu_app_secret'):
            credentials = data
            break
    if not credentials:
        raise SystemExit('Feishu credentials not found')
    auth = request('/auth/v3/tenant_access_token/internal', body={
        'app_id': credentials['feishu_app_id'], 'app_secret': credentials['feishu_app_secret']})['tenant_access_token']
    sheets = request(f'/sheets/v3/spreadsheets/{TOKEN}/sheets/query', auth)['data']['sheets']
    sheet = next(s for s in sheets if s['title'] == args.sheet)
    sid = sheet['sheet_id']
    prefix = f'/sheets/v2/spreadsheets/{TOKEN}'

    def values(area):
        return request(prefix + '/values/' + sid + '!' + area, auth)['data']['valueRange'].get('values', [])

    def write(cell, value):
        area = f'{sid}!{cell}:{cell}'
        request(prefix + '/values', auth, {'valueRange': {'range': area, 'values': [[value]]}}, 'PUT')

    def text(cell):
        if isinstance(cell, list): return ''.join(text(x) for x in cell)
        if isinstance(cell, dict): return str(cell.get('text') or cell.get('link') or '')
        return str(cell or '')

    rows = values('A1:ZZ2')
    headers = [text(cell) for cell in rows[0]]
    if args.resolve:
        if args.component not in headers:
            raise SystemExit('Component column not found')
        col = column(headers.index(args.component) + 1)
        repository = text(values(f'{col}2:{col}2')[0][0])
        if repository != args.repository:
            raise SystemExit('Unexpected component repository')
        tag = next((text(row[0]) for row in values(f'{col}4:{col}2000') if row and text(row[0])), '')
        if not tag:
            raise SystemExit('No published component tag found')
        print(repository + ':' + tag)
        return
    if not args.tag:
        raise SystemExit('--tag is required when recording an image')
    if args.component in headers:
        index = headers.index(args.component) + 1
    else:
        index = len(headers) + 1
        if index > sheet.get('grid_properties', {}).get('column_count', 0):
            request(prefix + '/dimension_range', auth, {'dimension': {
                'sheetId': sid, 'majorDimension': 'COLUMNS', 'length': 1}}, 'POST')
        write(column(index) + '1', args.component)
    col = column(index)
    write(col + '2', args.repository)
    from datetime import date
    today = date.today().strftime('%Y%m%d')
    dated = values('A4:A2000')
    row = next((i + 4 for i, item in enumerate(dated) if item and text(item[0]) == today), None)
    if row is None:
        request(prefix + '/values_prepend', auth, {'valueRange': {
            'range': f'{sid}!A4:A4', 'values': [[today]]}}, 'POST')
        row = 4
    write(f'{col}{row}', args.tag)
    assert text(values(f'{col}{row}:{col}{row}')[0][0]) == args.tag
    print(f'{args.sheet}: {args.component} -> {args.repository}:{args.tag}')


if __name__ == '__main__':
    main()
