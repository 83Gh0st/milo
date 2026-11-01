# Milo brand identity

Teal clay companion + lowercase `milo` wordmark on warm cream. Do not use
Flutter-default art anywhere in shipped builds.

## Palette

| Role | Hex | Used in |
|---|---|---|
| Deep teal body | `#149E87` | companion default, listening arcs, ♪ note |
| Deep teal ink | `#0A3F38` | splash + in-app wordmark, mouth interior, mono icon |
| Sea-teal iris | `#0D5C66` | companion eyes |
| Mint sprout | `#34C38F` / `#2FB584` | companion sprout (unchanged) |
| Warm cream | `#FEF4E5` | icon/splash backgrounds, adaptive bg, splash window |
| Coral blush | `#FF8A70` / `#FF9A86` | companion cheeks + tongue |

The app UI theme (`lib/ui/theme.dart`, periwinkle primary) is intentionally
untouched: this pass covers the product mark, launcher, splash, and the
companion's default look only.

## Source masters (`assets/branding/`)

| File | Purpose |
|---|---|
| `icon.png` | 1024 full-bleed master → legacy mipmaps + all iOS icons |
| `icon_fg.png` | 1024 adaptive foreground (mascot ≈58%, survives circle masks) |
| `icon_mono.png` | monochrome silhouette (Android 13+ themed icons) |
| `icon_noti.png` | white silhouette (notification use) |
| `mascot.png` | 1024 in-app mark for the `MiloBrand` lockup |
| `splash.png` | mascot + baked `milo` wordmark for native splash |

`generated_images/` (untracked) holds the two AI-generated master renders these
were derived from; the one-off derivation script is `.sdk-probe/brand_gen.dart`
(gitignored, not part of the build).

## Regeneration

Masters → platform assets is a committed, CI-run step (`release.yml` runs both
before every build). To refresh after editing a master:

```sh
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

Config lives in `pubspec.yaml` (`flutter_launcher_icons`,
`flutter_native_splash`). Commit the regenerated `android/app/src/main/res`
and `ios/Runner/Assets.xcassets` so local builds match CI.

## In-app surfaces

- `MiloBrand` (`lib/ui/brand.dart`): static lockup (mascot tile + `milo` in
  Lexend SemiBold). Currently on More → About Milo, above the version line.
  The debug long-press that opens MiloLab is unchanged.
- Companion default body is teal; the wardrobe (More → Milo → colour,
  onboarding) keeps periwinkle, pink, mint, and honey as options. Saved
  colours are untouched — only the default changed.
- The legacy Lab renderer (`lib/companion/painter.dart`) is deliberately
  unchanged: it is the before/after comparison baseline.

## Verification status

- `flutter analyze`: clean.
- Launcher (legacy + adaptive + mono), iOS AppIcon set, Android + iOS splash
  inspected in the working tree; display name `Milo` on both platforms.
- Release APK build and on-device visual check are CI/user-side: this
  environment has no network egress for the Gradle distribution.
