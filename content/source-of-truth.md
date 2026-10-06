# Source of truth

Everything the app ships — handbook text, requirements, brand colour — traces back to
one of the sources below. Each row names the URL it came from and when it was fetched.

Fetched: 2026-09-20.

## 1. The program page

**URL:** <https://pshs.princetonisd.net/counselors-corner/greencord-program>
**Title:** `GreenCord Program - Princeton High School`
**HTTP status when fetched:** 200

The page's *Resources* block links three items:

| Resource | Link |
| --- | --- |
| PISD Green Cord Handbook | `https://docs.google.com/document/d/1rX8VJSzQSzFacQ0zzEggV3RsmoGd11MPuLDFQR4DTQ0/edit?usp=sharing` |
| Community Service Verification Form | `/fs/resource-manager/...` (`CommunityServiceVerificationForm1.pdf`) |
| Volunteer Opportunities List (not all inclusive) | `https://docs.google.com/spreadsheets/d/1YIN5VuBxtWjVRz9loMnpPLCG11jaHeV7uIRURiDQU-Q/edit?usp=drive_link` |

## 2. The canonical handbook

The handbook on the program page is a **Google Doc**, not a PDF. Its PDF export is:

```
https://docs.google.com/document/d/1rX8VJSzQSzFacQ0zzEggV3RsmoGd11MPuLDFQR4DTQ0/export?format=pdf
```

**Comparison against the local copy at `/Users/hasya/Downloads/PISDGreenCordHandbook.pdf`:**

```
$ shasum -a 256 site-handbook.pdf ~/Downloads/PISDGreenCordHandbook.pdf
79efed01232a83475675c503325fba808e5c3eb1cd728dab6131d0b3ec0b3cf4  site-handbook.pdf
79efed01232a83475675c503325fba808e5c3eb1cd728dab6131d0b3ec0b3cf4  PISDGreenCordHandbook.pdf
$ cmp site-handbook.pdf ~/Downloads/PISDGreenCordHandbook.pdf && echo BYTE-IDENTICAL
BYTE-IDENTICAL
```

**The two files are byte-identical.** The local PDF is the current published handbook,
so no reconciliation was needed. The copy the app builds from lives at
`content/source/PISDGreenCordHandbook.pdf` with the same SHA-256.

**Version/date:** the handbook has no version number. Every page footer reads
`Updated as of 8/21//2026` (the doubled slash is in the original). The app therefore
uses **`2026.08.21`** as its content version. The Google Doc has no stable published
revision id, so a content update is detected by SHA-256, not by a revision number —
see `content/manifest.json`.

**Caution for future updates:** because the source is a live Google Doc, it can change
without notice and without the footer date changing. `tools/publish-content.sh`
re-downloads it and refuses to publish if the checksum moved without the content
version being bumped.

## 3. Brand colours

Taken from the program page's own stylesheet, in the inline `<style id="fsHSLColors">`
block that the district's CMS (Finalsite) emits:

```css
:root {
  --primary-color-h: 356.71;
  --primary-color-s: 68.22%;
  --primary-color-l: 20.98%;
  --primary-color: #5a1115;
  --secondary-color-h: 220.0;
  --secondary-color-s: 2.36%;
  --secondary-color-l: 75.10%;
  --secondary-color: #bebfc1;
}
```

| Token | Hex | Role |
| --- | --- | --- |
| Primary (maroon) | **`#5A1115`** | App brand colour, `BrandMaroon` in the asset catalogue |
| Secondary (silver) | **`#BEBFC1`** | Supporting tint, `BrandSilver` in the asset catalogue |

Contrast measurements for these values are in `verification/contrast.md`.

## 4. Logo — no panther mark available

The program page carries **no panther image**. Its two brand assets are:

| Asset | URL | What it is |
| --- | --- | --- |
| PHS wordmark | `https://resources.finalsite.net/images/f_auto,q_auto/v1743617999/princetonisdnet/v4lsolnz0dzy2vwfoeqx/PHSallwhite.png` | 5982×2362 PNG. An all-white "PRINCETON / SENIOR HIGH SCHOOL" wordmark under a swoosh. No animal. |
| District "P" mark | `https://resources.finalsite.net/images/v1710947182/princetonisdnet/dqk31cnuyrw6ju2plmtv/NewP-01.png` | 3334×3334 PNG. A letter "P" under the same swoosh. No animal. |

Both were downloaded and inspected. Neither contains a panther.

Per the locked decision for this build — *"If the program page yields no usable
high-resolution panther mark, ship an original black panther silhouette as vector art
and label it a swappable placeholder"* — the app ships an **original panther silhouette
drawn for this project** (`GreenCordHandbook/Assets.xcassets`, and the vector source at
`tools/panther.swift`). It is not the district's mark and carries no district
copyright. The swap procedure is in `README.md` under *Replacing the panther mark*.

## 5. Where updated content will be hosted

The manifest URL is a build-time constant, currently a **documented placeholder**:

```
https://pshs.princetonisd.net/greencord-app-content/manifest.json
```

Nobody has yet confirmed a writable path on the school site. `tools/publish-content.sh`
builds the exact directory to upload and prints the destination, so the path can be
changed in one place (`GreenCordHandbook/Content/ContentSource.swift`) once the
webmaster supplies it.
