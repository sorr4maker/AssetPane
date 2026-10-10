#!/usr/bin/env python3
"""按基金名称查候选代码（东方财富搜索接口）。用法：Scripts/resolve-funds.py 名称1 名称2 …
每个名称打印前 5 个候选：代码 · 全名 · 最新净值日期。名字相近的（A/C 份额、联接）要人工核对。"""
import sys, json, re, urllib.parse, urllib.request

def search(key):
    url = "https://fundsuggest.eastmoney.com/FundSearch/api/FundSearchAPI.ashx?m=1&key=" + urllib.parse.quote(key)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.loads(r.read().decode("utf-8"))
    return data.get("Datas") or []

for name in sys.argv[1:]:
    print(f"## {name}")
    try:
        rows = search(name)
    except Exception as e:
        print(f"  查询失败：{e}"); continue
    if not rows: print("  没有结果")
    for d in rows[:5]:
        info = d.get("FundBaseInfo") or {}
        print(f"  {d.get('CODE')} · {d.get('NAME')} · 净值日 {info.get('FSRQ')}")
