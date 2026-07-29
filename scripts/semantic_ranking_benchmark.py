#!/usr/bin/env python3

import argparse
import math
import time
from dataclasses import dataclass

import mlx.core as mx
from mlx_lm import generate, load


@dataclass(frozen=True)
class Case:
    context: str
    pinyin: str
    candidates: tuple[str, ...]
    expected: str


CASES = (
    Case("一身", "ni", ("你", "拳", "拟", "尼", "泥", "呢", "妳", "妮", "腻"), "泥"),
    Case("这件事与", "wo", ("我", "窝", "握", "卧", "沃", "无"), "我"),
    Case("前方道路十分拥", "du", ("堵", "读", "毒", "度", "独"), "堵"),
    Case("请把房门关", "shang", ("上", "伤", "尚", "商", "赏"), "上"),
)


def encode(tokenizer, text: str) -> list[int]:
    return tokenizer.encode(text, add_special_tokens=False)


def continuation_score(model, tokenizer, context: str, candidate: str) -> float:
    prefix = encode(tokenizer, context)
    continuation = encode(tokenizer, candidate)
    if not prefix or not continuation:
        return -math.inf

    tokens = mx.array([prefix + continuation])
    logits = model(tokens)
    log_probs = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
    mx.eval(log_probs)

    values = []
    for offset, token in enumerate(continuation):
        prediction_position = len(prefix) + offset - 1
        values.append(float(log_probs[0, prediction_position, token].item()))
    # Mild length normalization avoids always preferring a one-character
    # candidate while preserving the probability of the full continuation.
    return sum(values) / (len(values) ** 0.7)


def likelihood_ranking(model, tokenizer, case: Case):
    start = time.perf_counter()
    scored = [
        (candidate, continuation_score(model, tokenizer, case.context, candidate))
        for candidate in case.candidates
    ]
    elapsed_ms = (time.perf_counter() - start) * 1_000
    return sorted(scored, key=lambda item: item[1], reverse=True), elapsed_ms


def prompt_ranking(model, tokenizer, case: Case):
    choices = " ".join(
        f"{index}:{candidate}" for index, candidate in enumerate(case.candidates)
    )
    messages = [
        {
            "role": "system",
            "content": (
                "你是中文拼音输入法候选排序器。根据光标前文字和拼音，"
                "选择最自然的续写。只能输出一个候选编号，不要解释。"
            ),
        },
        {
            "role": "user",
            "content": (
                f"光标前文字：{case.context}\n"
                f"拼音：{case.pinyin}\n"
                f"候选：{choices}\n"
                "最佳编号："
            ),
        },
    ]
    prompt = tokenizer.apply_chat_template(
        messages,
        tokenize=False,
        add_generation_prompt=True,
        enable_thinking=False,
    )
    start = time.perf_counter()
    output = generate(model, tokenizer, prompt, max_tokens=4, verbose=False).strip()
    elapsed_ms = (time.perf_counter() - start) * 1_000
    return output, elapsed_ms


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--model",
        default="models/Qwen3-0.6B-MLX-4bit",
        help="Local MLX model directory",
    )
    parser.add_argument("--prompt", action="store_true")
    args = parser.parse_args()

    load_start = time.perf_counter()
    model, tokenizer = load(args.model)
    mx.eval(model.parameters())
    load_ms = (time.perf_counter() - load_start) * 1_000
    print(f"model_load_ms={load_ms:.1f}")
    print(f"model_memory_mb={mx.get_active_memory() / 1_000_000:.1f}")

    # Warm Metal kernels before collecting timings.
    _ = continuation_score(model, tokenizer, "天气", "好")

    correct = 0
    for case in CASES:
        ranking, elapsed_ms = likelihood_ranking(model, tokenizer, case)
        winner = ranking[0][0]
        correct += int(winner == case.expected)
        formatted = " ".join(f"{word}:{score:.2f}" for word, score in ranking)
        print(
            f"context={case.context!r} pinyin={case.pinyin!r} "
            f"expected={case.expected!r} winner={winner!r} "
            f"latency_ms={elapsed_ms:.1f} ranking={formatted}"
        )
        if args.prompt:
            output, prompt_ms = prompt_ranking(model, tokenizer, case)
            print(f"prompt_output={output!r} prompt_latency_ms={prompt_ms:.1f}")

    print(f"accuracy={correct}/{len(CASES)}")


if __name__ == "__main__":
    main()
