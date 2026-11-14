---
title: "Effect browser rework: previews over glyphs, and this machine's XCTest is broken"
author: Grey
date: 2026-11-14
branch: codex/cohesive-flagship-effects
cost: { minutes: 180 }
id: l-aa304387
scope: repo
status: active
src: agent
touches:
  - GreyVision/Features/Workspace/GVEffectBrowser.swift
  - GreyVision/Features/Workspace/GVEffectDashboardSelector.swift
  - GreyVision/Features/Workspace/GVEffectBrowserTile.swift
  - GreyVision/DesignSystem/GVDynamicType.swift
---

Why the effect browser now shows real previews

The browser had been reduced to a text-first index: every effect tile drew a
small procedural diagram from GVEffectGlyph, and every effect in a family drew
the same diagram. A screen of near-identical scribbles is the highest
cognitive load the surface ever had, because the operator had to learn a
visual language before they could choose anything.

GVEffectThumbnailStore already renders real previews with the production
shaders over a frame tapped from the live camera, and EffectCatalog.Shelf.hero
names each family's signature effect. The catalogue was paying for both and
the browser was using neither. Tiles are now the effect's own picture, and
each family chip is a thumbnail of its signature effect, so a family is chosen
by how it looks.

Navigation is two rows instead of three: the four saved lists (All, Active,
Favorites, Recent) in a fixed row, and the eight families plus the three
capture modes in one scrolling row behind a rule. The mode row used to be a
third row with a third shape of control; folding it into the same row as
everything else is what makes the strip read as one shelf of choices.

What the surface must not lose

Every accessibility identifier the browser already published is kept
(workspace.browser, .close, .add, .readouts, .categories, .category.<id>,
.effect.<id>, .effects.<category>, .search.field, .capture.modes,
.depth.modes, .depth.<id>). Two of them changed meaning and the UI tests
were updated to match: workspace.browser.categories is now the family/mode
scroller (the saved lists sit above it in a fixed row), and a category chip's
accessibilityValue is now exactly "selected" rather than "0 effects, selected".
The tests in FlagshipUITests still referenced a taxonomy that no longer
exists — "color", "datamosh", "sort", "experimental", "developer" — and were
failing before this work; they now name the real shelves.

Why the add-mode control is a segmented control, not an icon

The old chip was an unlabelled stack icon that silently changed what every
tap in the grid did. A control that changes what the whole screen means has
to say so, so it says "Replace" or "Add".

This machine cannot run XCTest

Both GreyVisionUITests and GreyVisionTests fail with "The test runner hung
before establishing connection" on the iOS 27 beta simulator, before and
after any change. The simulator also logs "unable to connect to
com.apple.instruments.deviceservice.lockdown". This is environmental, not a
product bug. Two more traps on this machine: the Metal toolchain is not
installed, so the app will not build until `xcodebuild -downloadComponent
MetalToolchain` has run; and xcodebuild wants its result bundle somewhere
that exists, or it fails with an opaque "mkstemp: No such file or directory".

Two ways to see a screen here, since there is no Simulator.app to click

`xcrun simctl io <udid> screenshot` works headlessly. To reach a particular
state, add a launch argument that the app reads at startup — the codebase
already does this for --open-effect-browser, --raw-preview and --export-log,
so a temporary --effect-browser-category=<id> in GVEffectBrowser.init is the
cheap way to photograph a screen, then remove it.
