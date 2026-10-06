# MaGiKara 本机日语歌唱强制对齐实验

This is an optional local A/B backend inspired by FA-Kara's useful structure:

1. use the separated vocal stem rather than the full mix;
2. preserve the user's Japanese lyric readings and map kana morae to the model's Latin phone alphabet;
3. align the known phone sequence against wav2vec2 CTC emissions, then map each aligned phone span back to the original mora and lyric line;
4. keep all timestamps in the original audio timeline and retain raw acoustic scores for review.

MaGiKara's existing ASR, OCR, editor, and export paths remain intact. The Yohane backend is opt-in and is not auto-accepted: forced alignment can return a plausible path even when the supplied lyric text is wrong, and the raw CTC score has not yet been calibrated against human acoustic ground truth.

## Local setup

Run `./Scripts/local_forced_aligner/setup.sh` from the project root. It creates an isolated Python 3.12 environment under:

`~/Library/Application Support/MaGiKara/LocalForcedAligner/`

The Yohane checkpoint is about 1.26 GB. The Hugging Face model card labels it CC BY-NC-SA 4.0. Setup pins checkpoint revision `2ab2b5f46539ee284703c281f286b01d2410ee12` and verifies the 1,261,938,632-byte weight file against SHA-256 `4d1d6fbb543534ab32bcceac5f5a42052c7fde3d16a83cbbce858473d5735042`, so repeated local tests use the same verified weights. This setup keeps weights and Python dependencies outside the repository and app bundle for local evaluation only. Do not redistribute or use it for a commercial release without a separate license review.

The Apple Silicon runtime uses MPS when available and falls back to CPU if an upstream operator is unsupported. The adapter does not contact the network during inference (`HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`).

## A/B usage

After the app/CLI has been rebuilt, run a local audio-only comparison with:

```sh
magikara-phase0 --align <media> <lyrics.txt> <output.magikara> --yohane-audio-only
```

`--yohane` keeps the normal screen-OCR-first behavior and uses Yohane for the audio fallback. The default remains the existing MaGiKara route until the new backend demonstrates a real held-out-song improvement.

## Protocol and evaluation

The bundled `sidecar.py` accepts one JSON request and returns line and mora spans as floating-point seconds, with model/device/runtime metadata and warnings. The CTC trellis is decoded locally; punctuation receives no phones, and unsupported or missing readings fail explicitly instead of receiving fabricated timing.

Run the lightweight phonetic and Viterbi unit tests with:

```sh
~/Library/Application\ Support/MaGiKara/LocalForcedAligner/venv/bin/python \
  -m unittest discover -s Tests/LocalForcedAlignerTests -v
```

Accuracy numbers must be computed against independent human-checked acoustic onset/end marks on held-out songs. OCR subtitle intervals are useful as a separate coarse reference but are not exact singing-onset ground truth.
