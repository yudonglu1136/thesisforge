# Black Edition local preview

Art direction: the user's black-background 13F article and charts. Black and white establish hierarchy; color identifies data rather than decorating containers. Changes reuse the existing Flutter application and Fact OS readers.

The user approved production publication on 2026-09-28. Black Edition is now the default; an explicit `BLACK_EDITION_PREVIEW=false` build retains the legacy theme for comparison. No backend calculation, database or stored research changes are part of this work.

## Run locally

From the existing ThesisForge root, start `bash scripts/local-server-dev.sh`, then:

```sh
flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5174 \
  --dart-define=API_BASE_URL=http://127.0.0.1:8787 \
  --dart-define=AUTH_DEV_BYPASS=true \
  --dart-define=INVESTMENT_WORKFLOW_ENABLED=true \
  --dart-define=BLACK_EDITION_PREVIEW=true
```

Local-only authentication bypass must never be used in a deployed build.

Open `http://127.0.0.1:5174/?view=discover&discoverTab=aiinsights&asOf=2026-09-21&lang=en`.

## Assets

- `assets/fonts/Inter-Variable.ttf`: Google Fonts Inter variable font; license alongside as `Inter-OFL.txt`. Preview family TFInter is isolated from the legacy font declaration.
- `assets/branding/thesisforge-black-mark.png`: generated white TF identity concept, user review pending; original identity remains available.
- Logo generation prompt: “Create a premium ultra-clean minimal logo asset for ThesisForge. Single compact white TF monogram on a completely uniform pure black #000000 square background. Geometry is simple geometric sans-serif architectural letters fused together, no serif tips. Swiss institutional research identity. Flat solid white fill with absolutely smooth hard edges. No distressed texture, no grain, no scratches, no shading, no gradient, no shadow, no perspective, no wordmark, no other text. Center symbol at 80% canvas size. Visually legible at 32px. Just one flat clean logo.”

Screenshots in this folder are actual local browser captures, not mockups. See the `design-qa.md` in this folder for the local verification and limitations. Production verification is recorded separately.
