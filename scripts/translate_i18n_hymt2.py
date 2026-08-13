#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用腾讯混元 Hy-MT2 (TokenHub MaaS, OpenAI 兼容接口) 补全 i18n 翻译。

特性:
  - 以 source 语言(en-US) 为基准, 只为每种目标语言补全缺失的 key
  - 主路径: 把一批待译 value 拼成 JSON 数组发给模型, 要求按相同顺序返回
    翻译数组(避免模型复现含 {}/引号等特殊字符的 key 而输出畸形 JSON)
  - 数组模式失败时自动降级为逐条翻译, 保证不丢 key
  - 写回前自动备份原文件到 temp/backups
  - --dry-run 只统计不联网不写文件

用法:
  # 仅统计(不联网)
  python3 translate_i18n_hymt2.py --dry-run

  # 真实翻译(需要 HY_API_KEY 环境变量或 --api-key)
  HY_API_KEY=xxx python3 translate_i18n_hymt2.py
  python3 translate_i18n_hymt2.py --api-key YOUR_KEY

  # 只翻某几种 / 跳过非官方语种
  python3 translate_i18n_hymt2.py --lang ar bn de
  python3 translate_i18n_hymt2.py --skip-unsupported
"""
import argparse
import json
import os
import re
import time
import urllib.request
from datetime import datetime

# ---- 路径 ----
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TRANS_DIR = os.path.normpath(os.path.join(HERE, "..", "assets", "translations"))
DEFAULT_BACKUP_DIR = os.path.normpath(os.path.join(HERE, "..", "temp", "backups"))

SOURCE_LANG = "en-US"
SKIP_LANGS = {"en-US", "zh-CN"}
DEFAULT_MODEL = "hy-mt2-plus"
# 国内版(默认, TokenHub MaaS): https://tokenhub.tencentmaas.com/v1
# 国际版可改用: https://tokenhub-intl.tencentcloudmaas.com/v1/chat/completions
BASE_URL = "https://tokenhub.tencentmaas.com/v1/chat/completions"

# 目标语言代码 -> (Hy-MT2 语种名, 是否官方支持)
# supported=False 的为官方 33 语种表外, 属尽力翻译
LANG_NAMES = {
    "ar": ("阿拉伯语", True),
    "bn": ("孟加拉语", True),
    "ca": ("加泰罗尼亚语", True),
    "cs": ("捷克语", True),
    "de": ("德语", True),
    "el": ("希腊语", True),
    "es": ("西班牙语", True),
    "et": ("爱沙尼亚语", True),
    "fi": ("芬兰语", True),
    "fr": ("法语", True),
    "hi": ("印地语", True),
    "id": ("印尼语", True),
    "it": ("意大利语", True),
    "ml": ("马拉雅拉姆语", False),
    "mr": ("马拉地语", True),
    "nb-NO": ("挪威语", True),
    "nl": ("荷兰语", True),
    "pl": ("波兰语", True),
    "pt-BR": ("葡萄牙语(巴西)", True),
    "pt": ("葡萄牙语", True),
    "ro": ("罗马尼亚语", True),
    "ru": ("俄语", True),
    "sa": ("梵语", False),
    "ta": ("泰米尔语", True),
    "tr": ("土耳其语", True),
    "uk": ("乌克兰语", True),
}


def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def extract_json_array(text):
    """抠出第一个完整 JSON 数组(容忍 markdown 围栏/多余文字)。"""
    text = text.strip()
    m = re.search(r"```(?:json)?\s*(\[.*?\])\s*```", text, re.DOTALL)
    if m:
        text = m.group(1)
    start = text.find("[")
    if start == -1:
        return None
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(text)):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def call_mt2(api_key, model, prompt, batch_idx, base_url, max_retry=3):
    """调用 Hy-MT2, 返回模型回复文本或 None。"""
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.0,
        "stream": False,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        base_url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    for attempt in range(1, max_retry + 1):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                body = json.loads(resp.read().decode("utf-8"))
            return body["choices"][0]["message"]["content"]
        except Exception as e:  # noqa
            log(f"  [batch {batch_idx}] 调用失败(第{attempt}次): {e}")
            time.sleep(2 * attempt)
    return None


def translate_one(api_key, model, value, target_lang_name, base_url):
    """单条翻译(作为数组模式失败时的降级)。"""
    prompt = (
        f"将以下文本翻译为{target_lang_name}, 只输出翻译结果, 不要任何额外解释。"
        f"必须原样保留文本中的占位符如 {{var}}、${{var}}、%s、%d。\n\n{value}"
    )
    return call_mt2(api_key, model, prompt, 0, base_url)


def translate_batch(api_key, model, items, target_lang_name, base_url):
    """翻译 [(key, value), ...] 批次, 返回 {key: translated_value}。

    主路径: 把值拼成 JSON 数组发给模型, 要求按相同顺序返回翻译数组。
    失败则降级为逐条翻译。
    """
    keys = [k for k, _ in items]
    values = [v for _, v in items]
    src = json.dumps(values, ensure_ascii=False, indent=2)
    prompt = f"""# 任务目标
将下面 JSON 数组中的每一段文本依次翻译为 {target_lang_name}。

# 严格约束
1. 仅翻译数组里每个字符串元素的可读文本内容, 严禁改动或翻译 {{var}}、${{var}}、%s、%d 这类占位符, 必须原样保留。
2. 严格保持数组长度与顺序: 第 i 个输出对应第 i 个输入。
3. 只输出一个 JSON 数组(不要 Markdown 代码块、不要任何额外解释), 元素为对应翻译。

# 数据输入
{src}"""
    raw = call_mt2(api_key, model, prompt, 0, base_url)
    if raw:
        arr_txt = extract_json_array(raw)
        if arr_txt:
            try:
                arr = json.loads(arr_txt)
                if isinstance(arr, list) and len(arr) == len(values):
                    return {
                        k: (arr[i] if isinstance(arr[i], str) and arr[i].strip() else values[i])
                        for i, k in enumerate(keys)
                    }
                log(f"  数组长度不符(期望 {len(values)}, 实得 "
                    f"{len(arr) if isinstance(arr, list) else '非数组'}), 降级逐条")
            except Exception as e:  # noqa
                log(f"  数组解析失败: {e}, 降级逐条")
    # 降级: 逐条翻译
    log("  降级为逐条翻译...")
    result = {}
    for k, v in items:
        r = translate_one(api_key, model, v, target_lang_name, base_url)
        result[k] = r if r else v
        time.sleep(0.2)
    return result


def chunk_dict(d, size):
    items = list(d.items())
    for i in range(0, len(items), size):
        yield items[i:i + size]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--translations-dir", default=DEFAULT_TRANS_DIR)
    ap.add_argument("--source", default=SOURCE_LANG)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--base-url", default=BASE_URL,
                    help="Hy-MT2 MaaS 接入点(国际版/国内版)")
    ap.add_argument("--api-key", default=os.environ.get("HY_API_KEY", ""))
    ap.add_argument("--batch-size", type=int, default=30)
    ap.add_argument("--lang", nargs="*", default=None,
                    help="只处理指定语言代码, 默认全部非中英文")
    ap.add_argument("--dry-run", action="store_true",
                    help="只统计缺失数量, 不联网不写文件")
    ap.add_argument("--backup-dir", default=DEFAULT_BACKUP_DIR)
    ap.add_argument("--skip-unsupported", action="store_true",
                    help="跳过官方不支持的语种")
    args = ap.parse_args()

    tdir = args.translations_dir
    source = load_json(os.path.join(tdir, f"{args.source}.json"))

    files = sorted(
        f[:-5] for f in os.listdir(tdir)
        if f.endswith(".json") and f[:-5] not in SKIP_LANGS
    )
    if args.lang:
        files = [f for f in files if f in args.lang]

    log(f"源语言: {args.source} ({len(source)} keys) | 目标语言数: {len(files)} | 模型: {args.model} | dry-run={args.dry_run}")

    total_todo = 0
    for lang in files:
        if lang not in LANG_NAMES:
            log(f"⚠ {lang}: 未配置语种名映射, 跳过")
            continue
        target_name, supported = LANG_NAMES[lang]
        d = load_json(os.path.join(tdir, f"{lang}.json"))
        # 待翻译: 缺失的 key, 或值已存在但为空(空壳)
        todo = {k: source[k] for k in source if k not in d or not str(d.get(k, "")).strip()}
        tag = "✓官方支持" if supported else "⚠尽力翻译(非官方语种)"
        empties = sum(1 for k in d if not str(d.get(k, "")).strip())
        log(f"{lang:8s} 现有 {len(d):4d} / 待译 {len(todo):4d} (空壳{empties})  [{target_name} {tag}]")
        total_todo += len(todo)
        if args.dry_run or len(todo) == 0:
            continue
        if not supported and args.skip_unsupported:
            log(f"  -> 跳过(非官方语种且 --skip-unsupported)")
            continue
        if not args.api_key:
            log("  !! 无 API key, 无法翻译(用 --api-key 或环境变量 HY_API_KEY)")
            continue

        # 分批翻译
        translated = {}
        for i, sub in enumerate(chunk_dict(todo, args.batch_size), 1):
            log(f"  [{lang}] 批次 {i}/{(len(todo)+args.batch_size-1)//args.batch_size} ({len(sub)} keys)...")
            res = translate_batch(args.api_key, args.model, sub, target_name, args.base_url)
            if res:
                translated.update(res)
            else:
                log(f"  [{lang}] 批次 {i} 翻译失败(全部重试失败), 跳过该批次")
            time.sleep(5)

        if not translated:
            log(f"  [{lang}] 无成功翻译, 跳过写回")
            continue

        # 合并: 以源顺序为基准, 原值保留, 译文覆盖空壳/缺失; 丢弃源中不存在的脏 key
        merged = {k: d.get(k, "") for k in source}
        for k in translated:
            if translated[k].strip():
                merged[k] = translated[k]

        # 备份 + 写回
        os.makedirs(args.backup_dir, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        bak = os.path.join(args.backup_dir, f"{lang}.json.{ts}.bak")
        with open(bak, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=4)
            f.write("\n")
        out = os.path.join(tdir, f"{lang}.json")
        with open(out, "w", encoding="utf-8") as f:
            json.dump(merged, f, ensure_ascii=False, indent=4)
            f.write("\n")
        log(f"  [{lang}] 已写回 {out} (成功 {len(translated)} / 待译 {len(todo)}, 备份 {bak})")

    log(f"完成. 待补全 key 总数: {total_todo}")


if __name__ == "__main__":
    main()
