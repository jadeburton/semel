import CLib
import Foundation
import ObjCKit
import Shapes
import Smoothing
import Zipper

print("the answer is \(clib_answer()), twice \(clib_twice(clib_answer()))")
// Each of these links only with what the manifest's linkerSettings ask for, the C++
// runtime, and the target's assembly compiled (B-55).
print("label \(clib_label_length()), zlib \(clib_has_zlib()), scaled \(clib_scaled(7)), "
    + "assembled \(clib_asm_base() + clib_asm_offset())")
print("a 3 by 4 rectangle has area \(shapes_rectangle_area(3, 4))")
print("'aaabccdd' has \(Zipper.runCount(of: "aaabccdd")) runs, squeezing out \(Zipper.squeezedLength(of: "aaabccdd"))")
print("smoothing: \(SmoothingStyleName(2))")

guard OKOwner.weakReferenceClears() else {
    fatalError("a weak reference outlived its object: ObjCKit was not compiled with ARC")
}
print("a weak reference clears")

// ObjCKit reads its bundle through SWIFTPM_MODULE_BUNDLE, beside this executable (B-55).
guard let greeting = OKResources.greeting() else {
    fatalError("ObjCKit's bundle holds no greeting.txt")
}
print("ObjCKit's resource: \(greeting.trimmingCharacters(in: .whitespacesAndNewlines))")
