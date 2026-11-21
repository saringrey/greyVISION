# On-device test pass

Run on a physical iPhone after `./scripts/install-iphone.sh`. Tick each line;
note the phone model, iOS version and anything that fails.

## Launch
- [ ] App icon shows the mark inside lime tracker brackets with the `OBJ 00` tag.
- [ ] Cold launch goes black → splash with no grey flash in between.
- [ ] Splash film plays as an x-ray; finger drags the tracker cursor.
- [ ] Inside `+CAMERA` the film shows in true colour with a lime scan line; label readable on light and dark shots.
- [ ] Tapping `+CAMERA` opens the camera; permission prompts appear on the splash, never over the viewfinder.

## First run
- [ ] Three tips appear, each framing the real control: camera button, Effects, Photo.
- [ ] Tap anywhere advances; Skip ends; tips do not return on next launch.
- [ ] Camera menu → Tips shows them again.

## Top shell
- [ ] Camera button sits centred in the left shoulder, level with the Dynamic Island.
- [ ] Wordmark sits centred in the right shoulder.
- [ ] No camera-stats row under the top shell.
- [ ] Landscape left and right: button and wordmark at the row ends, nothing under the notch.

## Camera menu
- [ ] Lens steps through every physical lens (e.g. 0.5× → 1× → 2×/3× → 0.5×) and the picture actually changes lens.
- [ ] Flip front/rear; Lens shows 1× and is disabled on the front camera if it has one lens.
- [ ] Torch, Grid, Format, Aspect, Timer, Audio, Render, Mac Cam, Pair Mac, Lock, Tips, Restart each do what they say.
- [ ] Crosshair is always visible in camera mode.

## Zoom
- [ ] Pinch on the bare viewfinder zooms smoothly; the readout above the capture row follows.
- [ ] Tapping the readout steps lens and the Lens key in the menu agrees.
- [ ] With a spectrum overlay effect selected, pinch resizes the overlay instead of zooming.

## Capture
- [ ] Photo: no white flash; button shows Saving → Saved; image is in Photos at sensor resolution.
- [ ] Record: tag reads REC, timecode replaces the camera button, take saves and plays back with effects.
- [ ] Self-timer counts down and can be cancelled.

## Docks
- [ ] Capture row, camera menu, effect dock, effect browser and parameter decks all use the black plate, lime brackets and tags.
- [ ] Tags are never clipped by the deck above them.
- [ ] Active effect tiles show lime brackets.

## Mac Cam
- [ ] Pair with the Mac app, stream live, stop and restart.

## Sustained
- [ ] 10 minutes with a 3-effect stack: no thermal warning, no dropped-frame shedding notice, memory stable.
