# Clicksmith

A right-click toolbox for the macOS Finder. Right-click a file and get only the tools that fit it: convert and shrink images, remove location data, compress video, make PDFs, create new files, rename in batch, and more. Every change can be undone, and the original file is never modified.

- macOS 14 or later. Native Swift 6, SwiftUI and AppKit. No third-party code.
- A Finder Sync extension plus a small app that starts on demand and quits when idle.
- `csx`: a command-line tool with the same actions.

## Build

No Xcode needed (Command Line Tools only).

```sh
scripts/check.sh     # build + all tests
scripts/bundle.sh    # build/Clicksmith.app, ad-hoc signed
scripts/install.sh   # copy to ~/Applications and enable the Finder extension
```

If macOS asks, turn on the extension in System Settings ▸ General ▸ Login Items & Extensions ▸ Finder.
