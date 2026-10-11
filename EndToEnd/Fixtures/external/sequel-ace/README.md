# The `sequel-ace` overlay

One file from [Sequel Ace](https://github.com/Sequel-Ace/Sequel-Ace) at commit
`1f2798da98d7cd8eef5cb5be97ce23de06733202`, at its path in that checkout, laid over the
clone by the end-to-end harness (`Projects.sequelAce`, B-77 item 4, B-154):

- `Source/Interfaces/ImportAccessory.xib`

The project's xib is misplaced: the frames it stores do not match its constraints. The
constraints size its accessory view to 707 × 160, and the xib says 707 × 184, with the
Format and Encoding rows, their pop-ups and the tab view at positions from an older layout.
ibtool updates such frames when it compiles, and does so differently from run to run.
Measured on Xcode 26.6, eight compiles of the one file came out as four different nibs:
the pop-ups, the labels and the tab view each at one of two places 24 points apart.
Semel's `IBToolCompiler` compiles every document twice and refuses one whose two nibs
differ (`toolOutputVaries`), so a fresh clone's build stops on this file. That is a fault
in the project, not in Semel.

This file is the project's with six frames changed: the view's height to 160, and the two
labels, the two pop-ups and the tab view to the frames AppKit's own layout gives them at
run time (the nib loaded with `NSNib` and laid out, which reports no ambiguous layout).
That is what Interface Builder's "Update Frames" writes. The constraints are unchanged, so
the app lays the view out as it did. Sixteen compiles of this file came out as one nib.

`LICENSE` is Sequel Ace's own, unchanged, laid over the checkout's identical copy: the file
is the project's, under its MIT license. This `README.md` is the overlay's and is not laid
over the clone.
