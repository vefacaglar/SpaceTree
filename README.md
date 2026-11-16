# SpaceTree

A native macOS disk usage explorer built with SwiftUI. Choose a folder or scan your home directory, expand folders to explore files sorted by size, and right-click an item to reveal it in Finder.

## Build and run

Requires macOS 14 or later and Xcode command-line tools.

```sh
./build-app.sh
open build/SpaceTree.app
```

The app reports logical file sizes, which can differ from actual disk space used due to APFS compression, clones, sparse files, or cloud files. Symbolic links are skipped. Inaccessible items are counted in the status bar; macOS privacy protections can require Full Disk Access to inspect some locations. Scans are read-only and do not modify files.

Scans stay on the selected filesystem and exclude iCloud Drive (`~/Library/Mobile Documents`), cloud provider folders (`~/Library/CloudStorage`), and external or network volumes. External volumes cannot be selected as scan roots.
