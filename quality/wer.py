# /// script
# requires-python = ">=3.10"
# dependencies = ["jiwer", "whisper-normalizer"]
#
# [[tool.uv.index]]
# url = "https://pypi.org/simple"
# default = true
# ///
"""Word error rate of each transcript against a reference.

usage: uv run quality/wer.py [--excerpt] <reference> [hypothesis ...]

Hypotheses default to every other .txt file in quality/. Both sides go through
Whisper's English normalizer (lowercase, strip punctuation, spell out numbers
consistently) so formatting differences don't count as errors.

--excerpt is for a reference that covers only part of the audio (e.g. NPR's
transcript of the second half): each hypothesis is first cropped to the span
that best matches the reference's opening and closing words, so the rest of
the speech isn't counted as insertions.
"""

import argparse
from difflib import SequenceMatcher
from pathlib import Path

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

normalize = EnglishTextNormalizer()


ANCHOR = 20  # words used to locate the start and end of an excerpt


def best_offset(needle: list[str], hay: list[str]) -> int:
    """Index in hay where a window of len(needle) words best matches needle."""
    n = len(needle)
    return max(
        range(max(1, len(hay) - n + 1)),
        key=lambda i: SequenceMatcher(None, needle, hay[i : i + n]).ratio(),
    )


def crop(ref: str, hyp: str) -> str:
    r, h = ref.split(), hyp.split()
    start = best_offset(r[:ANCHOR], h)
    end = best_offset(r[-ANCHOR:], h[start:]) + start + ANCHOR
    return " ".join(h[start:end])


def score(ref: str, hyp: str, excerpt: bool) -> tuple[float, int, int, int]:
    if excerpt:
        hyp = crop(ref, hyp)
    out = jiwer.process_words(ref, hyp)
    return out.wer, out.substitutions, out.deletions, out.insertions


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--excerpt", action="store_true")
    parser.add_argument("reference", type=Path)
    parser.add_argument("hypotheses", type=Path, nargs="*")
    args = parser.parse_args()

    here = Path(__file__).parent
    hyps = args.hypotheses or sorted(
        p for p in here.glob("*.txt") if p.resolve() != args.reference.resolve()
    )

    ref = normalize(args.reference.read_text())
    rows = sorted(
        (*score(ref, normalize(p.read_text()), args.excerpt), p.stem) for p in hyps
    )

    print(f"Reference: `{args.reference}` ({len(ref.split())} words)\n")
    print("| tool | WER | substitutions | deletions | insertions |")
    print("|---|--:|--:|--:|--:|")
    for wer, sub, dele, ins, name in rows:
        print(f"| {name} | {wer:.1%} | {sub} | {dele} | {ins} |")


if __name__ == "__main__":
    main()
