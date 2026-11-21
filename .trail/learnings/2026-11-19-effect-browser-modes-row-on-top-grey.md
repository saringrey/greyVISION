---
title: "Effect browser: modes row on top, wrapped family rows, concurrent 128px thumbnails"
author: Grey
date: 2026-11-19
branch: codex/cohesive-flagship-effects
id: l-cb5a4ccd
scope: repo
status: active
src: agent
touches:
  - GreyVision/DesignSystem/GVCompactDeckKit.swift
  - GreyVision/DesignSystem/GVGlass.swift
  - GreyVision/DesignSystem/GVInteraction.swift
  - GreyVision/DesignSystem/GVMetrics.swift
  - GreyVision/DesignSystem/GVMotion.swift
  - GreyVision/DesignSystem/GVPrimitives.swift
  - GreyVision/DesignSystem/GVStardustButton.swift
  - GreyVision/DesignSystem/GVSurface.swift
  - GreyVision/DesignSystem/GVTheme.swift
  - GreyVision/Features/Launch/BootView.swift
---

Why the strip changed shape, and why the thumbnails now fill in fast

The strip overflowed on the phone: each of the eight family chips drew a 26pt signature-effect preview plus text, and AR/LiDAR/Tracking sat at the end of the row, off the phone's screen — 'display all categories' failed even though the row is horizontal.

- The modes row is now pinned at the top of the browse area: AR, LiDAR and Tracking are the priority captures and a horizontal strip cannot pin anything, so it buried them at its trailing edge.
- Family chips are text again: the grid shows real previews of every effect in the family (GVEffectThumbnailStore), so the per-chip preview was the same picture eight times over and was the room the strip needed. GVEffectGlyph.swift is deleted — the browser moved to real previews and the glyph file had no callers outside itself (EffectCatalogTests still tests the catalog's hero property, which family shelves are built from).
- GVEffectDashboardSelector.wrappedFamilyRows(for:width:) splits the flat family list into rows sized by the widest chip's glyph-count estimate, then chunks evenly so the last row is never a stray single chip: two of four on the phone, one row of eight on the iPad.
- Identifiers are unchanged: workspace.browser.categories is still the strip container and every chip keeps workspace.browser.category.<id> with the same accessibility values, so the FlagshipUITests that swipe the rail and assert reachability keep passing.

Why the previews lag

The store ran one job at a time on a serial queue at 256px per render; the three codec effects (datamosh, liquidMosh, heavyMosh) each took up to the 2s encode deadline, serializing the grid behind the slowest.

- GVEffectThumbnailStore is concurrent now, bounded by pool (4 style renders) and codecGate (2 codec renders), so a slow codec encode never serializes the cheap style renders behind it. The gate is chosen via GVEffectSampleRenderer.codecVariant, which was private on the renderer and was made internal for this.
- Renders now run at side = 128 — ~70pt tiles get a crisp upscale and about a quarter of the old pixel count; the disk cache moved to EffectThumbnails-Metal-v3.
