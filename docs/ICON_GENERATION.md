# Icon Generation Rules

Use these rules when generating or regenerating the MediaFlow app icon. The target style is aligned with the existing SessionFlow icon language, not a generic media/photo icon.

## Reference Style

SessionFlow icon traits to preserve:

- macOS app icon composition: centered object inside a rounded-square safe area.
- Background: vivid vertical cyan/blue to violet/purple gradient.
- Foreground: translucent frosted-glass object with soft internal glow.
- Material: Apple Icon Composer-like glass, blur-material feel, semi-transparent, luminous edges.
- Lighting: soft individual layer lighting, no hard shadows.
- Shadow: colored layer shadow, soft and moderately strong.
- Depth: simple 3D stack/perspective, not flat vector art.
- Finish: polished, clean, minimal, premium utility app.

SessionFlow source values from `SessionFlow/Icon.icon/icon.json`:

- Gradient colors:
  - `display-p3:0.38557,0.73111,0.97310,1.00000`
  - `display-p3:0.40892,0.10100,0.92754,1.00000`
- Main foreground layer:
  - one image layer at `scale: 0.5`
  - `blur-material: 0.5`
  - `translucency.enabled: true`
  - `translucency.value: 0.25`
  - `shadow.kind: layer-color`
  - `shadow.opacity: 0.7`
  - `specular: false`

## MediaFlow Concept

MediaFlow should feel related to SessionFlow, but represent a live media wall/collage.

Use one of these foreground concepts:

- Three to five translucent rounded media tiles flowing in a staggered stack.
- A compact glass mosaic made of overlapping rounded rectangles.
- A centered layered "media wall" object with subtle perspective and depth.

The icon should imply:

- local photos and videos;
- collage layout;
- flow/rearrangement;
- fullscreen media wall.

It should not look like:

- a camera app;
- a generic photo gallery;
- a video player logo;
- a Finder/file utility;
- a lettermark.

## Prompt Template

Use this prompt as the starting point for image generation:

```text
Create a polished macOS app icon for "MediaFlow" in the same visual language as a modern Apple Icon Composer icon.

Canvas and framing:
- Square 1024x1024 app icon source.
- Rounded-square macOS icon safe area.
- Centered foreground object with generous padding.
- No text, no letters, no watermark.

Background:
- Smooth vertical gradient from luminous cyan/sky blue at the top to saturated violet/purple at the bottom.
- Clean, glossy, premium macOS utility-app feel.

Foreground object:
- A compact 3D stack of translucent frosted-glass rounded media tiles, like a flowing collage or media wall.
- Three to five overlapping rounded rectangles, arranged in a gentle cascading stack with subtle perspective.
- The tiles should feel like glass panels: translucent, softly blurred, luminous cyan highlights, pale blue edges, and faint internal glow.
- Use soft colored shadow below and behind the stack, matching the purple/blue environment.
- Minimal detail: abstract media panels, not literal thumbnails.

Style constraints:
- Match the SessionFlow icon language: glassy layered object, cyan/violet gradient, soft depth, premium macOS app icon.
- Avoid flat vector style, camera lens, play button, film strip, mountains/photo placeholder, text, letters, clutter, harsh black shadows, heavy outlines, or photorealistic objects.
- The icon must remain legible at small sizes.
```

## Selection Criteria

Choose the generated icon that best satisfies:

- The silhouette reads clearly at 32px.
- It feels like a sibling to SessionFlow.
- It communicates media collage without literal thumbnails.
- The foreground stays centered and not too large.
- No text-like artifacts or accidental symbols.
- No muddy low-contrast glass edges.

Reject outputs with:

- letters, labels, or UI text;
- camera lenses or play buttons;
- too many tiny rectangles;
- flat SVG-like geometry;
- dark/black shadows;
- photographic scenes inside panels;
- cropped foreground elements.

## Export Pipeline

After selecting a 1024px square PNG, save it as:

```sh
Assets/AppIcon-source.png
Assets/AppIcon-1024.png
```

Regenerate the iconset and `.icns`:

```sh
mkdir -p Assets/AppIcon.iconset
sips -z 16 16 Assets/AppIcon-1024.png --out Assets/AppIcon.iconset/icon_16x16.png
sips -z 32 32 Assets/AppIcon-1024.png --out Assets/AppIcon.iconset/icon_16x16@2x.png
sips -z 32 32 Assets/AppIcon-1024.png --out Assets/AppIcon.iconset/icon_32x32.png
sips -z 64 64 Assets/AppIcon-1024.png --out Assets/AppIcon.iconset/icon_32x32@2x.png
sips -z 128 128 Assets/AppIcon-1024.png --out Assets/AppIcon.iconset/icon_128x128.png
sips -z 256 256 Assets/AppIcon-1024.png --out Assets/AppIcon.iconset/icon_128x128@2x.png
sips -z 256 256 Assets/AppIcon-1024.png --out Assets/AppIcon.iconset/icon_256x256.png
sips -z 512 512 Assets/AppIcon-1024.png --out Assets/AppIcon.iconset/icon_256x256@2x.png
sips -z 512 512 Assets/AppIcon-1024.png --out Assets/AppIcon.iconset/icon_512x512.png
cp Assets/AppIcon-1024.png Assets/AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
```

Then rebuild release artifacts:

```sh
./scripts/build-native-app.sh
./scripts/create-dmg.sh
./scripts/verify-dmg.sh
```

## Notes

- Keep the source icon square and at least 1024x1024.
- Do not use transparency for the final app icon source; macOS icon masks handle shape.
- If the generated image has rough text-like artifacts, regenerate rather than editing around them.
- `Assets/AppIcon.icns` is the file copied into `MediaFlow.app` by the build script.
