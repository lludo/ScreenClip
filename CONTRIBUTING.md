# Contributing

Thanks for helping. The full workflow lives in [docs/development.md](docs/development.md#contributing). In short:

1. Branch from `main`. Use Xcode 16 or later on macOS 14 or later.
2. Run the local checks before opening a pull request: `bash scripts/test.sh`, the Python tests in `scripts/`, and `python3 website/build.py` if you touched the website. CI runs them again.
3. Interface copy goes through the String Catalogs. See [docs/localization.md](docs/localization.md).
4. Never commit signing material, `.env` files, a `screenclip.sqlite` queue, or screenshots from a real queue.
5. Open a pull request against `main` and describe what changed for users and how you checked it.

ScreenClip is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). By contributing you agree your contribution can be distributed under that license. Report security problems privately, as described in [SECURITY.md](SECURITY.md).
