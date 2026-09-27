# The `food-truck-mac` overlay

Four files from Apple's [sample-food-truck](https://github.com/apple/sample-food-truck) at
commit `3954a769e99f3cc53297d94f2b960ceb2665b3d6`, at their paths in that checkout, laid
over the clone by the end-to-end harness (`Projects.foodTruckMac`, B-77):

- `App/Orders/OrderDetailView.swift`
- `Widgets/Widgets.swift`
- `Widgets/TruckActivityAttributes.swift`
- `Widgets/TruckActivityWidget.swift`

Each is the sample's file with one change: every `#if canImport(ActivityKit)` reads
`#if canImport(ActivityKit) && !os(macOS)`. The sample was written against the macOS 13
SDK, where ActivityKit could not be imported on the Mac; on a current SDK it can, but
`ActivityContent` and the Live Activity API are still unavailable on macOS, so the Mac
build fails on those files — in Xcode as well as in Semel. The added condition restores
what the guard meant.

`LICENSE.txt` is the sample's own, unchanged: the files are under Apple's sample code
license, and their headers point to it. This `README.md` is the overlay's and is not laid
over the clone.
