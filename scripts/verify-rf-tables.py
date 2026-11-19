#!/usr/bin/env python3
"""模拟 rtl_ax_ap 驱动的表解析器，编译前验证 42 张射频表能否全部通过。

严格复现 board/wifi/rtl_ax_ap 下：
  phy.c::rtl_ax_phy_read_table      -> PHY_REG/PHY_REG_GAIN/RadioA/RadioB
  power-tables.c::rtl_ax_rate_parse -> TXPWR_ByRate.txt
  power-tables.c::rtl_ax_track_parse-> TXPWR_TrackTSSI.txt
  limits.c::rtl_ax_limit_parse      -> TXPWR_LMT*.txt
"""
import os
import re
import sys

EINVAL = -22
EOPNOTSUPP = -95


def lines(text):
    return text.split('\n')


# ---------------- phy 表 ----------------
def check_phy(path):
    n = 0
    for line in lines(open(path, encoding='utf-8', errors='replace').read()):
        line = line.lstrip(' \t')
        if not line or line.startswith('//'):
            continue
        m = re.match(r'^((?:0[xX])?[0-9a-fA-F]+)\s+((?:0[xX])?[0-9a-fA-F]+)', line)
        if not m:
            return EINVAL, 'sscanf 不匹配: %r' % line[:60]
        address = int(m.group(1), 16)
        if address == 0xFFFF:
            break
        if address >> 28:
            return EOPNOTSUPP, 'address>>28 非零: 0x%x' % address
        n += 1
    return 0, '%d pairs' % n


# ---------------- ByRate ----------------
RATE_GROUPS_OFFSET = {
    (0, 'AllRate2_1'), (0, 'AllRate2_2'), (1, 'AllRate5_1'), (2, 'AllRate6_1'),
}
RATE_GROUPS_NSS = {'11M_1M', '18M_6M', '54M_24M', 'DCM4_0', 'MCS11_8', 'MCS3_0', 'MCS7_4'}


def check_byrate(path):
    band = 0
    header = False
    rows = 0
    for line in lines(open(path, encoding='utf-8', errors='replace').read()):
        line = line.lstrip(' \t')
        if not line or line.startswith('//'):
            continue
        if not header:
            if not line.startswith('#[v3][Exact]#'):
                return EINVAL, '首行不是 #[v3][Exact]#: %r' % line[:40]
            header = True
            continue
        if line.startswith('#[2.4G]#'):
            band = 0; continue
        if line.startswith('#[5G]#'):
            band = 1; continue
        if line.startswith('#[6G]#'):
            band = 2; continue
        if line.startswith('#[START]#') or line.startswith('#[END]#'):
            continue
        code_part = line.split('//')[0]
        tok = code_part.split()
        if len(tok) < 6:
            return EINVAL, '需要 6 列，实际 %d: %r' % (len(tok), line[:50])
        tok = tok[:6]
        stream, group = tok[0], tok[1]
        for t in tok[2:]:
            try:
                int(t.split('.')[0])
            except ValueError:
                return EINVAL, '数值列非整数: %r' % t
        if stream == '[Offset]':
            if (band, group) not in RATE_GROUPS_OFFSET:
                return EINVAL, 'Offset 组不允许 band=%d group=%s' % (band, group)
        elif stream in ('[Nss1]', '[Nss2]'):
            nss = 0 if stream == '[Nss1]' else 1
            if group == '11M_1M':
                if nss or band:
                    return EINVAL, '11M_1M 只能在 band0/Nss1'
            elif group not in RATE_GROUPS_NSS:
                return EINVAL, '未知 group %s' % group
        else:
            return EINVAL, '未知 stream %s' % stream
        rows += 1
    if not header or not rows:
        return EINVAL, '无表头或无数据行'
    return 0, '%d rows' % rows


# ---------------- TrackTSSI ----------------
def check_track(path):
    rows = 0
    for line in lines(open(path, encoding='utf-8', errors='replace').read()):
        line = line.lstrip(' \t')
        if not line or line.startswith('//'):
            continue
        m = re.match(r'^\[(.{1,2})\]\[(.)\]\[(.)\]\[(.{1,3})\]', line)
        if not m:
            return EINVAL, '头部不匹配: %r' % line[:50]
        band, path_c, sign, mod = m.group(1).rstrip('\x00'), m.group(2), m.group(3), m.group(4)
        if path_c not in ('A', 'B') or sign not in ('+', '-'):
            return EINVAL, 'path/sign 非法: %r' % line[:40]
        lb, rb = line.find('{'), line.find('}')
        if lb < 0 or rb < 0:
            return EINVAL, '缺 {}: %r' % line[:40]
        if band == '2G':
            if mod not in ('CCK', 'ALL'):
                return EINVAL, '2G 调制非法: %r' % mod
        else:
            sel = re.search(r'\[ALL\]\[(\d+)\]', line)
            if not sel:
                return EINVAL, '缺 [ALL][n]: %r' % line[:50]
            g = int(sel.group(1))
            if band == '5G' and g >= 3:
                return EINVAL, '5G group %d >= 3' % g
            if band == '6G' and g >= 4:
                return EINVAL, '6G group %d >= 4' % g
            if band not in ('5G', '6G'):
                return EINVAL, 'band 非法: %r' % band
        body = line[lb + 1:rb]
        vals = [v.strip() for v in body.split(',')]
        if len(vals) > 30:
            vals = vals[:30]  # C: while (count < 30)
        for v in vals:
            if not re.fullmatch(r'[+-]?\d+', v):
                return EINVAL, '数值非法: %r' % v
        rows += 1
    return (0, '%d rows' % rows) if rows else (EINVAL, '无数据行')


# ---------------- power limit ----------------
BANDS = ['2.4G', '5G', '6G']
BW = ['20M', '40M', '80M', '160M']
RUS = ['RU26', 'RU52', 'RU106']
RATES = ['CCK', 'OFDM', 'HT', 'VHT', 'HE']


def parse_decimal(t):
    if t == 'NA':
        return 0
    if t == 'WW':
        return 0
    if t[:1] in '+-':
        t = t[1:]
    if '.' in t:
        i, f = t.split('.', 1)
        int(i, 10)
        int(f, 10)
    else:
        int(t, 10)
    return 0


def check_limits(path, ru):
    column_count = 0
    header = False
    labels = False
    rows = 0
    regs = []
    for raw in lines(open(path, encoding='utf-8', errors='replace').read()):
        line = raw.strip(' \t\r')
        if not line or line.startswith('//') or line.startswith('@@Ver='):
            continue
        if line.startswith('@@'):
            if 'Regulation=' not in line:
                return EINVAL, '@@ 行缺 Regulation: %r' % line[:50]
            if not (re.match(r'@@CountryCode=', line) or re.match(r'@@DomainCode=', line)):
                return EINVAL, '@@ 行缺 Country/Domain: %r' % line[:50]
            continue
        if line.startswith('##'):
            cur = line[2:].lstrip(' \t')
            if ',' in cur:
                c = cur.split('//')[0]
                fields = [f.strip() for f in c.split(',')]
                need = 4 if ru else 5
                if len(fields) < need:
                    return EINVAL, 'header 字段不足 %d: %r' % (need, cur[:50])
                if fields[0] not in BANDS:
                    return EINVAL, 'band 非法 %r' % fields[0]
                pool = RUS if ru else BW
                if fields[1] not in pool:
                    return EINVAL, 'bandwidth 非法 %r' % fields[1]
                if not re.fullmatch(r'[12]T', fields[2]):
                    return EINVAL, 'ntx 非法 %r' % fields[2]
                if fields[3] not in RATES:
                    return EINVAL, 'rate 非法 %r' % fields[3]
                if not ru and fields[4] not in ('BF', ''):
                    pass  # key->bf 只看是否等于 BF，其它值等同于非 BF
                header = True
                labels = False
                column_count = 0
            elif cur == 'START':
                continue
            elif cur == 'END':
                header = False
            elif re.fullmatch(r'#(\d+)#', cur):
                column_count = int(re.fullmatch(r'#(\d+)#', cur).group(1))
                if not column_count or column_count > 32:
                    return EINVAL, 'column_count 非法 %d' % column_count
            else:
                tok = cur.split()
                if len(tok) < column_count:
                    return EINVAL, 'labels 列数不足 %d < %d' % (len(tok), column_count)
                regs = tok[:column_count]
                labels = True
            continue
        if not header or not labels:
            return EINVAL, '数据行出现在 header/labels 之前: %r' % line[:50]
        tok = line.split()
        if not tok:
            continue
        if tok[0] == 'PShape':
            if len(tok) - 1 < column_count:
                return EINVAL, 'PShape 列数不足'
            for v in tok[1:column_count + 1]:
                int(v, 10)
            continue
        if not re.fullmatch(r'CH\d+', tok[0]):
            return EINVAL, '通道列非法 %r' % tok[0]
        if int(tok[0][2:]) > 255:
            return EINVAL, '通道号 > 255'
        for v in tok[1:column_count + 1]:
            r = parse_decimal(v)
            if r:
                return r, 'power 值非法 %r' % v
        if len(tok) - 1 < column_count:
            return EINVAL, '数据列不足'
        rows += 1
    if header or not rows:
        return EINVAL, 'header 未闭合或无数据'
    return 0, '%d rows, %d regs' % (rows, len(regs))


def check_file(path):
    name = os.path.basename(path)
    if name in ('PHY_REG.txt', 'PHY_REG_GAIN.txt', 'RadioA.txt', 'RadioB.txt'):
        return check_phy(path)
    if name == 'TXPWR_ByRate.txt':
        return check_byrate(path)
    if name == 'TXPWR_TrackTSSI.txt':
        return check_track(path)
    if name.startswith('TXPWR_LMT'):
        ru = '_RU' in name
        return check_limits(path, ru)
    return EINVAL, '未知表类型'


def main(root):
    total = 0
    bad = 0
    for dirpath, _, files in os.walk(root):
        for f in sorted(files):
            if not f.endswith('.txt'):
                continue
            p = os.path.join(dirpath, f)
            total += 1
            code, msg = check_file(p)
            rel = os.path.relpath(p, root)
            if code:
                bad += 1
                print('FAIL %-64s %s' % (rel, msg))
            else:
                print('  ok %-64s %s' % (rel, msg))
    print('\n%d 张表，%d 张失败' % (total, bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else '.'))
