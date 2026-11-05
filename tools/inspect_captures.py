"""Inspect existing monitor raw.ndjson ZIPs. No sockets, no battery operations.
Only aggregated metrics are written; no serial numbers, IPs or session paths.
This is a decoder/reconstruction check, not an energy-meter calibration.
"""
import argparse
import collections
import datetime
import json
import pathlib
import zipfile


def timestamp(value):
    value = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if value.tzinfo is None:
        raise ValueError('Timezone missing')
    return value.timestamp()


def u32(words, offset):
    return words[offset] + words[offset + 1] * 65536


def analyse(path, boundary):
    groups = collections.defaultdict(list)
    statistics = collections.defaultdict(lambda: dict(samples=0, balance_nonzero=0, balance_at_zero_current=0, max_selected=0))
    names = set()
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            if not item.filename.endswith('/raw.ndjson'):
                continue
            if item.filename in names:
                raise ValueError('Duplicate ZIP entry')
            names.add(item.filename)
            if item.file_size > 256 * 1024 * 1024:
                raise ValueError('Single log exceeds 256 MiB limit')
            count = None
            with archive.open(item) as stream:
                for line in stream:
                    row = json.loads(line.decode('utf-8-sig'))
                    if row.get('Type') == 'Config':
                        words = row['Words']
                        if len(words) != 102 or words[17] >> 8 != 1:
                            raise ValueError('Unsupported configuration')
                        modules = words[16] & 15
                        if not 3 <= modules <= 8:
                            raise ValueError('Unsupported module count')
                        count = modules * 16
                    if row.get('Type') != 'Tower':
                        continue
                    if count is None:
                        raise ValueError('Tower without preceding configuration')
                    words = row['Words']
                    if len(words) != 256 or any(not isinstance(w, int) or not 0 <= w <= 65535 for w in words):
                        raise ValueError('Invalid payload words')
                    tower = int(row['Tower'])
                    current = (words[26] - (65536 if words[26] >= 32768 else 0))/10
                    volts = sum(words[48:48+count])/1000
                    selected = sum((words[6+i//16] >> (i % 16)) & 1 for i in range(count))
                    s = statistics[tower]
                    s['samples'] += 1
                    s['balance_nonzero'] += selected > 0
                    s['balance_at_zero_current'] += selected > 0 and current == 0
                    s['max_selected'] = max(s['max_selected'], selected)
                    point = dict(t=timestamp(row['ReceivedAt']), counter=u32(words, 14)/1000, power=current*volts)
                    groups[tower, item.filename].append(point)
    totals = collections.defaultdict(lambda: dict(covered_seconds=0., counter_kWh=0., sampled_kWh=0., segments=0))
    for (tower, _), points in groups.items():
        points.sort(key=lambda x: x['t'])
        parts = []
        part = []
        for point in points:
            if part and (not 0 < point['t'] - part[-1]['t'] <= 20 or
                         (boundary is not None and part[-1]['t'] < boundary <= point['t'])):
                parts.append(part)
                part = []
            part.append(point)
        if part:
            parts.append(part)
        for part in parts:
            duration = part[-1]['t'] - part[0]['t']
            if duration <= 60:
                continue
            delta = part[-1]['counter'] - part[0]['counter']
            if delta < 0:
                raise ValueError('Counter decreased: reset/wrap requires separate treatment')
            integral = sum((max(0, -a['power']) + max(0, -b['power']))/2 * (b['t'] - a['t'])/3600000
                           for a, b in zip(part, part[1:]))
            label = 'all' if boundary is None else ('before' if part[0]['t'] < boundary else 'after')
            total = totals[tower, label]
            total['covered_seconds'] += duration
            total['counter_kWh'] += delta
            total['sampled_kWh'] += integral
            total['segments'] += 1
    energy = []
    for (tower, label), total in sorted(totals.items()):
        total['relative_difference_pct'] = (100*(total['sampled_kWh']/total['counter_kWh']-1)
                                            if total['counter_kWh'] else None)
        energy.append(dict(tower=tower, period=label, **total))
    return dict(log_files=len(names), towers=dict(statistics), energy_comparison=energy,
                interpretation='Sequential PC receive times, gaps >20 s excluded, segments <=60 s excluded. Not proof of physical accuracy or firmware causation.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('zip_path', type=pathlib.Path)
    parser.add_argument('--split-utc', help='Optional explicit ISO8601 boundary; not an inferred firmware version')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    boundary = timestamp(args.split_utc) if args.split_utc else None
    result = analyse(args.zip_path, boundary)
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(text, encoding='utf-8')
    print(text)


if __name__ == '__main__':
    main()
