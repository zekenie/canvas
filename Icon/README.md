# The app icon

`AppIcon.svg` is the icon: index cards pinned to a slate felt board, the app's yellow note among them,
joined by red string. `AppIcon-small.svg` is the same picture redrawn for 16 points (32 pixels on a
Retina screen: a list, Spotlight), where the cards' text bars turn to noise and a thin string disappears:
no bars, a heavier string, bigger pins.
`AppIcon.icns` is made from the two, and the app's build copies it into the bundle
(`Contents/Resources/AppIcon.icns`, named by `CFBundleIconFile`). It's board files' icon too: the board
type names it as its badge (`UTTypeIcons`), and macOS draws it on its own document page, BOARD under it.

After changing either SVG, run

```
python3 Icon/tools/icon.py build
```

and commit all three files. It renders with headless Google Chrome, which is why the app's build doesn't.

## The shape

Each artboard is full bleed, 1024 by 1024, as Icon Composer takes one: draw to the edges, and leave out
the rounded square, its shadow and its edge. `icon.py` adds them the way macOS 26 does to an Icon
Composer icon: the artboard scaled into an 824-point body in the middle of the 1024 canvas, clipped to
continuous corners of radius 211, a shadow 9 down and blurred 16 at a quarter black, and a faint light
rim. The shape and the shadow are traced from this Mac's own icons (Finder's, Notes'). That matters for a
plain `.icns`: macOS 26 draws one on its shape as it is, and shrinks one that isn't onto a gray plate.
`icon.py mask` shows the shape on the artboard.

It plates the 16 and 32 pixel images a 1x screen gets all the same, whatever their shape (`iconutil`
stores them in the old raw formats, `ic04` and `ic05`), so the `.icns` leaves them out and macOS scales
the Retina ones down, unplated. Zed's `.icns`, which holds only its 512 and 1024 pixel images, is never
plated; Orca's, which holds all ten, is plated at those two sizes.

A plain `.icns` has one look for every icon style (macOS 26's dark, clear and tinted icons): those need an
Icon Composer file, and only Xcode's `actool` compiles one.

## Trying an icon

`icon.py stage ART.svg` renders an artwork as the Dock and Command-Tab show it, among this Mac's own app
icons, light and dark, and at 64, 32 and 16 points. `icon.py dock ART.svg...` makes a do-nothing app for
each artwork and opens it, so it sits in the real Dock and in Command-Tab (`icon.py dock --quit` quits
them). `icon.py sheet` puts several side by side. The rest is in `icon.py --help`.
