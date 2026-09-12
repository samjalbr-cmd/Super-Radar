# Nightwatch for iOS

A host app that shows the dashboard full screen, and a home-screen widget that
answers the one question a glance is for: **is a storm heading here, and when.**

## Why it is shaped this way

A WidgetKit widget cannot host a web view — there is no such thing in the
framework — and iOS decides how often a widget may refresh, realistically every
15–30 minutes. So the widget is deliberately not a small radar app. It renders
one radar image and one number, and that number stays honest between refreshes
because the countdown runs from the storm cell's **observation time**, not from
when the widget last woke up. A 20-minute-old fetch still shows a correct ETA.

The app is a web view of the deployed dashboard rather than a reimplementation:
one codebase, and the phone still gets a real icon, no browser chrome, and a
screen that will not dim.

## Files

    Shared/StormArrival.swift    closest-approach geometry and the ranking rules
    Shared/StormFeed.swift       IEM attribute table, NOAA radar image, shared location
    Nightwatch/                  the host app
    NightwatchWidget/            the widget extension

`StormArrival.swift` is a port of the web app's `computeArrival` and was checked
against it on the same seven cases — direct hit, near miss, clean miss, a cell
already past, stationary, too weak, beyond the horizon — plus the observation-age
tick. Both produce identical decisions and ETAs.

## Setup

Open `Nightwatch.xcodeproj`, select your team on both targets if Xcode asks,
and run. The project is committed and builds as-is — verified with
`xcodebuild -target Nightwatch -sdk iphonesimulator`.

Then long-press the home screen → + → Nightwatch → small or medium widget.

If you would rather rebuild the targets by hand, the original steps follow.

## Setup by hand (about ten minutes)

1. **New project** — Xcode → File → New → Project → iOS → App.
   Name `Nightwatch`, interface SwiftUI, language Swift.
   Delete the generated `ContentView.swift` and `NightwatchApp.swift`.

2. **Add the widget target** — File → New → Target → Widget Extension.
   Name it `NightwatchWidget`. Uncheck "Include Live Activity" and
   "Include Configuration App Intent". Delete the files it generates.

3. **Add the sources** — drag `Shared/`, `Nightwatch/` and `NightwatchWidget/`
   into the project. In the file inspector set target membership:
   - both `Shared/*.swift` files → **app *and* widget**
   - `NightwatchApp.swift` → app only
   - `NightwatchWidget.swift` → widget only

4. **App group** — select the project, then for *each* target:
   Signing & Capabilities → + Capability → App Groups → add
   `group.com.samjalbr.nightwatch`. This is how the app tells the widget which
   location to watch; without it the widget falls back to Grand Rapids.

5. **Signing** — set your team on both targets. Bundle ids must nest, e.g.
   `com.samjalbr.nightwatch` and `com.samjalbr.nightwatch.NightwatchWidget`.

6. Build to your phone. Long-press the home screen → + → Nightwatch → pick the
   small or medium widget.

## Changing the location

`WatchLocation.fallback` in `StormFeed.swift` is the default. The app writes it
to the shared group on launch, and the widget reads it from there.

To follow the phone instead, add CoreLocation to the app, request
`whenInUse`, and call `WatchLocation(...).save()` with the fix — the widget
needs no changes, since it only ever reads the shared value.

## The map

Radar echo on its own has no geographic context, which is most of why an empty
render read as a broken widget. The radar widget now draws a real map: MapKit
renders a dark basemap for the region, the radar is composited over it, and
storm reports and your location are drawn on top.

Registration does not rely on two services agreeing about a bounding box.
MapKit adjusts a requested span to fit the widget's aspect ratio, so the radar
is requested for the region MapKit actually produced, and placed by projecting
that region's own corners through the snapshot.

## Zoom and settings

Zoom is a widget parameter — long-press the widget and choose Edit Widget:
Metro (~60 km), County (~150 km), Region (~300 km), State (~530 km), or
**Match the app**, which follows whatever the app is set to. Two radar widgets
can therefore sit side by side at different scales.

Storm reports likewise default to the app's setting and can be turned off per
widget. The shared values live in `WatchLocation` in the app group, so the app
remains the single place preferences are set.

## Clear weather vs. a broken widget

The radar service answers a clear sky with a fully transparent PNG, which on a
widget looks exactly like a failed fetch: an empty rectangle either way. The
radar widget therefore says which it is — **CLEAR / no echo nearby**, or
**NO DATA / couldn't reach radar** — rather than leaving you to guess.

Emptiness is judged by response size rather than by decoding and scanning
pixels. A blank render compresses to a few hundred bytes where one carrying
weather runs to tens or hundreds of kilobytes; measured across both widget sizes
the two cases sit 4x to 27x either side of the threshold.

## What the widget shows

    SEVERE CELL          <- tornado signature / rotating cell / severe / storm
    23 min               <- counted from the cell's observation time
    1.25" hail · 55 dBZ · 44 mph
    ~4 mi away           <- or "tracking over you" under three miles

With nothing inbound it shows the place name and the time of the last check.
